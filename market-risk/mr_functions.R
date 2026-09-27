# =============================================================================
#  mr_functions.R  |  Market risk building blocks
# =============================================================================
#
#  Sign convention used everywhere:
#    P&L   > 0 is a gain, P&L < 0 is a loss.
#    VaR and ES are reported as POSITIVE loss amounts.
#    A VaR "exception" (or breach) is a day where  loss = -P&L  >  VaR.
#
#  Contents
#    1. VaR / ES estimators
#    2. EWMA volatility
#    3. Risk decomposition (component VaR)
#    4. Backtesting tests
# -----------------------------------------------------------------------------


# ---- 1. VaR / ES estimators -------------------------------------------------

# Historical simulation: read VaR and ES straight off the empirical P&L
# distribution. No distribution assumption; only as good as the window.
hs_var <- function(pnl, conf) {
  unname(quantile(-pnl, probs = conf, type = 7))
}
hs_es <- function(pnl, conf) {
  losses <- -pnl
  mean(losses[losses >= quantile(losses, probs = conf, type = 7)])
}

# Parametric (normal): VaR = z * sigma, ES = sigma * phi(z) / (1 - conf).
# Mean is set to zero, the standard convention for 1-day horizons (the
# daily mean is tiny and noisy; assuming zero is slightly conservative).
normal_var <- function(sigma, conf) sigma * qnorm(conf)
normal_es  <- function(sigma, conf) sigma * dnorm(qnorm(conf)) / (1 - conf)


# ---- 2. EWMA volatility -----------------------------------------------------
# RiskMetrics (1996):  sigma^2[t] = lambda * sigma^2[t-1] + (1 - lambda) * r^2[t-1]
# Recent days get more weight, so EWMA reacts quickly when markets get
# volatile. Returns the FORECAST vol for each day, using data up to the day
# before (so it can be used out-of-sample in the backtest).
#
# Works on a vector (one series) or a matrix (one column per asset).

ewma_vol <- function(x, lambda, init_n = 30) {
  x <- as.matrix(x)
  n <- nrow(x)
  var_t <- matrix(NA_real_, n, ncol(x), dimnames = dimnames(x))
  var_t[1, ] <- apply(x[1:init_n, , drop = FALSE], 2, var)   # seed value
  for (t in 2:n) {
    var_t[t, ] <- lambda * var_t[t - 1, ] + (1 - lambda) * x[t - 1, ]^2
  }
  sqrt(var_t)
}

# EWMA covariance matrix at the END of the sample (used for today's VaR)
ewma_cov <- function(R, lambda) {
  R <- as.matrix(R)
  S <- cov(R[1:30, ])
  for (t in seq_len(nrow(R))) S <- lambda * S + (1 - lambda) * tcrossprod(R[t, ])
  S
}


# ---- 3. Risk decomposition (component VaR) -----------------------------------
# Euler allocation under the normal model:
#   marginal VaR_i  = z * (Cov %*% w)_i / sigma_p     (VaR change per $1 added)
#   component VaR_i = w_i * marginal VaR_i            (sums exactly to total VaR)
# A NEGATIVE component means the position hedges the rest of the book.

component_var <- function(positions, cov_mat, conf) {
  sigma_p   <- sqrt(as.numeric(t(positions) %*% cov_mat %*% positions))
  marginal  <- qnorm(conf) * as.numeric(cov_mat %*% positions) / sigma_p
  component <- positions * marginal
  standalone <- qnorm(conf) * abs(positions) * sqrt(diag(cov_mat))
  data.frame(
    ticker          = names(positions),
    position_usd    = positions,
    standalone_var  = standalone,
    marginal_var    = marginal,        # $ of VaR per $1 of position
    component_var   = component,
    pct_of_total    = component / sum(component),
    row.names = NULL
  )
}


# ---- 4. Backtesting tests ---------------------------------------------------

# Kupiec (1995) proportion-of-failures test.
# H0: the exception rate equals 1 - conf. LR ~ chi-squared(1).
kupiec_test <- function(exceptions, conf) {
  n <- length(exceptions); x <- sum(exceptions); p <- 1 - conf
  phat <- x / n
  ll_null <- (n - x) * log(1 - p) + x * log(p)
  ll_alt  <- ifelse(x == 0, n * log(1),
             ifelse(x == n, n * log(1), (n - x) * log(1 - phat) + x * log(phat)))
  lr <- -2 * (ll_null - ll_alt)
  c(LR_pof = lr, p_pof = 1 - pchisq(lr, df = 1))
}

# Christoffersen (1998) independence test.
# H0: an exception today does not make one tomorrow more likely.
# Clustered exceptions mean the model is too slow to react to volatility.
christoffersen_test <- function(exceptions) {
  e <- as.integer(exceptions)
  prev <- head(e, -1); curr <- tail(e, -1)
  n00 <- sum(prev == 0 & curr == 0); n01 <- sum(prev == 0 & curr == 1)
  n10 <- sum(prev == 1 & curr == 0); n11 <- sum(prev == 1 & curr == 1)
  xlogy <- function(n, p) ifelse(n == 0, 0, n * log(p))   # treats 0*log(0) as 0
  pi01 <- n01 / max(n00 + n01, 1)
  pi11 <- n11 / max(n10 + n11, 1)
  pi   <- (n01 + n11) / (n00 + n01 + n10 + n11)
  ll_null <- xlogy(n00 + n10, 1 - pi) + xlogy(n01 + n11, pi)
  ll_alt  <- xlogy(n00, 1 - pi01) + xlogy(n01, pi01) + xlogy(n10, 1 - pi11) + xlogy(n11, pi11)
  lr <- -2 * (ll_null - ll_alt)
  c(LR_ind = lr, p_ind = 1 - pchisq(lr, df = 1))
}

# Basel traffic light for 99% VaR over 250 days (BCBS 1996, still in MAR99).
# Green 0-4, Yellow 5-9, Red 10+. The "plus factor" is added to the
# capital multiplier of 3 when a bank lands in yellow or red.
traffic_light <- function(n_exceptions) {
  cut(n_exceptions, breaks = c(-Inf, 4, 9, Inf), labels = c("Green", "Yellow", "Red"))
}
basel_plus_factor <- function(n_exceptions) {
  lookup <- c(`5` = 0.40, `6` = 0.50, `7` = 0.65, `8` = 0.75, `9` = 0.85)
  ifelse(n_exceptions <= 4, 0,
  ifelse(n_exceptions >= 10, 1, lookup[as.character(n_exceptions)]))
}

# Acerbi & Szekely (2014) "Z2" test for Expected Shortfall.
#   Z2 = 1 - sum( L_t * I_t / ES_t ) / (T * alpha)
# where I_t flags a breach of the VaR at the same level as ES (97.5%) and
# alpha = 1 - ES_CONF. E[Z2] = 0 if ES is right. Negative -> ES too small.
# Approximate critical values from the paper: -0.70 (5%) and -1.80 (0.01%).
es_z2_test <- function(losses, var_at_es_level, es, es_conf) {
  alpha <- 1 - es_conf
  breach <- losses > var_at_es_level
  1 - sum(losses[breach] / es[breach]) / (length(losses) * alpha)
}
