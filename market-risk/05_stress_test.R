# =============================================================================
#  05_stress_test.R  |  Stress testing: what if history repeats, or worse?
# =============================================================================
#
#  What this does
#    1. Historical scenarios: replays real crisis periods on TODAY's portfolio
#    2. Hypothetical scenarios: instant shocks designed by the risk team
#    3. Reverse stress test: how big a market fall wipes out a loss budget?
#
#  Why stress testing?
#    VaR says "on a normal bad day, you lose about X". It says nothing about
#    the size of losses beyond that, or about events not in the look-back
#    window. Stress tests fill that gap. In the US, large banks run them for
#    the Fed's CCAR / DFAST "global market shock"; FRTB requires stress
#    calibration of ES; and every trading desk has stress limits.
# -----------------------------------------------------------------------------

source("market-risk/config.R")
dat <- readRDS(file.path(PATHS$processed, "clean_data.rds"))
rm_ <- readRDS(file.path(PATHS$processed, "risk_metrics.rds"))
w <- dat$positions


# ---- 1. Historical scenarios ------------------------------------------------
# Cumulative return of each asset between two dates, applied to today's
# positions. Dates are the approximate start and trough of each episode.
step("Historical scenarios")

hist_scen <- tibble::tribble(
  ~scenario,                          ~start,        ~end,
  "2008 Lehman / GFC",                "2008-09-12",  "2008-11-20",
  "2011 US downgrade",                "2011-07-22",  "2011-08-08",
  "2013 Taper tantrum",               "2013-05-02",  "2013-06-24",
  "2014-15 Oil price collapse",       "2014-06-20",  "2015-01-28",
  "2020 COVID crash",                 "2020-02-19",  "2020-03-23",
  "2020 Negative WTI (April)",        "2020-04-01",  "2020-04-28",
  "2022 Rates & energy shock",        "2022-01-03",  "2022-06-16",
  "2024 August carry unwind",         "2024-07-31",  "2024-08-05"
) |> mutate(across(c(start, end), as.Date))

px <- dat$prices
scenario_returns <- function(start, end) {
  p0 <- px[index(px) <= start]; p1 <- px[index(px) <= end]
  if (nrow(p0) == 0) return(setNames(rep(NA_real_, ncol(px)), colnames(px)))
  as.numeric(tail(p1, 1)) / as.numeric(tail(p0, 1)) - 1
}
hist_shocks <- do.call(rbind, lapply(seq_len(nrow(hist_scen)), function(i)
  scenario_returns(hist_scen$start[i], hist_scen$end[i])))
colnames(hist_shocks) <- colnames(px)
rownames(hist_shocks) <- hist_scen$scenario


# ---- 2. Hypothetical scenarios ----------------------------------------------
# Instant moves (% change) chosen by the risk team. TLT's move is linked to
# rates via duration: a 20+yr Treasury ETF has duration ~16-17, so
# +100bp in long yields ~ -16%.
step("Hypothetical scenarios")

hypo_shocks <- rbind(
  "Equity crash (-20%)"            = c(SPY = -0.20, TLT =  0.08, GLD =  0.05, USO = -0.15, UNG = -0.05, XLE = -0.25),
  "Rates +100bp (bear steepener)"  = c(SPY = -0.06, TLT = -0.16, GLD = -0.03, USO =  0.00, UNG =  0.00, XLE = -0.04),
  "Oil supply shock (+40%)"        = c(SPY = -0.05, TLT = -0.03, GLD =  0.05, USO =  0.40, UNG =  0.15, XLE =  0.20),
  "Energy glut (oil -40%)"         = c(SPY = -0.03, TLT =  0.03, GLD =  0.00, USO = -0.40, UNG = -0.25, XLE = -0.25),
  "Stagflation"                    = c(SPY = -0.15, TLT = -0.10, GLD =  0.10, USO =  0.25, UNG =  0.20, XLE =  0.05),
  "Nat gas spike (+60%)"           = c(SPY = -0.02, TLT =  0.00, GLD =  0.00, USO =  0.05, UNG =  0.60, XLE =  0.05)
)[, names(w)]


# ---- 3. P&L of every scenario -----------------------------------------------
all_shocks <- rbind(hist_shocks, hypo_shocks)
scen_pnl   <- sweep(all_shocks, 2, w, `*`)                # $ P&L by asset
var99      <- rm_$var_summary$var_99_1d[1]                # HS 1-day VaR

stress_tbl <- data.frame(
  scenario   = rownames(all_shocks),
  type       = c(rep("Historical", nrow(hist_shocks)), rep("Hypothetical", nrow(hypo_shocks))),
  total_pnl  = rowSums(scen_pnl),
  scen_pnl,
  row.names = NULL, check.names = FALSE
) |>
  mutate(multiple_of_var = -total_pnl / var99,
         pct_of_gross    = total_pnl / sum(abs(w))) |>
  arrange(total_pnl)
print(stress_tbl |> mutate(across(where(is.numeric), ~ round(.x, 2))))


# ---- 4. Reverse stress test -------------------------------------------------
# Question: "How far must the S&P 500 fall to cost us $1mm?"
# Map every asset to SPY with its beta (from the last 250 days), so one
# number (the SPY move) drives the whole book.
step("Reverse stress test")
R_win   <- tail(coredata(dat$returns), WINDOW)
betas   <- apply(R_win, 2, function(r) cov(r, R_win[, "SPY"]) / var(R_win[, "SPY"]))
book_beta_usd <- sum(w * betas)             # $ P&L per 1.00 (100%) move in SPY
loss_budget   <- 1e6
spy_move_needed <- -loss_budget / book_beta_usd
reverse <- data.frame(loss_budget = loss_budget, book_beta_usd_per_1pct = book_beta_usd / 100,
                      spy_move_needed = spy_move_needed)
cat("  Book P&L per 1% SPY move:", fmt_usd(book_beta_usd / 100),
    "| SPY move to lose", fmt_usd(loss_budget), ":", fmt_pct(spy_move_needed, 1), "\n")


# ---- 5. Save ----------------------------------------------------------------
step("Saving")
save_table(stress_tbl, file.path(PATHS$tables, "05_stress_scenarios.csv"))
save_table(data.frame(ticker = names(betas), beta_to_spy = betas), file.path(PATHS$tables, "05_betas.csv"))
save_table(reverse, file.path(PATHS$tables, "05_reverse_stress.csv"))
saveRDS(list(stress_tbl = stress_tbl, reverse = reverse, betas = betas, all_shocks = all_shocks),
        file.path(PATHS$processed, "stress.rds"))

# (a) Total P&L by scenario, with the VaR for scale
p_st <- ggplot(stress_tbl, aes(total_pnl / 1e3, reorder(scenario, -total_pnl))) +
  geom_col(aes(fill = type), width = 0.65) +
  geom_vline(xintercept = -var99 / 1e3, colour = COL_INK, linetype = "dashed") +
  annotate("text", x = -var99 / 1e3, y = nrow(stress_tbl) + 0.7, hjust = 1.05, size = 3, colour = COL_INK,
           label = "1-day 99% VaR") +
  geom_text(aes(label = fmt_usd(total_pnl), hjust = ifelse(total_pnl < 0, 1.1, -0.1)),
            size = 3, colour = COL_INK) +
  scale_fill_manual(values = c(Historical = PALETTE[["blue"]], Hypothetical = PALETTE[["orange"]])) +
  scale_x_continuous(expand = expansion(mult = 0.25)) +
  labs(title = "Stress test P&L on today's portfolio",
       subtitle = "Stress losses are often many multiples of VaR: VaR is not a worst case.",
       x = "P&L ($ thousands)", y = NULL) +
  theme_risk()
save_plot(p_st, file.path(PATHS$figures, "05_stress_pnl.png"), height = 6)

# (b) Which positions lose in which scenario
heat <- stress_tbl |>
  select(scenario, all_of(names(w))) |>
  pivot_longer(-scenario, names_to = "ticker", values_to = "pnl") |>
  mutate(scenario = factor(scenario, levels = rev(stress_tbl$scenario)))
lim <- max(abs(heat$pnl), na.rm = TRUE) / 1e3
p_heat <- ggplot(heat, aes(ticker, scenario, fill = pnl / 1e3)) +
  geom_tile(colour = "white", linewidth = 1) +
  geom_text(aes(label = round(pnl / 1e3)), size = 3) +
  scale_fill_gradient2(low = COL_LOSS, mid = COL_MID, high = COL_GAIN, midpoint = 0,
                       limits = c(-lim, lim), name = "$k") +
  labs(title = "Stress P&L by position ($ thousands)",
       subtitle = "Read across a row to see what hurts and what hedges in each scenario.",
       x = NULL, y = NULL) +
  theme_risk() + theme(legend.position = "right", legend.title = element_text(), panel.grid = element_blank())
save_plot(p_heat, file.path(PATHS$figures, "05_stress_heatmap.png"), height = 6)
