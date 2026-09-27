# =============================================================================
#  ccr_functions.R  |  Counterparty credit risk building blocks
# =============================================================================
#
#  Contents
#    1. Yield curve (today's discount factors and forward rates)
#    2. Risk-factor models
#         Rates: Hull-White one-factor short-rate model
#         FX:    lognormal (GBM) with interest-rate-parity drift
#         Oil:   Schwartz one-factor mean-reverting model
#    3. Monte Carlo simulation of all three factors, correlated
#    4. Trade pricing (IRS, FX forward, WTI swap) on every simulated path
#    5. Collateral and exposure metrics (EE, PFE, EEPE)
#    6. CVA
#    7. Regulatory formulas: SA-CCR, BA-CVA, IRB
#
#  Sign convention: V > 0 means the counterparty owes the bank (an asset).
#  Exposure = max(V - collateral, 0): only positive values are at risk.
# -----------------------------------------------------------------------------


# ---- 1. Yield curve ---------------------------------------------------------
# Treasury constant-maturity yields are semi-annual par yields in percent.
# Simplification: convert each to a continuously compounded rate and treat it
# as the zero rate for that tenor, then interpolate linearly. (Production
# systems bootstrap a SOFR OIS curve from swap quotes instead.)

cmt_to_zero <- function(y_pct) 2 * log(1 + y_pct / 200)

make_curve <- function(tenors, zero_rates) list(tenors = tenors, zeros = zero_rates)

zero_rate <- function(curve, T) {
  approx(curve$tenors, curve$zeros, xout = pmax(T, 1e-8), rule = 2)$y   # flat beyond ends
}

P0 <- function(curve, T) exp(-zero_rate(curve, T) * T)                # today's discount factor

f0 <- function(curve, t, h = 1e-4) {                                    # instantaneous forward rate
  t1 <- pmax(t - h, 0); t2 <- t + h
  -(log(P0(curve, t2)) - log(P0(curve, t1))) / (t2 - t1)
}


# ---- 2a. Hull-White one-factor rates model ----------------------------------
#   dr = [theta(t) - a r] dt + sigma dW
# theta(t) is chosen so the model reproduces today's curve exactly.
# Write r(t) = x(t) + alpha(t), where x is a simple mean-reverting process
# starting at zero and alpha(t) is a deterministic shift fitted to the curve.
# Zero-coupon bond prices have a closed form, so any swap can be repriced on
# any path at any future date without nested simulation.

hw_B <- function(a, tau) (1 - exp(-a * tau)) / a

hw_alpha <- function(curve, a, sigma, t) {
  f0(curve, t) + sigma^2 / (2 * a^2) * (1 - exp(-a * t))^2
}

# Price at time t of zero-coupon bonds maturing at each T, on each path.
# r: vector of short rates (one per path). Returns a paths x length(T) matrix.
hw_zcb <- function(curve, a, sigma, t, T, r) {
  B   <- hw_B(a, T - t)
  lnA <- log(P0(curve, T) / P0(curve, t)) + B * f0(curve, t) -
         sigma^2 / (4 * a) * (1 - exp(-2 * a * t)) * B^2
  exp(outer(-r, B) + matrix(lnA, length(r), length(T), byrow = TRUE))
}


# ---- 2b. Schwartz one-factor oil model --------------------------------------
#   X = ln(S),   dX = kappa (alpha - X) dt + sigma dW
# Oil prices mean-revert: high prices bring new supply, low prices cut it.
# Expected future price (the model forward) has a closed form:
#   F(t, T) = exp( X e^{-k tau} + alpha (1 - e^{-k tau}) + sigma^2 (1 - e^{-2 k tau}) / (4k) )

schwartz_mean_var <- function(X, tau, p) {
  e <- exp(-p$kappa * tau)
  list(mean = X * e + p$alpha * (1 - e),
       var  = p$sigma^2 * (1 - exp(-2 * p$kappa * tau)) / (2 * p$kappa))
}

schwartz_fwd <- function(X, tau, p) {        # paths x length(tau) matrix
  e   <- exp(-p$kappa * tau)
  add <- p$alpha * (1 - e) + p$sigma^2 * (1 - exp(-2 * p$kappa * tau)) / (4 * p$kappa)
  exp(outer(X, e) + matrix(add, length(X), length(tau), byrow = TRUE))
}

# Calibrate from daily log prices with an AR(1) regression:
#   X[t+1] = c + phi X[t] + e   ->   kappa = -ln(phi) * 252,  alpha = c / (1 - phi)
calibrate_schwartz <- function(log_px) {
  fit <- lm(log_px[-1] ~ log_px[-length(log_px)])
  c_  <- coef(fit)[[1]]; phi <- coef(fit)[[2]]
  kappa_raw <- if (phi < 1) -log(phi) * 252 else 0
  kappa <- min(max(kappa_raw, 0.10), 3)             # keep within sensible bounds
  # Long-run level: from the regression if it is well defined, else the sample mean
  alpha <- if (kappa_raw >= 0.10 && kappa_raw <= 3) c_ / (1 - phi) else mean(log_px)
  sigma <- sd(resid(fit)) * sqrt(2 * kappa / (1 - exp(-2 * kappa / 252)))
  list(kappa = kappa, alpha = alpha, sigma = sigma, half_life_yrs = log(2) / kappa)
}


# ---- 3. Monte Carlo simulation ----------------------------------------------
# Simulates the short rate, EURUSD and log WTI on a time grid, with
# correlated shocks (Cholesky of the historical correlation matrix).
# Also tracks the discount factor D(t) = exp(-integral of r) on each path,
# which CVA needs to discount future exposure.
#
# Measure: rates and FX use risk-neutral drifts (CVA is a price), while
# volatilities and correlations are estimated from history. Oil uses the
# historically calibrated model. Mixing measures like this is common in
# practice; a pure PFE system would use real-world drifts throughout.

simulate_factors <- function(grid, n_paths, mkt, seed) {
  set.seed(seed)
  nT <- length(grid); a <- mkt$hw_a; s <- mkt$hw_sigma; w <- mkt$wti
  Lc <- chol(mkt$corr)
  x <- r <- lnS <- X <- D <- matrix(0, n_paths, nT)
  r[, 1]   <- hw_alpha(mkt$curve, a, s, 0)
  lnS[, 1] <- log(mkt$fx_spot)
  X[, 1]   <- log(mkt$wti_spot)
  D[, 1]   <- 1

  for (k in 2:nT) {
    h <- grid[k] - grid[k - 1]
    Z <- matrix(rnorm(n_paths * 3), n_paths) %*% Lc      # correlated N(0,1) shocks

    # Rates: exact OU step for x, then shift by alpha(t)
    x[, k] <- x[, k - 1] * exp(-a * h) + s * sqrt((1 - exp(-2 * a * h)) / (2 * a)) * Z[, 1]
    r[, k] <- x[, k] + hw_alpha(mkt$curve, a, s, grid[k])
    D[, k] <- D[, k - 1] * exp(-0.5 * (r[, k - 1] + r[, k]) * h)    # trapezoid rule

    # FX: drift = USD rate - EUR rate (covered interest parity)
    lnS[, k] <- lnS[, k - 1] + (r[, k - 1] - mkt$r_eur - 0.5 * mkt$fx_vol^2) * h +
                mkt$fx_vol * sqrt(h) * Z[, 2]

    # Oil: exact OU step on log price
    e <- exp(-w$kappa * h)
    X[, k] <- X[, k - 1] * e + w$alpha * (1 - e) +
              w$sigma * sqrt((1 - exp(-2 * w$kappa * h)) / (2 * w$kappa)) * Z[, 3]
  }
  list(grid = grid, r = r, S = exp(lnS), X = X, D = D)
}


# ---- 4. Trade pricing -------------------------------------------------------
# Each pricer returns one value per path at time t. After a trade's last
# payment it returns zero (the trade has matured).
# Convention: a payment due ON date t still counts at t (exposure is measured
# just before settlement). Otherwise a collateralised netting set shows a
# false exposure spike on settlement dates: collateral still reflects the
# trade, but the trade has vanished from the portfolio value.

# Interest rate swap, semi-annual fixed vs floating, clean value (accrued
# interest ignored on both legs). Floating leg ~ notional x (1 - P(t, T_n)).
# Because the value is clean, it does not jump on coupon dates, so the
# "payment due today" convention above makes no difference for swaps.
price_irs <- function(tr, t, r, mkt) {
  pay <- seq(0.5, tr$maturity, by = 0.5)
  pay <- pay[pay > t + 1e-9]
  if (length(pay) == 0) return(rep(0, length(r)))
  P     <- hw_zcb(mkt$curve, mkt$hw_a, mkt$hw_sigma, t, pay, r)
  accr  <- pmin(diff(c(t, pay)), 0.5)                    # first period may be partial
  float <- 1 - P[, ncol(P)]
  fixed <- tr$strike * as.numeric(P %*% accr)
  tr$direction * tr$notional * (float - fixed)
}

# FX forward: exchange EUR notional for USD at the strike on the maturity date.
#   value (USD) = notional x (S e^{-r_eur tau} - K P_usd(t, T))
price_fxfwd <- function(tr, t, r, S, mkt) {
  if (t > tr$maturity + 1e-9) return(rep(0, length(r)))
  tau   <- tr$maturity - t
  P_usd <- hw_zcb(mkt$curve, mkt$hw_a, mkt$hw_sigma, t, tr$maturity, r)[, 1]
  tr$direction * tr$notional * (S * exp(-mkt$r_eur * tau) - tr$strike * P_usd)
}

# WTI fixed-for-floating swap, monthly settlement on the spot price.
#   value = barrels/month x sum over remaining months of (F(t, T_i) - K) P(t, T_i)
price_wti_swap <- function(tr, t, r, X, mkt) {
  fix <- seq(1 / 12, tr$maturity, by = 1 / 12)
  fix <- fix[fix >= t - 1e-9]                            # includes a fixing due today
  if (length(fix) == 0) return(rep(0, length(r)))
  Fwd <- schwartz_fwd(X, fix - t, mkt$wti)
  P   <- hw_zcb(mkt$curve, mkt$hw_a, mkt$hw_sigma, t, fix, r)
  tr$direction * tr$notional * rowSums((Fwd - tr$strike) * P)
}

price_trade <- function(tr, k, sims, mkt) {
  t <- sims$grid[k]
  switch(tr$type,
    IRS   = price_irs(tr, t, sims$r[, k], mkt),
    FXFWD = price_fxfwd(tr, t, sims$r[, k], sims$S[, k], mkt),
    WTI   = price_wti_swap(tr, t, sims$r[, k], sims$X[, k], mkt))
}


# Price a whole trade book today (t = 0), reusing the Monte Carlo pricers
# on a single "path". At t = 0 the Hull-White bond formula returns today's curve.
today_state <- function(mkt) {
  list(grid = 0, r = matrix(hw_alpha(mkt$curve, mkt$hw_a, mkt$hw_sigma, 0)),
       S = matrix(mkt$fx_spot), X = matrix(log(mkt$wti_spot)))
}
price_book <- function(trades, mkt) {
  st <- today_state(mkt)
  sapply(seq_len(nrow(trades)), function(i) price_trade(trades[i, ], 1, st, mkt))
}

# Shift today's market for sensitivities and stress tests
bump_market <- function(mkt, rates_bp = 0, fx_pct = 0, oil_pct = 0, oil_abs = 0) {
  mkt$curve$zeros <- mkt$curve$zeros + rates_bp / 1e4     # parallel shift of the zero curve
  mkt$fx_spot  <- mkt$fx_spot * (1 + fx_pct)
  mkt$wti_spot <- mkt$wti_spot * (1 + oil_pct) + oil_abs
  mkt
}


# ---- 5. Collateral and exposure metrics -------------------------------------
# Variation margin under a two-way CSA. Collateral reflects the portfolio
# value one margin period of risk (MPOR) ago: the counterparty stops posting,
# and the bank needs MPOR days to close out. Threshold + MTA is treated as
# one effective threshold (a standard simplification).
collateral_held <- function(V_lagged, threshold, mta) {
  th <- threshold + mta
  ifelse(V_lagged > th, V_lagged - th, ifelse(V_lagged < -th, V_lagged + th, 0))
}

# Exposure profile over time from a paths x dates exposure matrix
exposure_profile <- function(E, D, t, q) {
  data.frame(t = t,
             EE      = colMeans(E),                         # expected exposure
             PFE     = apply(E, 2, quantile, probs = q),    # potential future exposure
             EE_disc = colMeans(E * D))                     # discounted EE (for CVA)
}

# Basel IMM measures over the first year:
#   Effective EE  = running maximum of EE (exposure assumed not to roll off)
#   EEPE          = time-average of Effective EE    ->   IMM EAD = alpha x EEPE
eepe <- function(t, EE, horizon = 1) {
  keep <- t <= horizon + 1e-9
  eee  <- cummax(EE[keep])
  dt   <- diff(t[keep])
  sum(eee[-1] * dt) / sum(dt)
}


# ---- 6. CVA -----------------------------------------------------------------
# CVA = LGD x sum_i  EE_disc(t_i) x [S(t_{i-1}) - S(t_i)]
# S(t) = exp(-lambda t) is the survival probability. The hazard rate comes
# from the credit spread via the "credit triangle":  lambda = spread / LGD.
cva_from_profile <- function(t, EE_disc, spread, lgd) {
  lambda <- spread / lgd
  surv   <- exp(-lambda * t)
  pd_int <- c(0, -diff(surv))                    # default probability in each interval
  lgd * sum(EE_disc * pd_int)
}


# Path-by-path CVA, allowing the default intensity to depend on the path
# (used for wrong-way risk). With b = 0 it matches cva_from_profile().
#   lambda_path(t) = lambda x exp(b z(t))
# The path default probabilities are then rescaled so that, on AVERAGE,
# the default probability in each interval equals the unlinked one. That
# way the only thing that changes CVA is the correlation between default
# and exposure, not the overall default rate.
# Returns one CVA contribution per path; their mean is the CVA and their
# standard deviation gives the Monte Carlo error.
pathwise_cva <- function(E, D, t_grid, lambda, z, b, lgd) {
  lam  <- lambda * exp(b * z)                                   # paths x dates
  dt   <- diff(t_grid)
  haz  <- lam[, -ncol(lam), drop = FALSE] * rep(dt, each = nrow(lam))
  cumH <- cbind(0, t(apply(haz, 1, cumsum)))                    # cumulative hazard
  surv <- exp(-cumH)
  dPD  <- cbind(0, surv[, -ncol(surv)] - surv[, -1])            # default prob per interval
  target <- c(0, -diff(exp(-lambda * t_grid)))                  # unlinked default prob per interval
  dPD  <- sweep(dPD, 2, ifelse(colMeans(dPD) > 0, target / colMeans(dPD), 0), `*`)
  lgd * rowSums(D * E * dPD)
}


# ---- 7. Regulatory formulas -------------------------------------------------

# SA-CCR (Basel CRE52): EAD = alpha x (RC + PFE)
#   RC  = replacement cost today (net of collateral)
#   PFE = multiplier x AddOn  (AddOn by asset class from supervisory factors)
# `tr` needs: asset_class (IR/FX/COMMODITY), direction, adj_notional,
# maturity, hedging_set.
saccr <- function(tr, V, C, csa, threshold = 0, mta = 0, mpor_days = 10, alpha = ALPHA) {

  addon_by_class <- function(mf) {
    D <- tr$direction * tr$adj_notional * mf            # effective notional per trade
    out <- c(IR = 0, FX = 0, COMMODITY = 0)

    ir <- tr$asset_class == "IR"                         # IR: 3 maturity buckets, partial offset
    if (any(ir)) {
      b  <- cut(tr$maturity[ir], c(-Inf, 1, 5, Inf), labels = FALSE)
      Db <- sapply(1:3, function(k) sum(D[ir][b == k]))
      en <- sqrt(Db[1]^2 + Db[2]^2 + Db[3]^2 + 1.4 * Db[1] * Db[2] +
                 1.4 * Db[2] * Db[3] + 0.6 * Db[1] * Db[3])
      out["IR"] <- 0.005 * en                            # supervisory factor 0.5%
    }
    fx <- tr$asset_class == "FX"                         # FX: full offset within a currency pair
    if (any(fx)) out["FX"] <- 0.04 * sum(abs(tapply(D[fx], tr$hedging_set[fx], sum)))
    co <- tr$asset_class == "COMMODITY"                  # Commodity: energy hedging set, 18%
    if (any(co)) {
      a_type <- 0.18 * tapply(D[co], tr$hedging_set[co], sum)
      out["COMMODITY"] <- sqrt((0.4 * sum(a_type))^2 + (1 - 0.4^2) * sum(a_type^2))
    }
    out
  }

  calc <- function(mf, margined) {
    addons <- addon_by_class(mf)
    addon  <- sum(addons)
    mult   <- min(1, 0.05 + 0.95 * exp((V - C) / (2 * 0.95 * addon)))  # credit for over-collateralisation / negative MTM
    rc     <- if (margined) max(V - C, threshold + mta, 0) else max(V - C, 0)
    list(rc = rc, addons = addons, addon = addon, multiplier = mult,
         pfe = mult * addon, ead = alpha * (rc + mult * addon))
  }

  unm <- calc(sqrt(pmin(pmax(tr$maturity, 10 / 250), 1)), margined = FALSE)
  if (!csa) return(unm)
  mar <- calc(rep(1.5 * sqrt(mpor_days / 250), nrow(tr)), margined = TRUE)
  if (mar$ead > unm$ead) unm else mar                    # margined EAD capped at unmargined
}

# Supervisory duration for IR adjusted notional (S = start, E = end, years)
supervisory_duration <- function(S, E) (exp(-0.05 * S) - exp(-0.05 * E)) / 0.05

# BA-CVA reduced version (Basel MAR50): capital for CVA volatility.
#   SCVA_c = RW_c x M x EAD x DF / alpha,   DF = (1 - e^{-0.05 M}) / (0.05 M)
#   K = 0.65 x sqrt( (0.5 sum SCVA)^2 + 0.75 sum SCVA^2 )
BA_CVA_RW <- data.frame(
  bucket = c("Sovereigns", "Local government", "Financials", "Basic materials/energy/industrials",
             "Consumer goods/transport", "Technology/telecom", "Health care/utilities", "Other"),
  ig = c(0.005, 0.010, 0.050, 0.030, 0.030, 0.020, 0.015, 0.050),
  hy = c(0.020, 0.040, 0.120, 0.070, 0.085, 0.055, 0.050, 0.120)
)
ba_cva_reduced <- function(ead, M, bucket, rating, alpha = ALPHA) {
  ig  <- rating %in% c("AAA", "AA", "A", "BBB")
  rw  <- ifelse(ig, BA_CVA_RW$ig[match(bucket, BA_CVA_RW$bucket)],
                    BA_CVA_RW$hy[match(bucket, BA_CVA_RW$bucket)])
  df  <- (1 - exp(-0.05 * M)) / (0.05 * M)
  scva <- rw * M * ead * df / alpha
  k   <- 0.65 * sqrt((0.5 * sum(scva))^2 + (1 - 0.5^2) * sum(scva^2))
  list(scva = scva, rw = rw, capital = k, rwa = 12.5 * k)
}

# IRB capital for default risk (Basel CRE31): the Vasicek one-factor model.
# K = LGD x [ N( (G(PD) + sqrt(R) G(0.999)) / sqrt(1-R) ) - PD ] x maturity adj.
# R (asset correlation) falls as PD rises; x1.25 for large financials.
irb_capital <- function(pd, lgd, M, is_financial) {
  pd  <- pmax(pd, 0.0005)                                     # Basel III PD floor 5bp
  w   <- (1 - exp(-50 * pd)) / (1 - exp(-50))
  R   <- (0.12 * w + 0.24 * (1 - w)) * ifelse(is_financial, 1.25, 1)
  b   <- (0.11852 - 0.05478 * log(pd))^2
  M   <- pmin(pmax(M, 1), 5)
  k   <- (lgd * pnorm((qnorm(pd) + sqrt(R) * qnorm(0.999)) / sqrt(1 - R)) - pd * lgd) *
         (1 + (M - 2.5) * b) / (1 - 1.5 * b)
  data.frame(pd = pd, R = R, K = k)
}
