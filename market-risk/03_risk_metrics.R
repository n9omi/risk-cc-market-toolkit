# =============================================================================
#  03_risk_metrics.R  |  Today's VaR and ES: six methods, side by side
# =============================================================================
#
#  What this does
#    1. Estimates 1-day 99% VaR and 97.5% ES with six methods
#    2. Breaks VaR down by position (component VaR)
#    3. Finds the stressed VaR window (Basel 2.5)
#    4. Illustrates regulatory capital: Basel 2.5 VaR + sVaR, and FRTB ES
#
#  The six methods
#    Historical simulation (HS) ....... last 250 days of real moves, as-is
#    Parametric normal ................. equal-weighted covariance, normal tails
#    EWMA normal (RiskMetrics) ......... recent days weighted more heavily
#    Filtered HS (FHS) ................. historical moves rescaled to today's vol
#    Monte Carlo normal ................ simulate from the covariance matrix
#    Monte Carlo Student-t ............. same, but with fat tails
#
#  How to read the differences
#    EWMA/FHS above HS   -> markets are calmer in the past year than now
#    HS above normal     -> the P&L has fatter tails than a normal curve
#    Student-t ES > normal ES -> tail severity the normal model misses
# -----------------------------------------------------------------------------

source("market-risk/config.R")
source("market-risk/mr_functions.R")
dat <- readRDS(file.path(PATHS$processed, "clean_data.rds"))
set.seed(SEED)

R   <- coredata(dat$returns)
w   <- dat$positions
pnl <- as.numeric(dat$pnl)
n   <- nrow(R)
as_of <- end(dat$returns)

R_win   <- R[(n - WINDOW + 1):n, ]     # last 250 days
pnl_win <- pnl[(n - WINDOW + 1):n]


# ---- 1. VaR and ES, six ways ------------------------------------------------
step("Estimating 1-day VaR and ES as of", format(as_of))

# (a) Historical simulation
hs <- c(var = hs_var(pnl_win, VAR_CONF), es = hs_es(pnl_win, ES_CONF))

# (b) Parametric normal, equal-weighted covariance over the window
cov_win  <- cov(R_win)
sigma_eq <- sqrt(as.numeric(t(w) %*% cov_win %*% w))
param <- c(var = normal_var(sigma_eq, VAR_CONF), es = normal_es(sigma_eq, ES_CONF))

# (c) EWMA normal (RiskMetrics)
cov_ewma   <- ewma_cov(R, EWMA_LAMBDA)
sigma_ewma <- sqrt(as.numeric(t(w) %*% cov_ewma %*% w))
ewma <- c(var = normal_var(sigma_ewma, VAR_CONF), es = normal_es(sigma_ewma, ES_CONF))

# (d) Filtered historical simulation (Hull & White, 1998)
#     Each past return is divided by the vol at the time and multiplied by
#     today's vol. Keeps the real shape of the tails, updates the scale.
vol_path  <- ewma_vol(R, EWMA_LAMBDA)                          # vol forecast for each day
vol_next  <- sqrt(EWMA_LAMBDA * vol_path[n, ]^2 + (1 - EWMA_LAMBDA) * R[n, ]^2)
R_scaled  <- R_win / vol_path[(n - WINDOW + 1):n, ] * matrix(vol_next, WINDOW, ncol(R), byrow = TRUE)
pnl_fhs   <- as.numeric(R_scaled %*% w)
fhs <- c(var = hs_var(pnl_fhs, VAR_CONF), es = hs_es(pnl_fhs, ES_CONF))

# (e) Monte Carlo, multivariate normal, using the window covariance.
#     Cholesky factor L gives correlated shocks: X = Z %*% L, with Z iid N(0,1)
L       <- chol(cov_win)
Z       <- matrix(rnorm(MC_SIMS * ncol(R)), MC_SIMS)
pnl_mcn <- as.numeric((Z %*% L) %*% w)
mc_norm <- c(var = hs_var(pnl_mcn, VAR_CONF), es = hs_es(pnl_mcn, ES_CONF))

# (f) Monte Carlo, multivariate Student-t (fat tails), same covariance.
#     t = Z / sqrt(W / df) has covariance df/(df-2), so rescale to match.
W_chi   <- rchisq(MC_SIMS, df = T_DF)
X_t     <- (Z %*% L) / sqrt(W_chi / T_DF) * sqrt((T_DF - 2) / T_DF)
pnl_mct <- as.numeric(X_t %*% w)
mc_t    <- c(var = hs_var(pnl_mct, VAR_CONF), es = hs_es(pnl_mct, ES_CONF))

gross <- sum(abs(w))
var_summary <- data.frame(
  method     = c("Historical simulation", "Parametric normal", "EWMA normal (RiskMetrics)",
                 "Filtered HS", "Monte Carlo normal", "Monte Carlo Student-t"),
  var_99_1d  = c(hs["var"], param["var"], ewma["var"], fhs["var"], mc_norm["var"], mc_t["var"]),
  es_975_1d  = c(hs["es"],  param["es"],  ewma["es"],  fhs["es"],  mc_norm["es"],  mc_t["es"])
) |>
  mutate(var_99_10d   = var_99_1d * sqrt(HOLD_DAYS),   # square-root-of-time scaling
         var_pct_gross = var_99_1d / gross,
         es_to_var     = es_975_1d / var_99_1d)
print(var_summary |> mutate(across(where(is.numeric), ~ round(.x, 3))))


# ---- 2. Component VaR: which positions drive the risk? ---------------------
step("Decomposing VaR by position (EWMA covariance)")
comp <- component_var(w, cov_ewma, VAR_CONF) |>
  left_join(PORTFOLIO[, c("ticker", "description")], by = "ticker")
diversification <- sum(comp$standalone_var) - sum(comp$component_var)
cat("  Sum of standalone VaRs:", fmt_usd(sum(comp$standalone_var)),
    "| Portfolio VaR:", fmt_usd(sum(comp$component_var)),
    "| Diversification benefit:", fmt_usd(diversification), "\n")


# ---- 3. Stressed VaR (Basel 2.5) --------------------------------------------
# Stressed VaR = VaR of TODAY's portfolio using the worst 12-month period
# in history. We find that window by computing HS VaR on every rolling window.
step("Searching history for the stressed window")
roll_var <- rollapply(pnl, WINDOW, hs_var, conf = VAR_CONF, align = "right", fill = NA)
roll_var_xts <- xts(roll_var, index(dat$pnl))
worst_end  <- which.max(roll_var)
stress_win <- index(dat$pnl)[c(worst_end - WINDOW + 1, worst_end)]
svar <- roll_var[worst_end]
cat("  Stressed window:", format(stress_win[1]), "to", format(stress_win[2]),
    "| sVaR (1d, 99%):", fmt_usd(svar), "\n")


# ---- 4. Regulatory capital illustrations ------------------------------------
step("Regulatory capital illustrations")

# Basel 2.5 (US Market Risk Rule today):
#   capital = max(VaR_t, 3 x avg VaR over 60 days) + max(sVaR_t, 3 x avg sVaR)
#   using 10-day VaR (here: 1-day x sqrt(10)). The 3 rises to up to 4 if the
#   backtest lands in the yellow/red zone (see 04_backtest.R).
avg60_var <- mean(tail(roll_var, 60))
basel25 <- data.frame(
  component = c("VaR (10d)", "Stressed VaR (10d)"),
  latest    = c(tail(roll_var, 1), svar) * sqrt(HOLD_DAYS),
  avg_60d_x_multiplier = c(avg60_var, svar) * sqrt(HOLD_DAYS) * BASEL_MULT
) |> mutate(capital = pmax(latest, avg_60d_x_multiplier))
basel25_total <- sum(basel25$capital)

# FRTB internal models approach (simplified):
#   97.5% ES, scaled to each risk factor's LIQUIDITY HORIZON, then combined:
#   ES = sqrt( ES_10(all)^2 + sum_j [ ES_10(factors with LH >= LH_j) * sqrt((LH_j - LH_{j-1})/10) ]^2 )
#   Liquidity horizons (MAR33): equity large cap 10d, major rates 10d,
#   energy and precious-metal commodities 20d. Simplification: 10-day ES is
#   the 1-day HS ES x sqrt(10), and we skip the stressed-period calibration.
lh <- c(SPY = 10, TLT = 10, XLE = 10, GLD = 20, USO = 20, UNG = 20)[names(w)]
es10_all  <- hs_es(pnl_win, ES_CONF) * sqrt(10)
pnl_lh20  <- as.numeric(R_win[, lh >= 20] %*% w[lh >= 20])
es10_lh20 <- hs_es(pnl_lh20, ES_CONF) * sqrt(10)
frtb_es   <- sqrt(es10_all^2 + (es10_lh20 * sqrt((20 - 10) / 10))^2)

reg_summary <- data.frame(
  measure = c("Basel 2.5: VaR + stressed VaR capital", "FRTB-style liquidity-adjusted ES (97.5%)",
              "  of which: 10-day ES, all factors", "  of which: 10-day ES, 20-day-horizon factors"),
  usd     = c(basel25_total, frtb_es, es10_all, es10_lh20)
)
print(reg_summary)


# ---- 5. Save tables ---------------------------------------------------------
step("Saving tables and figures")
save_table(var_summary, file.path(PATHS$tables, "03_var_es_by_method.csv"))
save_table(comp,        file.path(PATHS$tables, "03_component_var.csv"))
save_table(basel25,     file.path(PATHS$tables, "03_basel25_capital.csv"))
save_table(reg_summary, file.path(PATHS$tables, "03_regulatory_summary.csv"))
save_table(round(cor(R_win), 3) |> as.data.frame() |> tibble::rownames_to_column("ticker"),
           file.path(PATHS$tables, "03_correlation_matrix.csv"))


# ---- 6. Figures -------------------------------------------------------------

# (a) P&L distribution with VaR / ES lines and a fitted normal curve
p_dist <- ggplot(data.frame(pnl = pnl_win), aes(pnl / 1e3)) +
  geom_histogram(aes(y = after_stat(density)), bins = 50, fill = PALETTE["blue"],
                 colour = "white", linewidth = 0.2) +
  stat_function(fun = dnorm, args = list(mean = 0, sd = sigma_eq / 1e3),
                colour = COL_INK, linewidth = 0.6, linetype = "dashed") +
  geom_vline(xintercept = -hs["var"] / 1e3, colour = PALETTE["orange"], linewidth = 0.8) +
  geom_vline(xintercept = -hs["es"] / 1e3,  colour = COL_LOSS, linewidth = 0.8) +
  annotate("text", x = -hs["var"] / 1e3, y = Inf, vjust = 1.5, hjust = -0.05, size = 3.2,
           label = paste0("99% VaR\n", fmt_usd(hs["var"])), colour = PALETTE["orange"]) +
  annotate("text", x = -hs["es"] / 1e3, y = Inf, vjust = 1.5, hjust = 1.05, size = 3.2,
           label = paste0("97.5% ES\n", fmt_usd(hs["es"])), colour = COL_LOSS) +
  labs(title = "Distribution of daily P&L over the last 250 days",
       subtitle = "Bars: historical P&L. Dashed: normal curve with the same volatility. Fat left tail = normal model understates risk.",
       x = "Daily P&L ($ thousands)", y = "Density") +
  theme_risk()
save_plot(p_dist, file.path(PATHS$figures, "03_pnl_distribution.png"))

# (b) VaR and ES by method
vs_long <- var_summary |>
  select(method, `99% VaR` = var_99_1d, `97.5% ES` = es_975_1d) |>
  pivot_longer(-method) |>
  mutate(method = factor(method, levels = rev(var_summary$method)),
         name = factor(name, levels = c("99% VaR", "97.5% ES")))
p_methods <- ggplot(vs_long, aes(value / 1e3, method, fill = name)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  geom_text(aes(label = fmt_usd(value)), position = position_dodge(width = 0.75),
            hjust = -0.1, size = 3, colour = COL_INK) +
  scale_fill_manual(values = c(`99% VaR` = PALETTE[["blue"]], `97.5% ES` = PALETTE[["orange"]])) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.18))) +
  labs(title = "1-day VaR and ES by method", subtitle = paste("As of", format(as_of)),
       x = "$ thousands", y = NULL) +
  theme_risk()
save_plot(p_methods, file.path(PATHS$figures, "03_var_by_method.png"))

# (c) Component VaR
p_comp <- ggplot(comp, aes(component_var / 1e3, reorder(paste(ticker, "-", description), component_var))) +
  geom_col(aes(fill = component_var > 0), width = 0.6) +
  geom_vline(xintercept = 0, colour = COL_INK, linewidth = 0.3) +
  geom_text(aes(label = fmt_pct(pct_of_total, 0),
                hjust = ifelse(component_var > 0, -0.15, 1.15)), size = 3.2, colour = COL_INK) +
  scale_fill_manual(values = c(`TRUE` = COL_LOSS, `FALSE` = COL_GAIN), guide = "none") +
  scale_x_continuous(expand = expansion(mult = 0.2)) +
  labs(title = "Who drives the risk? Component VaR (99%, 1-day, EWMA)",
       subtitle = "Components add up to total VaR. Blue bars reduce portfolio risk (hedges).",
       x = "Contribution to VaR ($ thousands)", y = NULL) +
  theme_risk()
save_plot(p_comp, file.path(PATHS$figures, "03_component_var.png"))

# (d) Correlation heat map
cor_long <- as.data.frame(as.table(cor(R_win)))
p_cor <- ggplot(cor_long, aes(Var1, Var2, fill = Freq)) +
  geom_tile(colour = "white", linewidth = 1) +
  geom_text(aes(label = sprintf("%.2f", Freq)), size = 3.4) +
  scale_fill_gradient2(low = COL_GAIN, mid = COL_MID, high = COL_LOSS, midpoint = 0, limits = c(-1, 1)) +
  labs(title = "Return correlations, last 250 days",
       subtitle = "Diversification comes from low or negative correlations between positions.",
       x = NULL, y = NULL) +
  coord_equal() + theme_risk() + theme(legend.position = "right", panel.grid = element_blank())
save_plot(p_cor, file.path(PATHS$figures, "03_correlation_heatmap.png"), width = 7, height = 6)

# (e) Rolling 1-year HS VaR with the stressed window shaded
p_roll <- ggplot(data.frame(date = index(roll_var_xts), v = coredata(roll_var_xts)[, 1]), aes(date, v / 1e3)) +
  annotate("rect", xmin = stress_win[1], xmax = stress_win[2], ymin = -Inf, ymax = Inf,
           fill = COL_LOSS, alpha = 0.12) +
  geom_line(colour = PALETTE["blue"], linewidth = 0.6, na.rm = TRUE) +
  annotate("text", x = stress_win[2], y = svar / 1e3, hjust = -0.1, size = 3.2, colour = COL_LOSS,
           label = paste0("Stressed window\nsVaR = ", fmt_usd(svar))) +
  labs(title = "Rolling 1-year historical VaR (99%, 1-day) of today's portfolio",
       subtitle = "The peak marks the stressed period Basel 2.5 uses for stressed VaR.",
       x = NULL, y = "$ thousands") +
  theme_risk()
save_plot(p_roll, file.path(PATHS$figures, "03_rolling_var_stressed_window.png"))

saveRDS(list(as_of = as_of, var_summary = var_summary, comp = comp,
             diversification = diversification, svar = svar, stress_win = stress_win,
             basel25 = basel25, basel25_total = basel25_total, frtb_es = frtb_es,
             reg_summary = reg_summary, gross = gross, cov_ewma = cov_ewma),
        file.path(PATHS$processed, "risk_metrics.rds"))
