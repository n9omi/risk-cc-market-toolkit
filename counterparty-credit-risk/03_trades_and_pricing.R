# =============================================================================
#  03_trades_and_pricing.R  |  Build the trade book and price it today
# =============================================================================
#
#  What this does
#    1. Sets each trade's strike from today's market (par rate / forward)
#    2. Prices every trade today (mark-to-market, MTM)
#    3. Checks the pricers: an at-market trade must be worth ~zero
#    4. Computes sensitivities (DV01, FX delta, oil delta) by bump-and-reprice
#    5. Prepares the trade fields SA-CCR needs
#
#  Why this matters
#    Exposure is just the future value of these trades. If today's price is
#    wrong, every exposure number built on top of it is wrong too. Pricing
#    checks are the first thing a model validator asks for.
# -----------------------------------------------------------------------------

source("counterparty-credit-risk/config.R")
source("counterparty-credit-risk/ccr_functions.R")
m   <- readRDS(file.path(PATHS$processed, "market.rds"))
mkt <- m$mkt


# ---- 1. Today's market levels for each trade --------------------------------
step("Setting strikes from today's market")

par_swap_rate <- function(M, curve) {
  pay <- seq(0.5, M, by = 0.5)
  (1 - P0(curve, M)) / sum(0.5 * P0(curve, pay))
}
fx_forward <- function(M, mkt) mkt$fx_spot * exp(-mkt$r_eur * M) / P0(mkt$curve, M)
wti_par_price <- function(M, mkt) {        # discount-weighted average forward = at-market fixed price
  fix <- seq(1 / 12, M, by = 1 / 12)
  Fw  <- as.numeric(schwartz_fwd(log(mkt$wti_spot), fix, mkt$wti))
  sum(Fw * P0(mkt$curve, fix)) / sum(P0(mkt$curve, fix))
}

trades <- TRADES |>
  rowwise() |>
  mutate(market_level = switch(type,
                               IRS   = par_swap_rate(maturity, mkt$curve),
                               FXFWD = fx_forward(maturity, mkt),
                               WTI   = wti_par_price(maturity, mkt)),
         strike = if (type == "IRS") market_level + strike_offset else market_level * (1 + strike_offset)) |>
  ungroup()


# ---- 2. Price every trade today ---------------------------------------------
# price_book() (in ccr_functions.R) reuses the Monte Carlo pricers on a
# single "path" at t = 0, where the Hull-White bond formula returns today's curve.
trades$mtm_today <- price_book(trades, mkt)


# ---- 3. Pricing checks ------------------------------------------------------
step("Pricing check: at-market trades should be worth ~0")
at_market <- trades |> mutate(strike = market_level)
checks <- data.frame(trade_id = trades$trade_id, type = trades$type,
                     mtm_at_market = price_book(at_market, mkt)) |>
  mutate(pass = abs(mtm_at_market) < 1)                 # within $1 on tens of millions
print(checks)
stopifnot(all(checks$pass))


# ---- 4. Sensitivities (bump and reprice) ------------------------------------
step("Sensitivities")
trades$dv01      <- price_book(trades, bump_market(mkt, rates_bp = 1)) - trades$mtm_today
trades$fx_delta  <- price_book(trades, bump_market(mkt, fx_pct = 0.01)) - trades$mtm_today
trades$oil_delta <- price_book(trades, bump_market(mkt, oil_abs = 1)) - trades$mtm_today


# ---- 5. Fields for SA-CCR ---------------------------------------------------
# Adjusted notional (Basel CRE52):
#   IR:        notional x supervisory duration
#   FX:        foreign-currency notional converted to USD
#   Commodity: total remaining barrels x current price
trades <- trades |>
  mutate(asset_class  = recode(type, IRS = "IR", FXFWD = "FX", WTI = "COMMODITY"),
         hedging_set  = recode(type, IRS = "USD", FXFWD = "EURUSD", WTI = "Crude oil"),
         adj_notional = case_when(
           type == "IRS"   ~ notional * supervisory_duration(0, maturity),
           type == "FXFWD" ~ notional * mkt$fx_spot,
           type == "WTI"   ~ notional * round(maturity * 12) * mkt$wti_spot),
         # Plain USD notional, used to weight effective maturity in 05
         usd_notional = case_when(
           type == "IRS"   ~ notional,
           type == "FXFWD" ~ notional * mkt$fx_spot,
           type == "WTI"   ~ notional * round(maturity * 12) * mkt$wti_spot))

print(trades |> select(trade_id, cpty, type, strike, mtm_today, dv01, fx_delta, oil_delta) |>
        mutate(across(where(is.numeric), ~ round(.x, 4))))

book_summary <- trades |>
  group_by(cpty) |>
  summarise(trades = n(), mtm_today = sum(mtm_today), dv01 = sum(dv01),
            fx_delta = sum(fx_delta), oil_delta = sum(oil_delta)) |>
  left_join(COUNTERPARTIES |> select(cpty, name, rating, csa), by = "cpty")
print(book_summary)


# ---- 6. Save ----------------------------------------------------------------
step("Saving")
save_table(trades, file.path(PATHS$tables, "03_trade_book.csv"))
save_table(checks, file.path(PATHS$tables, "03_pricing_checks.csv"))
save_table(book_summary, file.path(PATHS$tables, "03_book_by_counterparty.csv"))
saveRDS(list(trades = trades, checks = checks, book_summary = book_summary),
        file.path(PATHS$processed, "trades.rds"))
