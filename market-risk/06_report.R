# =============================================================================
#  06_report.R  |  Write the summary report (markdown)
# =============================================================================
#
#  Pulls the saved results together into outputs/market_risk_summary.md.
#  GitHub renders it with tables and charts. The written observations are
#  generated from the numbers, so they stay correct when the data updates.
# -----------------------------------------------------------------------------

source("market-risk/config.R")
dat <- readRDS(file.path(PATHS$processed, "clean_data.rds"))
rm_ <- readRDS(file.path(PATHS$processed, "risk_metrics.rds"))
bt  <- readRDS(file.path(PATHS$processed, "backtest.rds"))
st  <- readRDS(file.path(PATHS$processed, "stress.rds"))

step("Writing market_risk_summary.md")

vs  <- rm_$var_summary
hs_var_ <- vs$var_99_1d[vs$method == "Historical simulation"]
ew_var_ <- vs$var_99_1d[vs$method == "EWMA normal (RiskMetrics)"]
hs_es_ratio <- vs$es_to_var[vs$method == "Historical simulation"]
top_driver <- rm_$comp[which.max(rm_$comp$component_var), ]
best_hedge <- rm_$comp[which.min(rm_$comp$component_var), ]
res <- bt$results
worst3 <- head(st$stress_tbl, 3)

# ---- Observations written from the numbers ----------------------------------
obs <- c(
  sprintf("- **Headline:** 1-day 99%% historical VaR is **%s** (%s of gross exposure); 97.5%% ES is **%s**.",
          fmt_usd(hs_var_), fmt_pct(hs_var_ / rm_$gross), fmt_usd(vs$es_975_1d[1])),
  if (ew_var_ > 1.1 * hs_var_) {
    sprintf("- **Volatility regime:** EWMA VaR (%s) is above historical VaR, so recent markets are more volatile than the past-year average. Expect HS to lag if volatility keeps rising.", fmt_usd(ew_var_))
  } else if (ew_var_ < 0.9 * hs_var_) {
    sprintf("- **Volatility regime:** EWMA VaR (%s) is below historical VaR, so recent markets are calmer than the past-year average. HS still carries older, larger moves in its window.", fmt_usd(ew_var_))
  } else {
    sprintf("- **Volatility regime:** EWMA VaR (%s) is close to historical VaR, so recent volatility is in line with the past year.", fmt_usd(ew_var_))
  },
  sprintf("- **Tail shape:** historical ES / VaR = %.2f. Under a normal distribution the ratio is ~1.00 at these confidence levels, so %s.",
          hs_es_ratio, ifelse(hs_es_ratio > 1.05, "the realised tail is fatter than normal", "the tail looks close to normal")),
  sprintf("- **Risk drivers:** %s contributes the most risk (%s of VaR). %s is the best hedge (%s of VaR). Diversification saves %s versus adding up standalone VaRs.",
          top_driver$ticker, fmt_pct(top_driver$pct_of_total, 0), best_hedge$ticker,
          fmt_pct(best_hedge$pct_of_total, 0), fmt_usd(rm_$diversification)),
  sprintf("- **Stressed VaR:** the worst 1-year window is %s to %s, giving sVaR of %s (%.1fx today's VaR).",
          format(rm_$stress_win[1]), format(rm_$stress_win[2]), fmt_usd(rm_$svar), rm_$svar / hs_var_),
  sprintf("- **Backtest:** %s", paste(sprintf("%s: %d exceptions vs %.0f expected (%s).",
          res$model, res$exceptions_99, res$expected_99, tolower(res$verdict)), collapse = " ")),
  sprintf("- **Stress:** worst scenario is *%s* at %s (%.1fx VaR). A %s move in the S&P 500 (with beta-linked moves elsewhere) would lose %s.",
          worst3$scenario[1], fmt_usd(worst3$total_pnl[1]), worst3$multiple_of_var[1],
          fmt_pct(st$reverse$spy_move_needed, 1), fmt_usd(st$reverse$loss_budget))
)

# ---- Tables ------------------------------------------------------------------
t_port <- PORTFOLIO |> transmute(Ticker = ticker, `Asset class` = asset_class,
                                 Description = description, Position = fmt_usd(position_usd))
t_var  <- vs |> transmute(Method = method, `99% VaR (1d)` = fmt_usd(var_99_1d),
                          `97.5% ES (1d)` = fmt_usd(es_975_1d), `99% VaR (10d)` = fmt_usd(var_99_10d),
                          `ES / VaR` = round(es_to_var, 2))
t_comp <- rm_$comp |> transmute(Ticker = ticker, Position = fmt_usd(position_usd),
                                `Standalone VaR` = fmt_usd(standalone_var),
                                `Component VaR` = fmt_usd(component_var), `% of total` = fmt_pct(pct_of_total, 1))
t_bt <- res |> transmute(Model = model, Exceptions = exceptions_99, Expected = expected_99,
                         `Kupiec p` = round(kupiec_p, 3), `Christoffersen p` = round(christoffersen_p, 3),
                         `ES Z2` = round(es_z2, 2), `Last 250d` = last250_exc_99, Zone = last250_zone,
                         `FRTB desk pass` = ifelse(frtb_desk_pass, "Yes", "No"),
                         `% days in red` = fmt_pct(pct_days_red_zone, 1), Verdict = verdict)
t_st <- st$stress_tbl |> transmute(Scenario = scenario, Type = type, `P&L` = fmt_usd(total_pnl),
                                   `x VaR` = round(multiple_of_var, 1))
t_reg <- rm_$reg_summary |> transmute(Measure = measure, Amount = fmt_usd(usd))

report <- c(
  "# Market Risk Summary",
  "",
  sprintf("*As of %s. Generated by `market-risk/06_report.R`. Data: Yahoo Finance, FRED.*", format(rm_$as_of)),
  "",
  "## Portfolio", "", md_table(t_port), "",
  "## Key observations", "", obs, "",
  "## 1. VaR and ES by method", "", md_table(t_var), "",
  "![VaR by method](figures/03_var_by_method.png)", "",
  "![P&L distribution](figures/03_pnl_distribution.png)", "",
  "## 2. Where the risk comes from", "", md_table(t_comp), "",
  "![Component VaR](figures/03_component_var.png)", "",
  "![Correlations](figures/03_correlation_heatmap.png)", "",
  "## 3. Regulatory capital (illustrative)", "", md_table(t_reg), "",
  "![Stressed window](figures/03_rolling_var_stressed_window.png)", "",
  "## 4. Backtesting", "",
  sprintf("Out-of-sample, %d trading days (%s to %s). Each forecast uses only the prior 250 days.",
          res$days_tested[1], format(min(bt$bt$date)), format(max(bt$bt$date))), "",
  md_table(t_bt), "",
  "*p-values below 0.05 reject the model at 5% significance. Z2 below -0.70 flags ES as too low.*", "",
  "![Backtest](figures/04_backtest_pnl_vs_var.png)", "",
  "![Traffic light](figures/04_traffic_light.png)", "",
  "![COVID reaction](figures/04_covid_reaction_speed.png)", "",
  "## 5. Stress testing", "", md_table(t_st), "",
  "![Stress P&L](figures/05_stress_pnl.png)", "",
  "![Stress heat map](figures/05_stress_heatmap.png)", "",
  "## Regulatory notes", "",
  "- **Basel 2.5 (US Market Risk Rule, in force today):** 10-day 99% VaR plus stressed VaR, each times a multiplier of 3 (up to 4 after poor backtests). Backtesting uses the traffic light on 250 days of 99% VaR exceptions.",
  "- **FRTB (Fundamental Review of the Trading Book):** replaces VaR with 97.5% Expected Shortfall scaled to liquidity horizons (10 to 120 days), calibrated to a stressed period, and approved desk by desk. Desks must pass backtesting (at most 12 exceptions at 99% and 30 at 97.5% in 250 days) and a P&L attribution test comparing risk-model P&L to front-office P&L.",
  "- **Timing:** FRTB capital applies in the EU from 1 Jan 2027; the UK applies Basel 3.1 from 1 Jan 2027 with FRTB internal models from 1 Jan 2028; US agencies re-proposed their Basel III endgame rules (including FRTB) in March 2026. Check current status before quoting dates.",
  "- **Model risk (SR 11-7 in the US):** every model needs independent validation: conceptual soundness, ongoing monitoring (this backtest) and outcomes analysis.",
  "",
  "## Limitations", "",
  "- ETFs proxy risk factors; a real book maps positions to curves, spreads and vol surfaces.",
  "- Positions are linear, so there are no option Greeks (gamma, vega) in this book.",
  "- 10-day figures use square-root-of-time scaling, which assumes independent daily returns.",
  "- USO and UNG hold futures, so their returns include roll yield, not just spot moves."
)

writeLines(report, file.path(PATHS$outputs, "market_risk_summary.md"))
message("  saved market_risk_summary.md")
