# =============================================================================
#  05_cva_and_capital.R  |  CVA, wrong-way risk, and regulatory capital
# =============================================================================
#
#  What this does
#    1. CVA: the price of counterparty default risk, per counterparty
#    2. CS01: how much CVA moves when credit spreads widen 1bp
#    3. Wrong-way risk (WWR): CVA when default risk rises exactly when
#       exposure is high
#    4. SA-CCR: the standardised regulatory exposure (EAD)
#    5. Capital: IRB default-risk capital and BA-CVA capital
#
#  How the pieces connect
#    Simulation (04) -> EE profile -> CVA (accounting / pricing)
#                                  -> EEPE -> IMM EAD (internal-model capital)
#    Trade details   -> SA-CCR EAD -> IRB capital (default risk)
#                                  -> BA-CVA capital (CVA volatility risk)
# -----------------------------------------------------------------------------

source("counterparty-credit-risk/config.R")
source("counterparty-credit-risk/ccr_functions.R")
mkt    <- readRDS(file.path(PATHS$processed, "market.rds"))$mkt
trades <- readRDS(file.path(PATHS$processed, "trades.rds"))$trades
ex     <- readRDS(file.path(PATHS$processed, "exposure.rds"))
cptys  <- COUNTERPARTIES |> left_join(mkt$spreads |> select(rating, spread), by = "rating")
t_grid <- ex$grid


# ---- 1. CVA and CS01 --------------------------------------------------------
step("CVA by counterparty")
cva_tbl <- bind_rows(lapply(seq_len(nrow(cptys)), function(i) {
  cp <- cptys[i, ]
  pr <- ex$profiles |> filter(cpty == cp$cpty, basis == "With collateral")
  cva <- cva_from_profile(pr$t, pr$EE_disc, cp$spread, LGD_MKT)
  cva_bumped <- cva_from_profile(pr$t, pr$EE_disc, cp$spread + 0.0001, LGD_MKT)
  data.frame(cpty = cp$cpty, rating = cp$rating, spread_bp = cp$spread * 1e4,
             hazard = cp$spread / LGD_MKT, cva = cva, cs01 = cva_bumped - cva)
}))
print(cva_tbl |> mutate(across(where(is.numeric), ~ round(.x, 4))))


# ---- 2. Wrong-way risk ------------------------------------------------------
# Link each counterparty's default intensity to the oil price on each path:
#   lambda_path(t) = lambda x exp(b z(t))
# z(t) is the standardised oil move (a N(0,1) number under the model).
# Default probabilities are rescaled so the AVERAGE default rate is
# unchanged; any change in CVA comes only from the default-exposure link.
#   Fund D is long oil (bank is short): bank's exposure is highest when oil
#   falls, which is exactly when an oil-long fund is weakest -> WRONG-WAY.
#   Airline C: bank's exposure is highest when oil falls, when the airline
#   is strongest -> RIGHT-WAY.
step("Wrong-way risk")
X0 <- log(mkt$wti_spot)
mv <- schwartz_mean_var(X0, t_grid, mkt$wti)
z_oil <- sweep(sweep(ex$X, 2, mv$mean, `-`), 2, sqrt(pmax(mv$var, 1e-12)), `/`)
z_oil[, 1] <- 0

wwr_tbl <- bind_rows(lapply(seq_len(nrow(cptys)), function(i) {
  cp <- cptys[i, ]
  sgn <- switch(cp$credit_link, worse_when_oil_falls = -1, worse_when_oil_rises = 1, none = 0)
  lam <- cp$spread / LGD_MKT
  E   <- ex$E[[cp$cpty]]
  indep  <- pathwise_cva(E, ex$D, t_grid, lam, z_oil, 0, LGD_MKT)
  linked <- pathwise_cva(E, ex$D, t_grid, lam, sgn * z_oil, WWR_B * abs(sgn), LGD_MKT)  # b = 0 if no link
  # Conditional EE at 1 year: exposure on paths where oil is in its worst 10%
  k1 <- which.min(abs(t_grid - 1))
  low_oil <- ex$X[, k1] <= quantile(ex$X[, k1], 0.10)
  data.frame(cpty = cp$cpty, credit_link = cp$credit_link,
             cva_independent = mean(indep), cva_with_link = mean(linked),
             cva_se = sd(indep) / sqrt(length(indep)),
             ee_1y_all_paths = mean(E[, k1]), ee_1y_low_oil_paths = mean(E[low_oil, k1]))
})) |>
  mutate(wwr_effect = cva_with_link / cva_independent - 1,
         classification = case_when(credit_link == "none" ~ "No link modelled",
                                    wwr_effect > 0.02 ~ "Wrong-way",
                                    wwr_effect < -0.02 ~ "Right-way",
                                    TRUE ~ "Neutral"))
print(wwr_tbl |> mutate(across(where(is.numeric), ~ round(.x, 3))))


# ---- 3. SA-CCR --------------------------------------------------------------
step("SA-CCR exposure at default")
saccr_tbl <- bind_rows(lapply(seq_len(nrow(cptys)), function(i) {
  cp  <- cptys[i, ]
  tr  <- trades |> filter(cpty == cp$cpty)
  es  <- ex$exposure_summary |> filter(cpty == cp$cpty)
  res <- saccr(tr, V = es$mtm_today, C = es$collateral_today, csa = cp$csa,
               threshold = ifelse(cp$csa, cp$threshold, 0), mta = ifelse(cp$csa, cp$mta, 0),
               mpor_days = ifelse(cp$csa, cp$mpor_days, 10))
  data.frame(cpty = cp$cpty, mtm = es$mtm_today, collateral = es$collateral_today,
             rc = res$rc, addon_ir = res$addons[["IR"]], addon_fx = res$addons[["FX"]],
             addon_cmdty = res$addons[["COMMODITY"]], multiplier = res$multiplier,
             pfe_addon = res$pfe, saccr_ead = res$ead,
             eff_maturity = sum(tr$usd_notional * tr$maturity) / sum(tr$usd_notional))   # notional-weighted
}))
print(saccr_tbl |> mutate(across(where(is.numeric), ~ round(.x, 2))))


# ---- 4. Capital -------------------------------------------------------------
step("Regulatory capital")

# IRB default-risk capital, using SA-CCR EAD. Foundation IRB LGDs:
# 45% for financial institutions, 40% for other corporates (Basel III final).
irb <- irb_capital(pd = PD_BY_RATING[cptys$rating],
                   lgd = ifelse(cptys$is_financial, 0.45, 0.40),
                   M = saccr_tbl$eff_maturity, is_financial = cptys$is_financial)
irb$cpty <- cptys$cpty
irb$ead  <- saccr_tbl$saccr_ead
irb$rwa  <- 12.5 * irb$K * irb$ead

# BA-CVA reduced: capital for the risk that CVA itself moves
bacva <- ba_cva_reduced(ead = saccr_tbl$saccr_ead, M = saccr_tbl$eff_maturity,
                        bucket = cptys$ba_cva_bucket, rating = cptys$rating)

capital_tbl <- data.frame(
  cpty         = cptys$cpty,
  name         = cptys$name,
  rating       = cptys$rating,
  mtm          = saccr_tbl$mtm,
  saccr_ead    = saccr_tbl$saccr_ead,
  imm_ead      = ex$exposure_summary$imm_ead,
  cva          = cva_tbl$cva,
  cva_wwr      = wwr_tbl$cva_with_link,
  irb_pd       = irb$pd,
  irb_rwa      = irb$rwa,
  ba_cva_rw    = bacva$rw,
  ba_cva_scva  = bacva$scva
)
totals <- data.frame(
  measure = c("Total CVA", "Total SA-CCR EAD", "Total IMM-style EAD",
              "IRB default-risk RWA", "BA-CVA capital", "BA-CVA RWA", "Total CCR RWA (IRB + BA-CVA)"),
  usd = c(sum(capital_tbl$cva), sum(capital_tbl$saccr_ead), sum(capital_tbl$imm_ead),
          sum(irb$rwa), bacva$capital, bacva$rwa, sum(irb$rwa) + bacva$rwa)
)
print(capital_tbl |> mutate(across(where(is.numeric), ~ round(.x, 4))))
print(totals)


# ---- 5. Save ----------------------------------------------------------------
step("Saving")
save_table(cva_tbl,     file.path(PATHS$tables, "05_cva.csv"))
save_table(wwr_tbl,     file.path(PATHS$tables, "05_wrong_way_risk.csv"))
save_table(saccr_tbl,   file.path(PATHS$tables, "05_saccr.csv"))
save_table(capital_tbl, file.path(PATHS$tables, "05_capital_by_counterparty.csv"))
save_table(totals,      file.path(PATHS$tables, "05_capital_totals.csv"))
saveRDS(list(cva_tbl = cva_tbl, wwr_tbl = wwr_tbl, saccr_tbl = saccr_tbl, capital_tbl = capital_tbl,
             totals = totals, z_oil = z_oil),
        file.path(PATHS$processed, "cva_capital.rds"))


# ---- 6. Figures -------------------------------------------------------------
name_of <- setNames(cptys$name, cptys$cpty)

cva_long <- wwr_tbl |>
  select(cpty, `Independent` = cva_independent, `Oil-credit link` = cva_with_link) |>
  pivot_longer(-cpty) |> mutate(cpty = name_of[cpty])
p_cva <- ggplot(cva_long, aes(value / 1e3, cpty, fill = name)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  geom_text(aes(label = fmt_usd(value)), position = position_dodge(width = 0.75), hjust = -0.1,
            size = 3, colour = COL_INK) +
  scale_fill_manual(values = c(Independent = PALETTE[["blue"]], `Oil-credit link` = PALETTE[["orange"]])) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.25))) +
  labs(title = "CVA by counterparty, with and without wrong-way risk",
       subtitle = paste(sprintf("%s: %s (%s)", name_of[wwr_tbl$cpty], tolower(wwr_tbl$classification),
                                fmt_pct(wwr_tbl$wwr_effect, 0))[wwr_tbl$credit_link != "none"], collapse = " | "),
       x = "CVA ($ thousands)", y = NULL) +
  theme_risk()
save_plot(p_cva, file.path(PATHS$figures, "05_cva_wwr.png"), height = 4.5)

ead_long <- capital_tbl |>
  select(cpty, `SA-CCR EAD` = saccr_ead, `IMM-style EAD (1.4 x EEPE)` = imm_ead) |>
  pivot_longer(-cpty) |> mutate(cpty = name_of[cpty])
p_ead <- ggplot(ead_long, aes(value / 1e6, cpty, fill = name)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  geom_text(aes(label = fmt_usd(value)), position = position_dodge(width = 0.75), hjust = -0.1,
            size = 3, colour = COL_INK) +
  scale_fill_manual(values = c(`SA-CCR EAD` = PALETTE[["violet"]], `IMM-style EAD (1.4 x EEPE)` = PALETTE[["aqua"]])) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.25))) +
  labs(title = "Exposure at default: standardised (SA-CCR) vs. internal model",
       subtitle = "SA-CCR uses fixed supervisory factors; the simulation-based EAD reflects this portfolio's actual dynamics.",
       x = "EAD ($ millions)", y = NULL) +
  theme_risk()
save_plot(p_ead, file.path(PATHS$figures, "05_ead_comparison.png"), height = 4.5)

# Conditional exposure for the fund: all paths vs. low-oil paths over time
E_fund <- ex$E[["FUND_D"]]
cond <- bind_rows(lapply(seq_along(t_grid), function(k) {
  low <- ex$X[, k] <= quantile(ex$X[, k], 0.10)
  data.frame(t = t_grid[k], `All paths` = mean(E_fund[, k]),
             `Oil in worst 10% of paths` = mean(E_fund[low, k]), check.names = FALSE)
})) |> pivot_longer(-t) |> filter(t <= 1.5)
p_cond <- ggplot(cond, aes(t, value / 1e6, colour = name)) +
  geom_line(linewidth = 0.8) +
  scale_colour_manual(values = c(`All paths` = PALETTE[["blue"]], `Oil in worst 10% of paths` = COL_LOSS)) +
  labs(title = "Wrong-way risk: exposure to Energy Hedge Fund D when oil falls",
       subtitle = sprintf("At 1 year, expected exposure on low-oil paths is %.1fx the average: highest when an oil-long fund is weakest.",
                          wwr_tbl$ee_1y_low_oil_paths[wwr_tbl$cpty == "FUND_D"] / wwr_tbl$ee_1y_all_paths[wwr_tbl$cpty == "FUND_D"]),
       x = "Years from today", y = "Expected exposure ($ millions)") +
  theme_risk()
save_plot(p_cond, file.path(PATHS$figures, "05_wwr_conditional_exposure.png"), height = 4.5)
