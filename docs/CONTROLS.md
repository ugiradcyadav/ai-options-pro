# AI Options Pro — Actionable Control Audit Matrix (Ticket B1)

| Screen | Control Label | Handler / Target | Expected Verified Effect |
|---|---|---|---|
| Home | Paper / Live Badge | `V2ControlDialogs.confirmSwitchToLive` | Always starts in Paper; switching to Live requires typing `LIVE` in confirmation dialog. |
| Home | NIFTY 50 / BANK NIFTY / FINNIFTY Cards | `appState.setSelectedUnderlying` | Switches active index across all tabs and refreshes chain + 1m bars. |
| Home | Quick Actions (6 Tiles) | `MainTerminalShell` tab switcher | Navigates immediately to OI Analysis, Option Chain, Backtest, Signals, Positions, or Settings. |
| OI Analysis | OI / Price / Volume / IV Tabs | `_selectedMetricTab` state update | Switches interactive chart and header metrics between OI, Price Candles, Volume, and IV Skew. |
| OI Analysis | 5m / 15m / 60m Lookback Chips | `_oiLookback` state update | Updates OI change window across bars and totals footer. |
| OI Analysis | Interactive Chart Canvas | `GestureDetector` pan/tap crosshair | Highlights touched strike/bar and displays exact OHLCV/OI/IV in top tooltip banner. |
| Option Chain | Expiry Dropdown | `engine.fetchOptionChainSnapshot` | Loads option chain for selected expiry date. |
| Option Chain | ATM-2 .. ATM+2 Filter Pills | `_selectedOffset` highlight | Highlights target moneyness strike row in chain table. |
| Option Chain | Chain / Premium / OI / Volume / IV Tabs | `_bottomSubTab` state update | Updates both interactive graph and table columns for chosen metric. |
| Signals | Execute Paper Trade / Approve Live Order | `appState.executeActiveSignal` | Validates via `RiskEngine.validateAndEnforceRisk` (M8 EV gate) and creates order/position or shows exact rejection reason. |
| Positions | Kill Switch Toggle | `ForeverDatabase.savePersistedRiskConfig` | Persists kill-switch state to SQLite and blocks new entries immediately. |
| Positions | Close Position Button | `appState.closePosition` | Closes open position, records realized net P&L after charges, and reconciles broker audit log. |
| Backtest | Run Walk-Forward Backtest | `BacktestEngine.runRealisticBacktest` | Runs out-of-sample walk-forward backtest with statutory costs, half-spread + impact slippage, next-bar open fill, and stop-first rule. |
| Settings | Strategy Settings Tile | `V2ControlDialogs.openStrategySettingsSheet` | Opens validated editor for OI threshold, volume, IV band, target %, SL %, time exit, lookback, and changelog. |
| Settings | Data & Storage Tile | `V2ControlDialogs.openDataAndStorageSheet` | Shows DB size, per-index bar counts, time range, Prune >5d, Export CSV, and confirmed Clear DB. |
| Settings | Recalibrate Now Button | `AiRecalibrationEngine.runLightweightFiveDayRecalibration` | Runs 60/40 walk-forward calibration and reports unclamped OOS accuracy (or "Insufficient data" if N < 100). |
| API Setup | Angel One / Dhan Switcher & Save | `AngelSmartApiEngine.loginAndSave` / `TotpAuthManager` | Authenticates via TOTP and starts live parallel index feed. |
