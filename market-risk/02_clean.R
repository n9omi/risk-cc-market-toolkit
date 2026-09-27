# =============================================================================
#  02_clean.R  |  Clean prices, run data-quality checks, build daily P&L
# =============================================================================
#
#  What this does
#    1. Lines up adjusted closing prices for all ETFs on one date index
#    2. Runs data-quality (DQ) checks and logs every fix
#    3. Converts prices to daily returns
#    4. Builds the portfolio's daily hypothetical P&L
#
#  Why this matters
#    Bad data is the #1 cause of bad VaR. A stale price shows up as a day of
#    zero risk; a bad print shows up as a fake crash. Risk analysts spend a
#    large share of their time on exactly these checks.
#
#  Key term: HYPOTHETICAL P&L
#    Today's positions, revalued with each historical day's market moves.
#    It strips out intraday trading and fees, so it isolates what the VaR
#    model is meant to predict. FRTB backtests on this P&L (plus actual P&L).
# -----------------------------------------------------------------------------

source("market-risk/config.R")
raw <- readRDS(file.path(PATHS$processed, "raw_data.rds"))


# ---- 1. Build one price table (dates x tickers) -----------------------------
step("Lining up adjusted close prices")

# Adjusted close = price adjusted for dividends and splits, so returns
# computed from it are total returns.
prices_long <- bind_rows(lapply(names(raw$etf), function(tk) {
  d <- raw$etf[[tk]]
  data.frame(date = d$date, ticker = tk, price = d[[paste0(tk, ".Adjusted")]])
}))

prices_wide <- prices_long |>
  distinct(date, ticker, .keep_all = TRUE) |>             # drop duplicate rows
  pivot_wider(names_from = ticker, values_from = price) |>
  arrange(date)

prices <- xts(as.matrix(prices_wide[, PORTFOLIO$ticker]), order.by = prices_wide$date)
dq_log <- list()   # every fix gets written here


# ---- 2. Data-quality checks -------------------------------------------------
step("Running data-quality checks")

# (a) Non-positive prices are impossible for an ETF: treat as missing
bad_px <- which(prices <= 0, arr.ind = TRUE)
if (nrow(bad_px) > 0) {
  dq_log$bad_price <- data.frame(date = index(prices)[bad_px[, 1]],
                                 ticker = colnames(prices)[bad_px[, 2]],
                                 issue = "non-positive price set to NA")
  px_mat <- coredata(prices); px_mat[bad_px] <- NA       # edit the matrix, not the xts
  prices <- xts(px_mat, index(prices))
}

# (b) Missing prices: fill short gaps (up to 2 days) with the last price.
#     Longer gaps are left missing and those dates are dropped below.
missing_before <- colSums(is.na(prices))
prices <- na.locf(prices, maxgap = 2, na.rm = FALSE)
filled <- missing_before - colSums(is.na(prices))
prices <- prices[complete.cases(prices), ]

# (c) Returns: simple (arithmetic) returns, because P&L = $ position x return
returns <- na.omit(prices / stats::lag(prices, 1) - 1)

# (d) Stale prices: 3+ days in a row with exactly zero return
stale_runs <- sapply(colnames(returns), function(tk) {
  r <- rle(as.numeric(returns[, tk]) == 0)
  sum(r$lengths[r$values] >= 3)
})

# (e) Outliers: moves larger than 5 standard deviations (rolling 1-year sd).
#     These are FLAGGED, not deleted: real crashes are exactly what VaR is
#     for. A human checks each one against the news before deciding.
roll_sd  <- rollapply(returns, WINDOW, sd, align = "right", fill = NA)
z_scores <- returns / stats::lag(roll_sd, 1)
outliers <- which(abs(coredata(z_scores)) > 5, arr.ind = TRUE)
outlier_tbl <- data.frame(
  date   = index(returns)[outliers[, 1]],
  ticker = colnames(returns)[outliers[, 2]],
  return = round(coredata(returns)[outliers], 4),
  z      = round(coredata(z_scores)[outliers], 1)
) |> arrange(date)

dq_summary <- data.frame(
  ticker            = colnames(prices),
  first_raw_date    = as.Date(sapply(colnames(prices), function(tk) min(raw$etf[[tk]]$date))),
  last_raw_date     = as.Date(sapply(colnames(prices), function(tk) max(raw$etf[[tk]]$date))),
  n_returns         = colSums(!is.na(returns)),
  gaps_filled       = as.integer(filled),
  stale_runs_3plus  = as.integer(stale_runs),
  outliers_5sd      = as.integer(table(factor(outlier_tbl$ticker, levels = colnames(prices)))),
  worst_day         = round(apply(returns, 2, min), 4),
  best_day          = round(apply(returns, 2, max), 4),
  ann_vol           = round(apply(returns, 2, sd) * sqrt(252), 4),
  row.names = NULL
)
print(dq_summary)


# ---- 3. Portfolio P&L -------------------------------------------------------
step("Building daily hypothetical P&L")

positions <- setNames(PORTFOLIO$position_usd, PORTFOLIO$ticker)
asset_pnl <- sweep(returns, 2, positions, `*`)    # $ P&L by position
pnl       <- xts(rowSums(asset_pnl), index(asset_pnl))
colnames(pnl) <- "pnl"

cat("  Days of P&L:", nrow(pnl), " from", format(start(pnl)), "to", format(end(pnl)), "\n")
cat("  Worst day:  ", fmt_usd(min(pnl)), "on", format(index(pnl)[which.min(pnl)]), "\n")


# ---- 4. Market context (FRED) -----------------------------------------------
# FRED leaves holidays as NA. Carry the last value forward and align to the
# ETF trading calendar.
context <- Reduce(function(a, b) merge(a, b, all = TRUE),
                  lapply(names(FRED_SERIES), function(nm) {
                    d <- raw$fred[[nm]]
                    xts(d[[FRED_SERIES[[nm]]]], d$date, dimnames = list(NULL, nm))
                  }))
context <- na.locf(context)[index(returns)]


# ---- 5. Save outputs --------------------------------------------------------
step("Saving")
save_table(dq_summary,  file.path(PATHS$tables, "02_data_quality_summary.csv"))
save_table(outlier_tbl, file.path(PATHS$tables, "02_flagged_outliers.csv"))
if (length(dq_log)) save_table(bind_rows(dq_log), file.path(PATHS$tables, "02_dq_fixes.csv"))

saveRDS(list(prices = prices, returns = returns, pnl = pnl, asset_pnl = asset_pnl,
             positions = positions, context = context, dq_summary = dq_summary,
             outliers = outlier_tbl),
        file.path(PATHS$processed, "clean_data.rds"))

# Chart: each asset's price path (indexed to 100), one panel per asset
idx <- data.frame(date = index(prices), coredata(sweep(prices, 2, coredata(prices[1, ]), "/") * 100)) |>
  pivot_longer(-date, names_to = "ticker", values_to = "index") |>
  left_join(PORTFOLIO[, c("ticker", "description")], by = "ticker") |>
  mutate(label = paste0(ticker, " - ", description))

p_idx <- ggplot(idx, aes(date, index)) +
  geom_hline(yintercept = 100, colour = COL_INK, linewidth = 0.3, linetype = "dashed") +
  geom_line(colour = PALETTE["blue"], linewidth = 0.5) +
  facet_wrap(~label, scales = "free_y", ncol = 2) +
  scale_y_log10() +
  labs(title = "Portfolio building blocks, indexed to 100 at start (log scale)",
       subtitle = "Adjusted close prices. Note USO and UNG: futures roll costs erode long-run value.",
       x = NULL, y = NULL, caption = "Source: Yahoo Finance") +
  theme_risk()
save_plot(p_idx, file.path(PATHS$figures, "02_price_history.png"), height = 7)

p_pnl <- ggplot(data.frame(date = index(pnl), pnl = coredata(pnl)[, 1]), aes(date, pnl / 1e3)) +
  geom_col(aes(fill = pnl < 0), width = 1) +
  scale_fill_manual(values = c(`TRUE` = COL_LOSS, `FALSE` = COL_GAIN), guide = "none") +
  labs(title = "Daily hypothetical P&L of today's portfolio",
       subtitle = "Today's positions revalued with each historical day's returns. Volatility clusters in 2008, 2020 and 2022.",
       x = NULL, y = "P&L ($ thousands)") +
  theme_risk()
save_plot(p_pnl, file.path(PATHS$figures, "02_daily_pnl.png"))
