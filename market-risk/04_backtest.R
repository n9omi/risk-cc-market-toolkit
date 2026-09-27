# =============================================================================
#  04_backtest.R  |  Did the VaR model work? Out-of-sample backtesting
# =============================================================================
#
#  What this does
#    1. Walks forward through history. Each day, it forecasts tomorrow's VaR
#       using ONLY the 250 days before it (no look-ahead), for four models.
#    2. Compares each forecast to the P&L that actually happened.
#    3. Runs the standard statistical tests and the Basel traffic light.
#
#  The questions each test answers
#    Kupiec (coverage) ........ Are there as many exceptions as promised?
#                               99% VaR -> about 1 in 100 days, ~2.5 a year.
#    Christoffersen (clusters). Do exceptions bunch together? If so, the
#                               model reacts too slowly when volatility jumps.
#    Traffic light ............ Regulatory view: exceptions in the last 250
#                               days -> Green (0-4), Yellow (5-9), Red (10+).
#    Acerbi-Szekely Z2 ........ Is ES big enough? (ES is harder to backtest
#                               than VaR because it is an average of the tail.)
#    FRTB desk test ........... More than 12 exceptions at 99% or 30 at 97.5%
#                               in 250 days -> desk loses internal model approval.
#
#  Monte Carlo methods are skipped to keep the run fast. Normal Monte Carlo
#  converges to the parametric model; Student-t MC could be added the same way.
# -----------------------------------------------------------------------------

source("market-risk/config.R")
source("market-risk/mr_functions.R")
dat <- readRDS(file.path(PATHS$processed, "clean_data.rds"))

R     <- coredata(dat$returns)
w     <- dat$positions
pnl   <- as.numeric(dat$pnl)
dates <- index(dat$pnl)
n     <- length(pnl)


# ---- 1. Walk-forward VaR / ES forecasts -------------------------------------
step("Walk-forward forecasts:", n - WINDOW, "days x 4 models")

vol_assets <- ewma_vol(R, EWMA_LAMBDA)          # per-asset vol forecasts (for FHS)
vol_port   <- as.numeric(ewma_vol(pnl, EWMA_LAMBDA))  # portfolio P&L vol forecasts (for EWMA)
z99  <- qnorm(VAR_CONF)
z975 <- qnorm(ES_CONF)

test_days <- (WINDOW + 1):n
fc <- matrix(NA_real_, length(test_days), 12,
             dimnames = list(NULL, c(outer(c("var99", "var975", "es975"),
                                           c("hs", "normal", "ewma", "fhs"), paste, sep = "_"))))

for (k in seq_along(test_days)) {
  t   <- test_days[k]
  win <- (t - WINDOW):(t - 1)                  # the 250 days BEFORE day t
  p_w <- pnl[win]

  # Historical simulation
  fc[k, c("var99_hs", "var975_hs", "es975_hs")] <-
    c(hs_var(p_w, VAR_CONF), hs_var(p_w, ES_CONF), hs_es(p_w, ES_CONF))

  # Parametric normal (equal weights over the window)
  s <- sd(p_w)
  fc[k, c("var99_normal", "var975_normal", "es975_normal")] <-
    c(s * z99, s * z975, normal_es(s, ES_CONF))

  # EWMA normal
  s <- vol_port[t]
  fc[k, c("var99_ewma", "var975_ewma", "es975_ewma")] <-
    c(s * z99, s * z975, normal_es(s, ES_CONF))

  # Filtered HS: rescale each past return to today's volatility
  scale  <- sweep(1 / vol_assets[win, ], 2, vol_assets[t, ], `*`)
  p_fhs  <- as.numeric((R[win, ] * scale) %*% w)
  fc[k, c("var99_fhs", "var975_fhs", "es975_fhs")] <-
    c(hs_var(p_fhs, VAR_CONF), hs_var(p_fhs, ES_CONF), hs_es(p_fhs, ES_CONF))
}

bt <- data.frame(date = dates[test_days], pnl = pnl[test_days], fc) |>
  mutate(loss = -pnl)

models <- c(hs = "Historical simulation", normal = "Parametric normal",
            ewma = "EWMA normal", fhs = "Filtered HS")


# ---- 2. Exceptions and tests ------------------------------------------------
step("Scoring each model")

last250 <- tail(seq_len(nrow(bt)), 250)
results <- bind_rows(lapply(names(models), function(m) {
  exc99  <- bt$loss > bt[[paste0("var99_", m)]]
  exc975 <- bt$loss > bt[[paste0("var975_", m)]]
  kp <- kupiec_test(exc99, VAR_CONF)
  ch <- christoffersen_test(exc99)
  lr_cc <- kp["LR_pof"] + ch["LR_ind"]              # conditional coverage = both
  data.frame(
    model               = models[[m]],
    days_tested         = nrow(bt),
    exceptions_99       = sum(exc99),
    expected_99         = round(nrow(bt) * (1 - VAR_CONF), 1),
    exception_rate      = mean(exc99),
    kupiec_p            = kp[["p_pof"]],
    christoffersen_p    = ch[["p_ind"]],
    cond_coverage_p     = 1 - pchisq(lr_cc[[1]], df = 2),
    es_z2               = es_z2_test(bt$loss, bt[[paste0("var975_", m)]], bt[[paste0("es975_", m)]], ES_CONF),
    last250_exc_99      = sum(exc99[last250]),
    last250_zone        = as.character(traffic_light(sum(exc99[last250]))),
    last250_plus_factor = basel_plus_factor(sum(exc99[last250])),
    last250_exc_975     = sum(exc975[last250]),
    frtb_desk_pass      = sum(exc99[last250]) <= 12 & sum(exc975[last250]) <= 30,
    pct_days_red_zone   = mean(zoo::rollsum(exc99, 250) >= 10)
  )
}))

# Plain-English verdicts (5% significance)
results <- results |>
  mutate(verdict = case_when(
    kupiec_p < 0.05 & exception_rate > (1 - VAR_CONF) ~ "Underestimates risk (too many exceptions)",
    kupiec_p < 0.05                                    ~ "Overestimates risk (too few exceptions)",
    christoffersen_p < 0.05                            ~ "Right count, but exceptions cluster",
    TRUE                                               ~ "Passes coverage and independence"),
    es_verdict = case_when(es_z2 < -1.80 ~ "ES rejected (red)",
                           es_z2 < -0.70 ~ "ES too low (yellow)",
                           TRUE          ~ "ES acceptable"))
print(results |> mutate(across(where(is.numeric), ~ round(.x, 3))))


# ---- 3. Save ----------------------------------------------------------------
step("Saving")
save_table(results, file.path(PATHS$tables, "04_backtest_results.csv"))
save_table(bt,      file.path(PATHS$tables, "04_backtest_daily_forecasts.csv"))
saveRDS(list(bt = bt, results = results, models = models),
        file.path(PATHS$processed, "backtest.rds"))


# ---- 4. Figures -------------------------------------------------------------

# (a) P&L vs. VaR for each model, exceptions in red
bt_long <- bind_rows(lapply(names(models), function(m) {
  data.frame(date = bt$date, pnl = bt$pnl, var = bt[[paste0("var99_", m)]], model = models[[m]])
})) |> mutate(exception = -pnl > var, model = factor(model, levels = models))

p_bt <- ggplot(bt_long, aes(date)) +
  geom_col(aes(y = pnl / 1e3), fill = "grey75", width = 1) +
  geom_line(aes(y = -var / 1e3), colour = PALETTE["blue"], linewidth = 0.5) +
  geom_point(data = filter(bt_long, exception), aes(y = pnl / 1e3),
             colour = COL_LOSS, size = 1.2) +
  facet_wrap(~model, ncol = 1) +
  labs(title = "Backtest: daily P&L vs. 99% VaR forecast (made the day before)",
       subtitle = "Grey: P&L. Blue: -VaR. Red dots: exceptions (loss bigger than VaR).",
       x = NULL, y = "$ thousands") +
  theme_risk()
save_plot(p_bt, file.path(PATHS$figures, "04_backtest_pnl_vs_var.png"), height = 9)

# (b) Rolling 250-day exception count against the traffic-light zones
roll_exc <- bt_long |>
  group_by(model) |>
  mutate(count_250 = zoo::rollsum(exception, 250, fill = NA, align = "right")) |>
  ungroup()
x_rng <- range(roll_exc$date)
p_tl <- ggplot(roll_exc, aes(date, count_250)) +
  annotate("rect", xmin = x_rng[1], xmax = x_rng[2], ymin = -Inf, ymax = 4.5, fill = "#1baf7a", alpha = 0.10) +
  annotate("rect", xmin = x_rng[1], xmax = x_rng[2], ymin = 4.5,  ymax = 9.5, fill = "#eda100", alpha = 0.14) +
  annotate("rect", xmin = x_rng[1], xmax = x_rng[2], ymin = 9.5,  ymax = Inf, fill = COL_LOSS, alpha = 0.10) +
  geom_step(colour = PALETTE["blue"], linewidth = 0.6, na.rm = TRUE) +
  facet_wrap(~model, ncol = 2) +
  labs(title = "Basel traffic light: exceptions in the trailing 250 days",
       subtitle = "Green 0-4 | Yellow 5-9 (capital multiplier rises) | Red 10+ (model presumed flawed)",
       x = NULL, y = "Exceptions (last 250 days)") +
  theme_risk()
save_plot(p_tl, file.path(PATHS$figures, "04_traffic_light.png"), height = 6)

# (c) Zoom on the COVID crash: how fast does each model react?
zoom <- bt_long |> filter(date >= as.Date("2020-01-15"), date <= as.Date("2020-06-30"))
if (nrow(zoom) > 0) {
  p_zoom <- ggplot(zoom, aes(date)) +
    geom_col(data = distinct(zoom, date, pnl), aes(y = pnl / 1e3), fill = "grey75", width = 1) +
    geom_line(aes(y = -var / 1e3, colour = model), linewidth = 0.7) +
    scale_colour_manual(values = unname(PALETTE[c("blue", "orange", "aqua", "violet")])) +
    labs(title = "Reaction speed during the COVID crash (Feb-Jun 2020)",
         subtitle = "Compare how quickly each model widens its VaR after the volatility shock.",
         x = NULL, y = "$ thousands") +
    theme_risk()
  save_plot(p_zoom, file.path(PATHS$figures, "04_covid_reaction_speed.png"))
}
