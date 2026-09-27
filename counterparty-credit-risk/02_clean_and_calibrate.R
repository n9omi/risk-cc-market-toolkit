# =============================================================================
#  02_clean_and_calibrate.R  |  Clean the data and fit the risk-factor models
# =============================================================================
#
#  What this does
#    1. Cleans the FRED series (holidays, bad prints, stale values) and logs fixes
#    2. Builds today's discount curve from Treasury yields
#    3. Calibrates the three risk-factor models:
#         rates  - Hull-White volatility from daily changes in the 1y yield
#         FX     - EURUSD volatility from daily log returns
#         oil    - Schwartz mean reversion, long-run level and volatility
#    4. Estimates the correlations between the three factors
#    5. Turns credit spreads into default probabilities (hazard rates)
#
#  Real-data example worth knowing: WTI spot printed about -$37 on 20 Apr 2020.
#  A log-price model cannot take a negative number, so that day is flagged
#  and filled by interpolation. A risk analyst must document fixes like this.
# -----------------------------------------------------------------------------

source("counterparty-credit-risk/config.R")
source("counterparty-credit-risk/ccr_functions.R")
raw <- readRDS(file.path(PATHS$processed, "raw_data.rds"))

to_xts <- function(id) { d <- raw[[id]]; xts(d[[id]], d$date, dimnames = list(NULL, id)) }
dq_log <- list()


# ---- 1. Clean each block of data --------------------------------------------
step("Cleaning")

# Treasuries: FRED leaves holidays as NA; drop days with no data at all,
# then carry forward short gaps (e.g. a single missing tenor).
tsy <- do.call(merge, lapply(unname(TSY_SERIES), to_xts))
tsy <- tsy[rowSums(!is.na(tsy)) > 0]
tsy <- na.locf(tsy, maxgap = 5, na.rm = FALSE)

# FX and ECB rate: carry forward over holidays
fx     <- na.locf(na.omit(to_xts(FX_SERIES)))
eur_rt <- na.locf(na.omit(to_xts(EUR_RATE)))

# WTI: flag non-positive prints, interpolate over them
wti <- na.omit(to_xts(WTI_SERIES))
bad <- which(wti <= 0)
if (length(bad)) {
  dq_log$wti <- data.frame(date = index(wti)[bad], series = WTI_SERIES,
                           value = as.numeric(wti[bad]),
                           fix = "non-positive price -> linear interpolation")
  wti[bad] <- NA
  wti <- na.approx(wti)
}

# Stale-data check: the same value 5+ days in a row
stale_check <- function(x, name) {
  r <- rle(as.numeric(diff(x))[-1] == 0)
  data.frame(series = name, stale_runs_5plus = sum(r$lengths[r$values] >= 5, na.rm = TRUE))
}
dq_summary <- bind_rows(
  data.frame(series = TSY_SERIES, obs = colSums(!is.na(tsy)),
             last_value = as.numeric(last(tsy)), min = apply(tsy, 2, min, na.rm = TRUE),
             max = apply(tsy, 2, max, na.rm = TRUE)),
  data.frame(series = c(FX_SERIES, EUR_RATE, WTI_SERIES),
             obs = c(nrow(fx), nrow(eur_rt), nrow(wti)),
             last_value = sapply(list(fx, eur_rt, wti), function(x) as.numeric(last(x))),
             min = sapply(list(fx, eur_rt, wti), min), max = sapply(list(fx, eur_rt, wti), max))
) |> left_join(bind_rows(stale_check(fx, FX_SERIES), stale_check(wti, WTI_SERIES)), by = "series")
rownames(dq_summary) <- NULL
print(dq_summary)


# ---- 2. Valuation date and today's curve ------------------------------------
# Valuation date = latest day on which the curve, FX and oil all have data
common <- index(tsy[complete.cases(tsy)])
val_date <- max(Reduce(intersect, list(common, index(fx), index(wti))))
val_date <- as.Date(val_date)
step("Valuation date:", format(val_date), "| latest Treasury date:", format(max(common)))
# FRED publishes EURUSD (H.10) weekly, so the valuation date can trail the
# latest Treasury print by a few days. That is expected, not a data error.

tenors   <- as.numeric(names(TSY_SERIES))
cmt_today <- as.numeric(tsy[val_date])
curve    <- make_curve(tenors, cmt_to_zero(cmt_today))
curve_tbl <- data.frame(tenor_yrs = tenors, series = TSY_SERIES, cmt_yield_pct = cmt_today,
                        zero_rate_cc = curve$zeros, discount_factor = P0(curve, tenors))
print(curve_tbl |> mutate(across(where(is.numeric), ~ round(.x, 5))))


# ---- 3. Calibrate the risk-factor models ------------------------------------
step("Calibrating risk-factor models")
lookback <- function(x, years) x[index(x) > val_date - round(365.25 * years) & index(x) <= val_date]

# Rates: Hull-White sigma ~ annualised volatility of daily changes in the
# 1y yield (in decimals). Mean reversion `a` is fixed in config.
d_r      <- diff(lookback(tsy[, "DGS1"], VOL_YEARS) / 100)
hw_sigma <- sd(d_r, na.rm = TRUE) * sqrt(252)

# FX: annualised volatility of daily log returns
d_fx   <- diff(log(lookback(fx, VOL_YEARS)))
fx_vol <- sd(d_fx, na.rm = TRUE) * sqrt(252)

# Oil: Schwartz one-factor on log prices
wti_par <- calibrate_schwartz(as.numeric(log(lookback(wti, WTI_CAL_YEARS))))

# Correlations between daily moves of the three factors
moves <- na.omit(merge(d_r, d_fx, diff(log(lookback(wti, VOL_YEARS)))))
colnames(moves) <- c("rates", "fx", "oil")
corr <- cor(moves)

params <- data.frame(
  parameter = c("Hull-White mean reversion a", "Hull-White sigma (abs. rate vol)", "EURUSD volatility",
                "WTI mean reversion kappa", "WTI half-life (years)", "WTI long-run level ($/bbl)",
                "WTI volatility", "EUR rate (ECB deposit)", "EURUSD spot", "WTI spot ($/bbl)"),
  value = c(HW_A, hw_sigma, fx_vol, wti_par$kappa, wti_par$half_life_yrs, exp(wti_par$alpha),
            wti_par$sigma, as.numeric(eur_rt[paste0("/", val_date)] |> last()) / 100,
            as.numeric(fx[val_date]), as.numeric(wti[val_date])),
  source = c("assumption (config)", paste0("1y UST, last ", VOL_YEARS, "y"), paste0("last ", VOL_YEARS, "y"),
             paste0("AR(1), last ", WTI_CAL_YEARS, "y"), "log(2)/kappa", "exp(alpha)",
             paste0("AR(1), last ", WTI_CAL_YEARS, "y"), "FRED ECBDFR", "FRED DEXUSEU", "FRED DCOILWTICO")
)
print(params |> mutate(value = round(value, 4)))
print(round(corr, 3))


# ---- 4. Credit spreads -> hazard rates --------------------------------------
# Credit triangle: spread ~ hazard x LGD, so hazard = spread / LGD.
# Bond spreads also include a liquidity premium, so this overstates default
# risk a little. Using rating-bucket spreads for names without CDS is the
# same idea as the "proxy spread" method regulators allow for CVA.
step("Credit spreads and hazard rates")
spreads <- bind_rows(lapply(names(SPREAD_SERIES), function(rt) {
  x <- na.omit(to_xts(SPREAD_SERIES[[rt]]))
  x <- x[index(x) <= val_date]
  data.frame(rating = rt, series = SPREAD_SERIES[[rt]], as_of = as.Date(last(index(x))),
             spread = as.numeric(last(x)) / 100)
})) |>
  mutate(hazard = spread / LGD_MKT,
         pd_1y_market = 1 - exp(-hazard),
         pd_1y_historical = PD_BY_RATING[rating])
print(spreads |> mutate(across(where(is.numeric), ~ round(.x, 5))))


# ---- 5. Save ----------------------------------------------------------------
mkt <- list(
  val_date = val_date, curve = curve, hw_a = HW_A, hw_sigma = hw_sigma,
  fx_spot = as.numeric(fx[val_date]), fx_vol = fx_vol,
  r_eur = params$value[params$parameter == "EUR rate (ECB deposit)"],
  wti_spot = as.numeric(wti[val_date]), wti = wti_par,
  corr = corr, spreads = spreads
)
saveRDS(list(mkt = mkt, tsy = tsy, fx = fx, wti = wti, eur_rt = eur_rt, params = params,
             curve_tbl = curve_tbl, dq_summary = dq_summary),
        file.path(PATHS$processed, "market.rds"))

step("Saving tables and figures")
save_table(dq_summary, file.path(PATHS$tables, "02_data_quality_summary.csv"))
if (length(dq_log)) save_table(bind_rows(dq_log), file.path(PATHS$tables, "02_dq_fixes.csv"))
save_table(curve_tbl,  file.path(PATHS$tables, "02_curve_today.csv"))
save_table(params,     file.path(PATHS$tables, "02_model_parameters.csv"))
save_table(data.frame(factor = rownames(corr), round(corr, 4)), file.path(PATHS$tables, "02_factor_correlations.csv"))
save_table(spreads,    file.path(PATHS$tables, "02_credit_spreads_hazards.csv"))

# (a) Today's zero curve and the oil model's forward curve
tt <- seq(0.05, 30, by = 0.05)
p_curve <- ggplot(data.frame(t = tt, z = zero_rate(curve, tt)), aes(t, z)) +
  geom_line(colour = PALETTE["blue"], linewidth = 0.8) +
  geom_point(data = curve_tbl, aes(tenor_yrs, zero_rate_cc), colour = PALETTE["blue"], size = 2) +
  scale_y_continuous(labels = percent_format(0.1)) +
  labs(title = "US Treasury zero curve", subtitle = paste("As of", format(val_date)),
       x = "Maturity (years)", y = "Zero rate (cont. comp.)") +
  theme_risk()
fwd <- data.frame(t = tt[tt <= 5], F = as.numeric(schwartz_fwd(log(mkt$wti_spot), tt[tt <= 5], wti_par)))
p_fwd <- ggplot(fwd, aes(t, F)) +
  geom_hline(yintercept = exp(wti_par$alpha), colour = COL_INK, linetype = "dashed", linewidth = 0.3) +
  geom_line(colour = PALETTE["orange"], linewidth = 0.8) +
  labs(title = "WTI model forward curve",
       subtitle = sprintf("Dashed = long-run level. Half-life %.1f years.", wti_par$half_life_yrs),
       x = "Maturity (years)", y = "$/bbl") +
  theme_risk()
save_plot(p_curve + p_fwd, file.path(PATHS$figures, "02_curves_today.png"), height = 4.5)

# (b) Risk-factor history
hist_df <- bind_rows(
  data.frame(date = index(tsy), value = as.numeric(tsy[, "DGS1"]), factor = "US 1y Treasury yield (%)"),
  data.frame(date = index(tsy), value = as.numeric(tsy[, "DGS10"]), factor = "US 10y Treasury yield (%)"),
  data.frame(date = index(fx),  value = as.numeric(fx),  factor = "EURUSD"),
  data.frame(date = index(wti), value = as.numeric(wti), factor = "WTI crude ($/bbl, cleaned)")
)
p_hist <- ggplot(hist_df, aes(date, value)) +
  geom_line(colour = PALETTE["blue"], linewidth = 0.4, na.rm = TRUE) +
  facet_wrap(~factor, scales = "free_y", ncol = 2) +
  labs(title = "Risk-factor history used for calibration and backtesting",
       x = NULL, y = NULL, caption = "Source: FRED (St. Louis Fed)") +
  theme_risk()
save_plot(p_hist, file.path(PATHS$figures, "02_risk_factor_history.png"), height = 6)
