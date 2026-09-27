# =============================================================================
#  06_backtest_and_validate.R  |  Is the exposure model any good?
# =============================================================================
#
#  What this does
#    A. Backtests the risk-factor models against real history (the core of
#       Basel's IMM backtesting guidance, BCBS 2010)
#    B. Martingale tests: does the simulation reproduce today's prices?
#    C. Monte Carlo convergence: is 5,000 paths enough for stable CVA?
#
#  A. How the backtest works (probability integral transform, PIT)
#    At each past month-end, calibrate the model using ONLY data up to then
#    and forecast the distribution of the factor 1 month and 3 months ahead.
#    Then look up where the realised value fell in that forecast:
#        u = forecast CDF(realised value)
#    If the model is right, the u's are uniform between 0 and 1:
#      - too many u's near 0 or 1  -> the model's tails are too thin
#      - u's bunched in the middle -> the model is too wide (conservative)
#    Forecast windows do not overlap, so the observations are independent.
#
#  Forecast models (as in the simulation, but with real-world zero drift):
#    rates: change in the 1y yield ~ Normal(0, Hull-White OU variance)
#    FX:    change in log EURUSD  ~ Normal(0, sigma^2 h)
#    oil:   log WTI               ~ Schwartz conditional Normal
# -----------------------------------------------------------------------------

source("counterparty-credit-risk/config.R")
source("counterparty-credit-risk/ccr_functions.R")
m   <- readRDS(file.path(PATHS$processed, "market.rds"))
ex  <- readRDS(file.path(PATHS$processed, "exposure.rds"))
cc  <- readRDS(file.path(PATHS$processed, "cva_capital.rds"))
trd <- readRDS(file.path(PATHS$processed, "trades.rds"))
mkt <- m$mkt


# ---- A. Risk-factor backtest ------------------------------------------------
step("A. PIT backtest of risk-factor forecasts")

series <- list(rates = na.omit(m$tsy[, "DGS1"]) / 100, fx = m$fx, oil = log(m$wti))

forecast_dist <- function(factor, hist, h_days) {
  h <- h_days / 252
  x_now <- as.numeric(last(hist))
  if (factor == "rates") {
    s  <- sd(diff(as.numeric(tail(hist, 252 * VOL_YEARS)))) * sqrt(252)
    c(mean = x_now, sd = s * sqrt((1 - exp(-2 * HW_A * h)) / (2 * HW_A)))
  } else if (factor == "fx") {
    s  <- sd(diff(log(as.numeric(tail(hist, 252 * VOL_YEARS))))) * sqrt(252)
    c(mean = log(x_now), sd = s * sqrt(h))
  } else {
    p  <- calibrate_schwartz(as.numeric(tail(hist, 252 * WTI_CAL_YEARS)))
    mv <- schwartz_mean_var(x_now, h, p)
    c(mean = mv$mean, sd = sqrt(mv$var))
  }
}

run_backtest <- function(factor, h_days, step_months) {
  x <- series[[factor]]
  dates <- index(x)
  first_origin <- dates[1] + round(365.25 * max(WTI_CAL_YEARS, VOL_YEARS))
  month_ends <- dates[!duplicated(format(dates, "%Y-%m"), fromLast = TRUE)]
  origins <- month_ends[month_ends >= first_origin]
  origins <- origins[seq(1, length(origins), by = step_months)]
  last_target <- as.Date("1900-01-01")
  bind_rows(lapply(origins, function(o) {
    pos <- match(o, dates)
    if (is.na(pos) || pos + h_days > length(dates)) return(NULL)
    if (o < last_target) return(NULL)                  # skip: would overlap the previous window
    last_target <<- dates[pos + h_days]
    fc <- forecast_dist(factor, x[1:pos], h_days)
    realised <- as.numeric(x[pos + h_days])
    if (factor == "fx") realised <- log(realised)
    data.frame(factor = factor, horizon = paste0(h_days, "d"), origin = o,
               target_date = dates[pos + h_days], fc_mean = fc[["mean"]], fc_sd = fc[["sd"]],
               realised = realised, u = pnorm(realised, fc[["mean"]], fc[["sd"]]))
  }))
}

pit <- bind_rows(
  lapply(names(series), run_backtest, h_days = 21, step_months = 1),   # 1 month, monthly
  lapply(names(series), run_backtest, h_days = 63, step_months = 3)    # 3 months, quarterly
)

pit_tests <- pit |>
  group_by(factor, horizon) |>
  summarise(
    n            = n(),
    outside_95   = sum(u < 0.025 | u > 0.975),
    expected_95  = 0.05 * n(),
    coverage_p   = binom.test(sum(u < 0.025 | u > 0.975), n(), 0.05)$p.value,
    upper_tail_breaches = sum(u > 0.975),
    lower_tail_breaches = sum(u < 0.025),
    ks_p         = suppressWarnings(ks.test(u, "punif")$p.value),
    sd_of_u      = sd(u)                                # 0.289 if uniform
  ) |>
  ungroup() |>
  mutate(verdict = case_when(
    coverage_p < 0.05 & outside_95 > expected_95 ~ "Tails too thin (underestimates risk)",
    coverage_p < 0.05                            ~ "Too wide (conservative)",
    ks_p < 0.05                                  ~ "Coverage ok, but distribution shape off",
    TRUE                                         ~ "Passes"))
print(pit_tests |> mutate(across(where(is.numeric), ~ round(.x, 3))))


# ---- B. Martingale tests ----------------------------------------------------
# Under the pricing measure, discounted prices of traded assets must average
# back to today's prices:
#   E[ D(t) ]            = P(0, t)             (zero-coupon bond)
#   E[ D(t) x EURUSD(t) ] = S0 x e^{-r_eur t}  (EUR deposit converted to USD)
# A failure means the simulation creates or destroys value: a bug, or a
# drift / discretisation problem.
step("B. Martingale tests")
check_t <- c(1, 2, 5, max(ex$grid))
mart <- bind_rows(lapply(check_t, function(tt) {
  k <- which.min(abs(ex$grid - tt))
  zcb <- ex$D[, k]; fxd <- ex$D[, k] * ex$S[, k]
  data.frame(
    t = ex$grid[k],
    test = c("Zero-coupon bond", "Discounted EURUSD"),
    model_value = c(mean(zcb), mean(fxd)),
    market_value = c(P0(mkt$curve, ex$grid[k]), mkt$fx_spot * exp(-mkt$r_eur * ex$grid[k])),
    mc_std_error = c(sd(zcb), sd(fxd)) / sqrt(nrow(ex$D))
  )
})) |>
  mutate(error_bp = (model_value / market_value - 1) * 1e4,
         z_score = (model_value - market_value) / mc_std_error,
         pass = abs(z_score) < 3 | abs(error_bp) < 5)
print(mart |> mutate(across(where(is.numeric), ~ round(.x, 5))))


# ---- C. Monte Carlo convergence ---------------------------------------------
step("C. Monte Carlo convergence of CVA")
spreads <- COUNTERPARTIES |> left_join(mkt$spreads, by = "rating")
conv <- bind_rows(lapply(seq_len(nrow(spreads)), function(i) {
  cp <- spreads[i, ]
  contrib <- pathwise_cva(ex$E[[cp$cpty]], ex$D, ex$grid, cp$spread / LGD_MKT,
                          matrix(0, nrow(ex$D), ncol(ex$D)), 0, LGD_MKT)
  n_seq <- unique(round(seq(250, length(contrib), length.out = 40)))
  data.frame(cpty = cp$cpty, n_paths = n_seq,
             cva = sapply(n_seq, function(n) mean(contrib[1:n])),
             se  = sapply(n_seq, function(n) sd(contrib[1:n]) / sqrt(n)))
}))
conv_final <- conv |> group_by(cpty) |> slice_max(n_paths, n = 1) |>
  mutate(rel_error_95 = 1.96 * se / cva)
print(conv_final |> mutate(across(where(is.numeric), ~ round(.x, 4))))


# ---- Save -------------------------------------------------------------------
step("Saving")
save_table(pit,        file.path(PATHS$tables, "06_pit_observations.csv"))
save_table(pit_tests,  file.path(PATHS$tables, "06_pit_backtest_results.csv"))
save_table(mart,       file.path(PATHS$tables, "06_martingale_tests.csv"))
save_table(conv_final, file.path(PATHS$tables, "06_mc_convergence.csv"))
saveRDS(list(pit = pit, pit_tests = pit_tests, mart = mart, conv = conv, conv_final = conv_final,
             pricing_checks = trd$checks),
        file.path(PATHS$processed, "validation.rds"))


# ---- Figures ----------------------------------------------------------------
fac_lab <- c(rates = "Rates (1y UST)", fx = "EURUSD", oil = "WTI crude")

p_pit <- ggplot(pit |> mutate(factor = fac_lab[factor]), aes(u)) +
  geom_histogram(aes(y = after_stat(density)), breaks = seq(0, 1, 0.1),
                 fill = PALETTE["blue"], colour = "white") +
  geom_hline(yintercept = 1, colour = COL_LOSS, linetype = "dashed") +
  facet_grid(horizon ~ factor) +
  labs(title = "PIT histograms: where did reality land in each forecast?",
       subtitle = "A good model gives flat bars at the dashed line. Tall end bars = fat tails the model missed.",
       x = "u = forecast CDF of realised value", y = "Density") +
  theme_risk()
save_plot(p_pit, file.path(PATHS$figures, "06_pit_histograms.png"), height = 5.5)

band <- pit |> filter(factor == "oil", horizon == "21d") |>
  mutate(lo = exp(fc_mean - 1.96 * fc_sd), hi = exp(fc_mean + 1.96 * fc_sd),
         realised_px = exp(realised), breach = u < 0.025 | u > 0.975)
p_band <- ggplot(band, aes(target_date)) +
  geom_ribbon(aes(ymin = lo, ymax = hi), fill = PALETTE["blue"], alpha = 0.2) +
  geom_line(aes(y = realised_px), colour = COL_INK, linewidth = 0.4) +
  geom_point(data = filter(band, breach), aes(y = realised_px), colour = COL_LOSS, size = 1.8) +
  labs(title = "Oil model backtest: 1-month-ahead 95% forecast band vs. realised WTI",
       subtitle = "Red: realised price fell outside the band. Expect ~5% of months.",
       x = NULL, y = "$/bbl") +
  theme_risk()
save_plot(p_band, file.path(PATHS$figures, "06_oil_forecast_band.png"))

name_of <- setNames(COUNTERPARTIES$name, COUNTERPARTIES$cpty)
p_conv <- ggplot(conv |> mutate(cpty = name_of[cpty]), aes(n_paths, cva / 1e3)) +
  geom_ribbon(aes(ymin = (cva - 1.96 * se) / 1e3, ymax = (cva + 1.96 * se) / 1e3),
              fill = PALETTE["blue"], alpha = 0.2) +
  geom_line(colour = PALETTE["blue"], linewidth = 0.7) +
  facet_wrap(~cpty, scales = "free_y") +
  labs(title = "Monte Carlo convergence of CVA", subtitle = "Band = 95% confidence interval. It narrows like 1/sqrt(paths).",
       x = "Number of paths", y = "CVA ($ thousands)") +
  theme_risk()
save_plot(p_conv, file.path(PATHS$figures, "06_mc_convergence.png"), height = 5.5)
