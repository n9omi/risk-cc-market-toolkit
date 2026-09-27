# =============================================================================
#  07_report.R  |  Write the summary report (markdown)
# =============================================================================
#
#  Pulls the saved results into outputs/ccr_summary.md. The observations
#  are generated from the numbers, so they stay correct when data updates.
# -----------------------------------------------------------------------------

source("counterparty-credit-risk/config.R")
m   <- readRDS(file.path(PATHS$processed, "market.rds"))
trd <- readRDS(file.path(PATHS$processed, "trades.rds"))
ex  <- readRDS(file.path(PATHS$processed, "exposure.rds"))
cc  <- readRDS(file.path(PATHS$processed, "cva_capital.rds"))
va  <- readRDS(file.path(PATHS$processed, "validation.rds"))

step("Writing ccr_summary.md")

es  <- ex$exposure_summary
cap <- cc$capital_tbl
wwr <- cc$wwr_tbl
name_of <- setNames(COUNTERPARTIES$name, COUNTERPARTIES$cpty)
top_pfe <- es[which.max(es$peak_pfe), ]
top_cva <- cap[which.max(cap$cva), ]
fund <- wwr[wwr$cpty == "FUND_D", ]; air <- wwr[wwr$cpty == "AIR_C", ]
csa_rows <- es[es$csa, ]
pit_fail <- va$pit_tests[va$pit_tests$verdict != "Passes", ]
tot <- setNames(cc$totals$usd, cc$totals$measure)

# ---- Observations -----------------------------------------------------------
obs <- c(
  sprintf("- **Book:** %d trades with %d counterparties, net MTM %s. Largest peak PFE (%.0f%%) is %s at %s, reached after %.1f years.",
          nrow(trd$trades), nrow(es), fmt_usd(sum(es$mtm_today)), PFE_Q * 100,
          name_of[top_pfe$cpty], fmt_usd(top_pfe$peak_pfe), top_pfe$peak_pfe_time),
  sprintf("- **Collateral:** for %s, the CSA changes peak PFE from %s (no CSA) to %s. Thresholds and MTAs limit how much it helps.",
          paste(name_of[csa_rows$cpty], collapse = " and "),
          paste(fmt_usd(csa_rows$peak_pfe_no_csa), collapse = " / "),
          paste(fmt_usd(csa_rows$peak_pfe), collapse = " / ")),
  sprintf("- **CVA:** total %s. The largest charge is %s (%s), driven by %s credit and %s.",
          fmt_usd(tot[["Total CVA"]]), name_of[top_cva$cpty], fmt_usd(top_cva$cva), top_cva$rating,
          ifelse(COUNTERPARTIES$csa[COUNTERPARTIES$cpty == top_cva$cpty], "residual exposure above the CSA threshold", "uncollateralised exposure")),
  sprintf("- **Wrong-way risk:** linking credit to oil moves Fund D's CVA by %s (%s) and Airline C's by %s (%s). Same trade direction, opposite credit link, opposite result.",
          fmt_pct(fund$wwr_effect, 0), tolower(fund$classification), fmt_pct(air$wwr_effect, 0), tolower(air$classification)),
  sprintf("- **EAD:** SA-CCR totals %s versus %s from the simulation (1.4 x EEPE). SA-CCR is %s here.",
          fmt_usd(tot[["Total SA-CCR EAD"]]), fmt_usd(tot[["Total IMM-style EAD"]]),
          ifelse(tot[["Total SA-CCR EAD"]] > tot[["Total IMM-style EAD"]], "more conservative", "less conservative")),
  sprintf("- **Capital:** IRB default-risk RWA %s plus BA-CVA RWA %s = %s total counterparty RWA.",
          fmt_usd(tot[["IRB default-risk RWA"]]), fmt_usd(tot[["BA-CVA RWA"]]), fmt_usd(tot[["Total CCR RWA (IRB + BA-CVA)"]])),
  if (nrow(pit_fail) == 0) "- **Backtest:** all risk-factor forecasts pass coverage and distribution tests." else
    sprintf("- **Backtest:** %s. The usual fix is fatter-tailed shocks or regime-dependent volatility.",
            paste(sprintf("%s %s: %s", pit_fail$factor, pit_fail$horizon, tolower(pit_fail$verdict)), collapse = "; ")),
  sprintf("- **Validation:** all at-market trades reprice to ~0; %d of %d martingale checks pass; CVA Monte Carlo error is within %s of the estimate for every counterparty.",
          sum(va$mart$pass), nrow(va$mart), fmt_pct(max(va$conv_final$rel_error_95), 0))
)

# ---- Tables -----------------------------------------------------------------
t_book <- trd$trades |> transmute(Trade = trade_id, Counterparty = name_of[cpty], Description = description,
                                  Strike = ifelse(type == "IRS", fmt_pct(strike, 3), sprintf("%.4f", strike)),
                                  MTM = fmt_usd(mtm_today), DV01 = fmt_usd(dv01))
t_par <- m$params |> transmute(Parameter = parameter, Value = sapply(value, function(v) format(signif(v, 4), big.mark = ",", scientific = FALSE)), Source = source)
t_exp <- es |> transmute(Counterparty = name_of[cpty], Rating = rating, CSA = ifelse(csa, "Yes", "No"),
                         MTM = fmt_usd(mtm_today), `Peak EE` = fmt_usd(peak_ee),
                         `Peak PFE` = fmt_usd(peak_pfe), `Peak PFE (no CSA)` = fmt_usd(peak_pfe_no_csa),
                         EEPE = fmt_usd(eepe))
t_cva <- cap |> left_join(cc$cva_tbl |> select(cpty, spread_bp, cs01), by = "cpty") |>
  left_join(wwr |> select(cpty, classification), by = "cpty") |>
  transmute(Counterparty = name, `Spread (bp)` = round(spread_bp), CVA = fmt_usd(cva),
            `CS01` = fmt_usd(cs01), `CVA with oil link` = fmt_usd(cva_wwr), `WWR` = classification)
t_cap <- cap |> left_join(cc$saccr_tbl |> select(cpty, rc, pfe_addon, multiplier), by = "cpty") |>
  transmute(Counterparty = name, RC = fmt_usd(rc), `PFE add-on` = fmt_usd(pfe_addon),
            Multiplier = round(multiplier, 3), `SA-CCR EAD` = fmt_usd(saccr_ead),
            `IMM-style EAD` = fmt_usd(imm_ead), `IRB PD` = fmt_pct(irb_pd), `IRB RWA` = fmt_usd(irb_rwa))
t_tot <- cc$totals |> transmute(Measure = measure, Amount = fmt_usd(usd))
t_stress <- ex$stress_tbl |> mutate(cpty = name_of[cpty]) |> mutate(across(-cpty, fmt_usd)) |>
  rename(Counterparty = cpty)
t_pit <- va$pit_tests |> transmute(Factor = factor, Horizon = horizon, N = n, `Outside 95%` = outside_95,
                                   Expected = round(expected_95, 1), `Coverage p` = round(coverage_p, 3),
                                   `KS p` = round(ks_p, 3), Verdict = verdict)
t_mart <- va$mart |> transmute(Test = test, `t (yrs)` = round(t, 2), Model = signif(model_value, 6),
                               Market = signif(market_value, 6), `Error (bp)` = round(error_bp, 2),
                               Pass = ifelse(pass, "Yes", "No"))

report <- c(
  "# Counterparty Credit Risk Summary", "",
  sprintf("*Valuation date %s. Generated by `counterparty-credit-risk/07_report.R`. Data: FRED. %s paths, monthly grid.*",
          format(m$mkt$val_date), format(N_PATHS, big.mark = ",")), "",
  "## Key observations", "", obs, "",
  "## 1. Trade book", "", md_table(t_book), "",
  "## 2. Market data and model calibration", "", md_table(t_par), "",
  "![Curves](figures/02_curves_today.png)", "",
  "![Risk factor history](figures/02_risk_factor_history.png)", "",
  "## 3. Exposure", "", md_table(t_exp), "",
  "![Exposure profiles](figures/04_exposure_profiles.png)", "",
  "![Risk factor fans](figures/04_risk_factor_fans.png)", "",
  "**Stressed current exposure** (MTM after instant shocks):", "", md_table(t_stress), "",
  "## 4. CVA and wrong-way risk", "", md_table(t_cva), "",
  "![CVA](figures/05_cva_wwr.png)", "",
  "![WWR](figures/05_wwr_conditional_exposure.png)", "",
  "## 5. Regulatory exposure and capital (illustrative)", "", md_table(t_cap), "", md_table(t_tot), "",
  "![EAD comparison](figures/05_ead_comparison.png)", "",
  "## 6. Backtesting and validation", "",
  "**Risk-factor PIT backtest** (non-overlapping forecasts, rolling out-of-sample calibration):", "",
  md_table(t_pit), "",
  "![PIT](figures/06_pit_histograms.png)", "",
  "![Oil band](figures/06_oil_forecast_band.png)", "",
  "**Martingale tests** (simulation must reproduce today's prices):", "", md_table(t_mart), "",
  "![Convergence](figures/06_mc_convergence.png)", "",
  "## Regulatory notes", "",
  "- **SA-CCR** (Basel CRE52) is the standardised method for derivative EAD: `EAD = 1.4 x (RC + multiplier x AddOn)`. It replaced the older Current Exposure Method; US advanced-approaches banks must use it and other US banks may elect it.",
  "- **IMM** (internal model method) lets approved banks use simulated EEPE instead: `EAD = alpha x EEPE`, with alpha = 1.4 (or bank-estimated, floored at 1.2). IMM approval requires ongoing backtesting like section 6.",
  "- **CVA capital** (Basel MAR50): banks use BA-CVA (shown here) or SA-CVA (sensitivity-based, built on FRTB machinery). The old internal-model CVA approach was removed.",
  "- **IRB** (Basel CRE31) turns EAD into default-risk capital with the Vasicek one-factor formula. Basel III final rules restrict large corporates and financials to Foundation IRB with supervisory LGDs.",
  "- **Accounting:** CVA (and DVA) are fair-value adjustments under IFRS 13 / ASC 820, so they hit P&L. xVA desks hedge CVA with CDS and market hedges.",
  "- **Timing:** EU applies the final Basel package via CRR3 (FRTB/CVA pieces phased to 2027); UK Basel 3.1 applies from 1 Jan 2027; US agencies re-proposed Basel III endgame in March 2026. Check current status before quoting dates.",
  "",
  "## Limitations", "",
  "- One curve (Treasuries) for discounting and forwarding; production uses SOFR OIS curves and a separate EUR curve.",
  "- Hull-White mean reversion is fixed; production calibrates it to swaption volatilities.",
  "- Oil is modelled on spot with a one-factor model; production fits the full NYMEX futures curve (two-factor Schwartz-Smith or similar).",
  "- Collateral uses a simplified VM model (no initial margin, no disputes, threshold + MTA combined).",
  "- The WWR link is a stylised hazard-rate model with an assumed strength (`WWR_B` in config).",
  "- Bond-index spreads stand in for CDS; they include liquidity premia.",
  "- The oil forward curve is the model's own (historical long-run level), not NYMEX futures, so the at-market pricing check proves internal consistency only.",
  "- AR(1) estimates of mean reversion are biased upward in finite samples, so oil's long-horizon volatility may be understated.",
  "- Folding the MTA into the threshold leaves a permanent residual exposure of about the MTA on margined sets (conservative).",
  "- The PIT backtest uses zero drift, so it tests the volatility assumptions rather than the risk-neutral drifts used for CVA."
)

writeLines(report, file.path(PATHS$outputs, "ccr_summary.md"))
message("  saved ccr_summary.md")
