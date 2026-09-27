# Critical Minerals & Energy Markets — ML Analysis Dashboard

> An interactive, browser-based educational dashboard for learning machine learning methods applied to commodity and energy markets. No installation, no API keys, no backend — open the link and start exploring.

---

## Live Demo

**[→ View Dashboard](https://YOUR_USERNAME.github.io/commodity-ml-dashboard/)**

*(Replace with your actual GitHub Pages URL after deployment)*

---

## Overview

This dashboard was built as a self-contained learning tool that bridges quantitative finance theory and hands-on experimentation. It covers five interconnected modules, each with plain-English methodology explanations, interactive controls, and live visual outputs.

The target audience is anyone curious about how ML is applied to commodity markets — no prior quant finance background required.

---

## Modules

### 01 · Market Overview
- Simulated historical price series for 8 assets: Copper, WTI Crude, Natural Gas, Lithium, Nickel, Cobalt, Gold, and Power
- Pairwise correlation matrix across critical minerals
- Supply tightness composite signals
- Current market regime estimates with plain-English descriptions
- Key concepts glossary (Basis, Backwardation, PMI, Alpha, Sharpe, Regime)

### 02 · Lasso / Ridge / ElasticNet
- Interactive regularization strength (alpha) and L1 ratio controls
- Live coefficient bar chart — watch features get zeroed out in real time as you increase alpha
- R² score and active feature count
- Predicted vs. actual scatter plot
- Plain-English explanation of overfitting, penalization, and when to use each model

### 03 · XGBoost
- Tune N trees, max depth, learning rate, and subsample fraction
- Feature importance chart showing which signals the model relies on
- Training vs. validation learning curve — visually diagnose overfitting
- Predicted vs. actual scatter plot
- Explanation of gradient boosting, non-linearity, and ensemble methods

### 04 · Hidden Markov Model
- Select 2–4 hidden regimes
- Inferred regime properties: mean return, volatility, average persistence
- Transition probability matrix with intensity shading
- Historical regime classification chart overlaid with monthly returns
- Explanation of the Viterbi algorithm, emission probabilities, and regime-conditioned strategy logic

### 05 · Backtest Engine
- Choose signal model (Lasso, XGBoost, HMM, or Ensemble)
- Configure start year, stop-loss, and transaction cost
- Outputs: Total Return, Sharpe Ratio, Max Drawdown, Win Rate, CAGR, N Trades
- Equity curve vs. buy-and-hold benchmark
- Monthly returns heatmap
- Drawdown chart
- Plain-English interpretation of all metrics, including Sharpe benchmarks and drawdown risk context

---

## ML Methods Covered

| Method | Type | Key Concept Taught |
|---|---|---|
| Lasso (L1) | Regularized Regression | Feature selection via sparsity |
| Ridge (L2) | Regularized Regression | Coefficient shrinkage |
| ElasticNet | Regularized Regression | Blend of L1 and L2 penalties |
| XGBoost | Gradient Boosted Trees | Non-linear relationships, ensemble learning |
| Hidden Markov Model | Probabilistic Sequence Model | Latent regime detection, transition dynamics |

---

## Technical Details

- **Single file:** Everything lives in `index.html` — no npm, no webpack, no build step
- **Dependencies:** Chart.js 4.4.1 (via Cloudflare CDN), Google Fonts
- **Data:** All price series and returns are synthetically generated using geometric Brownian motion with regime-switching parameters. No real market data or external API calls are used.
- **Computation:** Runs entirely client-side in the browser
- **Browser support:** Chrome, Firefox, Safari, Edge

---

## Data Disclaimer

All price series, returns, signals, and model outputs are **synthetically simulated** from realistic commodity return distributions using deterministic random seeds. This dashboard is intended for **educational purposes only** and does not constitute financial advice or represent real market data.

---

## Author

Built by Naomi Esparza · CUNY Hunter College · MS Applied Mathematics & Economics  
Research focus: commodity markets, stochastic volatility, regime classification
