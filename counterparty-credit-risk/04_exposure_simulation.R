# =============================================================================
#  04_exposure_simulation.R  |  Simulate future exposure to each counterparty
# =============================================================================
#
#  What this does
#    1. Simulates 5,000 paths of rates, EURUSD and oil, monthly, out to the
#       longest trade maturity
#    2. Reprices every trade on every path at every date
#    3. Nets trades within each counterparty (ISDA netting set)
#    4. Applies collateral for counterparties with a CSA
#    5. Measures exposure: EE, PFE, EPE, EEPE and IMM-style EAD
#    6. Stresses today's exposure with instant market shocks
#
#  Key ideas
#    - Derivative exposure is RANDOM: it depends on where markets go.
#    - Netting: only the net value per counterparty is at risk in default.
#    - Collateral cuts exposure to roughly the move over the margin period
#      of risk (MPOR), plus any threshold.
#    - PFE (a high percentile) is used for credit limits; EE (the average) is
#      used for pricing (CVA) and capital (EEPE).
# -----------------------------------------------------------------------------

source("counterparty-credit-risk/config.R")
source("counterparty-credit-risk/ccr_functions.R")
mkt    <- readRDS(file.path(PATHS$processed, "market.rds"))$mkt
trades <- readRDS(file.path(PATHS$processed, "trades.rds"))$trades
cptys  <- COUNTERPARTIES


# ---- 1. Time grid -----------------------------------------------------------
# Monthly reporting dates, plus one extra date an MPOR before each, so we
# know the portfolio value when collateral was last received.
main_grid <- seq(0, max(trades$maturity), by = DT)
mpor_yrs  <- unique(na.omit(cptys$mpor_days)) / 250
lag_pts   <- unlist(lapply(mpor_yrs, function(m) main_grid[-1] - m))
full_grid <- sort(unique(round(c(main_grid, lag_pts[lag_pts > 0]), 10)))
idx_of    <- function(t) match(round(t, 10), full_grid)
idx_main  <- idx_of(main_grid)
step("Grid:", length(main_grid), "reporting dates,", length(full_grid), "simulation dates,", N_PATHS, "paths")


# ---- 2. Simulate the risk factors --------------------------------------------
step("Simulating risk factors")
t0 <- Sys.time()
sims <- simulate_factors(full_grid, N_PATHS, mkt, SEED)
cat("  done in", round(difftime(Sys.time(), t0, units = "secs"), 1), "seconds\n")


# ---- 3. Reprice every trade on every path and date --------------------------
step("Repricing", nrow(trades), "trades on every path and date")
t0 <- Sys.time()
V_trade <- lapply(seq_len(nrow(trades)), function(i) {
  sapply(seq_along(full_grid), function(k) price_trade(trades[i, ], k, sims, mkt))
})
names(V_trade) <- trades$trade_id
cat("  done in", round(difftime(Sys.time(), t0, units = "secs"), 1), "seconds\n")


# ---- 4. Netting and collateral ----------------------------------------------
step("Netting and collateral")
netting <- lapply(cptys$cpty, function(cp) {
  ids <- trades$trade_id[trades$cpty == cp]
  V   <- Reduce(`+`, V_trade[ids])                  # net value per path and date
  cp_row <- cptys[cptys$cpty == cp, ]

  V_main <- V[, idx_main]
  E_unc  <- pmax(V_main, 0)                         # exposure without collateral
  E_col  <- E_unc
  C_main <- matrix(0, nrow(V_main), ncol(V_main))

  if (cp_row$csa) {
    mpor <- cp_row$mpor_days / 250
    V_lag <- cbind(V[, 1], V[, idx_of(main_grid[-1] - mpor)])   # value one MPOR earlier
    C_main <- collateral_held(V_lag, cp_row$threshold, cp_row$mta)
    E_col  <- pmax(V_main - C_main, 0)
  }
  list(V = V_main, C = C_main, E = E_col, E_unc = E_unc)
})
names(netting) <- cptys$cpty

D_main <- sims$D[, idx_main]


# ---- 5. Exposure metrics ----------------------------------------------------
step("Exposure metrics")
profiles <- bind_rows(lapply(cptys$cpty, function(cp) {
  ns <- netting[[cp]]
  bind_rows(
    exposure_profile(ns$E,     D_main, main_grid, PFE_Q) |> mutate(basis = "With collateral"),
    exposure_profile(ns$E_unc, D_main, main_grid, PFE_Q) |> mutate(basis = "No collateral")
  ) |> mutate(cpty = cp)
}))

exposure_summary <- bind_rows(lapply(cptys$cpty, function(cp) {
  pr <- profiles |> filter(cpty == cp, basis == "With collateral")
  pu <- profiles |> filter(cpty == cp, basis == "No collateral")
  ns <- netting[[cp]]
  data.frame(
    cpty            = cp,
    mtm_today       = mean(ns$V[, 1]),
    collateral_today = mean(ns$C[, 1]),
    peak_ee         = max(pr$EE),
    peak_pfe        = max(pr$PFE),
    peak_pfe_time   = pr$t[which.max(pr$PFE)],
    peak_pfe_no_csa = max(pu$PFE),
    epe_1y          = mean(pr$EE[pr$t > 0 & pr$t <= 1]),
    eepe            = eepe(pr$t, pr$EE),
    imm_ead         = ALPHA * eepe(pr$t, pr$EE)
  )
})) |> left_join(cptys |> select(cpty, name, rating, csa), by = "cpty")
print(exposure_summary |> mutate(across(where(is.numeric), ~ round(.x))))


# ---- 6. Stressed current exposure -------------------------------------------
# Instant shocks applied to today's market, then the book is repriced.
# Answers: "if this happened overnight, who would owe us the most?"
step("Stressed current exposure")
shocks <- list(
  "Base"                    = list(),
  "Rates +100bp"            = list(rates_bp = 100),
  "Rates -100bp"            = list(rates_bp = -100),
  "EURUSD -10%"             = list(fx_pct = -0.10),
  "Oil -30%"                = list(oil_pct = -0.30),
  "Oil +30%"                = list(oil_pct = 0.30),
  "Combined: rates -100bp, oil -30%, EUR -10%" = list(rates_bp = -100, oil_pct = -0.30, fx_pct = -0.10)
)
stress_mtm <- sapply(shocks, function(s) {
  v <- price_book(trades, do.call(bump_market, c(list(mkt = mkt), s)))
  tapply(v, trades$cpty, sum)[cptys$cpty]
})
stress_tbl <- data.frame(cpty = cptys$cpty, stress_mtm, check.names = FALSE, row.names = NULL)
print(stress_tbl |> mutate(across(where(is.numeric), ~ round(.x / 1e3))))


# ---- 7. Save ----------------------------------------------------------------
step("Saving")
save_table(profiles,         file.path(PATHS$tables, "04_exposure_profiles.csv"))
save_table(exposure_summary, file.path(PATHS$tables, "04_exposure_summary.csv"))
save_table(stress_tbl,       file.path(PATHS$tables, "04_stressed_current_exposure.csv"))

# Keep what later scripts need: exposures, discount factors and factor paths
# on the reporting grid.
saveRDS(list(grid = main_grid, D = D_main, r = sims$r[, idx_main], S = sims$S[, idx_main],
             X = sims$X[, idx_main], E = lapply(netting, `[[`, "E"),
             profiles = profiles, exposure_summary = exposure_summary, stress_tbl = stress_tbl),
        file.path(PATHS$processed, "exposure.rds"))


# ---- 8. Figures -------------------------------------------------------------
lab <- setNames(paste0(cptys$name, " (", cptys$rating, ifelse(cptys$csa, ", CSA", ", no CSA"), ")"), cptys$cpty)

prof_long <- profiles |>
  select(cpty, basis, t, EE, PFE) |>
  pivot_longer(c(EE, PFE), names_to = "metric") |>
  mutate(series = paste(metric, "-", basis), cpty = lab[cpty]) |>
  filter(!(basis == "No collateral" & metric == "EE"))
p_prof <- ggplot(prof_long, aes(t, value / 1e6, colour = series, linetype = series)) +
  geom_line(linewidth = 0.7) +
  facet_wrap(~cpty, scales = "free", ncol = 2) +
  scale_colour_manual(values = c("EE - With collateral" = PALETTE[["blue"]],
                                 "PFE - With collateral" = PALETTE[["orange"]],
                                 "PFE - No collateral" = COL_INK)) +
  scale_linetype_manual(values = c("EE - With collateral" = "solid", "PFE - With collateral" = "solid",
                                   "PFE - No collateral" = "dashed")) +
  labs(title = paste0("Exposure profiles: expected exposure (EE) and ", PFE_Q * 100, "% PFE"),
       subtitle = "Swaps: 'hump' shape (uncertainty grows, then cash flows run off). CSA caps exposure (dashed = without it).",
       x = "Years from today", y = "$ millions") +
  theme_risk()
save_plot(p_prof, file.path(PATHS$figures, "04_exposure_profiles.png"), height = 7)

# Fan charts of the simulated risk factors
fan <- function(M, name, scale = 1) {
  q <- apply(M, 2, quantile, probs = c(0.025, 0.25, 0.5, 0.75, 0.975)) * scale
  data.frame(t = main_grid, lo = q[1, ], q1 = q[2, ], med = q[3, ], q3 = q[4, ], hi = q[5, ], factor = name)
}
fans <- bind_rows(fan(sims$r[, idx_main], "Short rate (%)", 100),
                  fan(sims$S[, idx_main], "EURUSD"),
                  fan(exp(sims$X[, idx_main]), "WTI ($/bbl)"))
p_fan <- ggplot(fans, aes(t)) +
  geom_ribbon(aes(ymin = lo, ymax = hi), fill = PALETTE["blue"], alpha = 0.15) +
  geom_ribbon(aes(ymin = q1, ymax = q3), fill = PALETTE["blue"], alpha = 0.30) +
  geom_line(aes(y = med), colour = PALETTE["blue"], linewidth = 0.7) +
  facet_wrap(~factor, scales = "free_y", ncol = 3) +
  labs(title = "Simulated risk factors: median, 50% and 95% bands",
       subtitle = sprintf("Oil mean-reverts (half-life %.1f years), so its band levels off; FX bands keep widening with sqrt(time).",
                          mkt$wti$half_life_yrs),
       x = "Years from today", y = NULL) +
  theme_risk()
save_plot(p_fan, file.path(PATHS$figures, "04_risk_factor_fans.png"), height = 4)
