import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/backtest_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/risk_engine.dart';
import '../../engine/strategy_settings.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import 'signal_details_screen.dart';

class SignalsScreen extends StatefulWidget {
  final AppState appState;

  const SignalsScreen({super.key, required this.appState});

  @override
  State<SignalsScreen> createState() => _SignalsScreenState();
}

class _SignalsScreenState extends State<SignalsScreen> {
  String _subTab = 'Live'; // 'Live' | 'Backtest' | 'History'
  List _recentSignals = [];
  List _recentBars = [];

  @override
  void initState() {
    super.initState();
    _loadSignalHistory();
  }

  @override
  void didUpdateWidget(covariant SignalsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadSignalHistory();
  }

  Future<void> _loadSignalHistory() async {
    final sigs = await ForeverDatabase.instance.getRecentSignals(limit: 25);
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: widget.appState.selectedIndex.label,
      limit: 40,
    );
    if (!mounted) return;
    setState(() {
      _recentSignals = sigs;
      _recentBars = bars;
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final ai = AiRecalibrationEngine.instance;
    final settings = StrategySettingsEngine.instance.current;
    final chain = engine.optionChainRows[idx] ?? [];
    final spot = engine.spotPrices[idx] ?? 0.0;
    final sig = widget.appState.activeSignal;

    final latencyMs = (engine.dataDelaySec * 1000).round();
    final lastUpd = engine.lastSyncTimestampMs > 0
        ? DateFormat('HH:mm:ss').format(
            DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs))
        : '--:--:--';
    final ageSec = engine.lastSyncTimestampMs > 0
        ? ((DateTime.now().millisecondsSinceEpoch - engine.lastSyncTimestampMs) /
                1000.0)
            .clamp(0.0, 999.0)
        : 99.0;
    final isStale = ageSec > 15.0;

    StrikeRowSnapshot? atmRow;
    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeChg = 0;
    int totalPeChg = 0;
    for (final r in chain) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      totalCeChg += r.ceOiChange15m;
      totalPeChg += r.peOiChange15m;
      if (r.offset == 0) atmRow = r;
    }
    if (atmRow == null && chain.isNotEmpty) {
      atmRow = chain[chain.length ~/ 2];
    }

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 1.0;
    final netOiFlow = totalPeChg - totalCeChg;
    final isCall = sig?.action == SignalAction.buyCe;
    final optIv = atmRow != null
        ? (isCall ? atmRow.ceIv : atmRow.peIv)
        : 15.0;

    // Independent Strategy Validation vs Risk Validation Checks
    final bool ivCheckPass =
        optIv >= settings.minIvPct && optIv <= settings.maxIvPct;
    final bool oiCheckPass =
        netOiFlow.abs() >= (settings.oiThresholdForIndex(idx) * 0.25);
    final bool liqCheckPass =
        atmRow != null && (atmRow.ceVolume + atmRow.peVolume) > settings.minVolumeFilter;
    final bool regimeCheckPass = ai.probChopRegime <= 0.62;
    final bool freshnessPass = !isStale && chain.isNotEmpty;

    final bool strategyValidated = sig != null &&
        sig.action != SignalAction.noTrade &&
        sig.strike > 0 &&
        ivCheckPass &&
        regimeCheckPass;

    final double availCap = engine.availableTradingCapital > 0
        ? engine.availableTradingCapital
        : (sig?.availableCapital ?? 25000.0);
    final int qty = sig?.lotSize ?? idx.defaultLotSize;
    final double entryPrem = sig?.entryPremium ?? 0.0;
    final double slPrem = sig?.stopLossPremium ?? 0.0;
    final double tgtPrem = sig?.targetPremium ?? 0.0;
    final double expMovePts =
        entryPrem > 0 ? (tgtPrem - entryPrem) : 0.0;
    final double riskPts =
        entryPrem > 0 ? (entryPrem - slPrem).abs() : 0.0;
    final double rrRatio = riskPts > 0 ? (expMovePts / riskPts) : 0.0;

    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: entryPrem,
      exitPremium: tgtPrem,
      quantity: qty,
    );
    final double maxPotentialLoss =
        (riskPts * qty) + costs.totalFrictionInr;
    final double expectedNetReward =
        (expMovePts * qty) - costs.totalFrictionInr;
    final double netEv = RiskEngine.computeNetExpectedValueInr(
      winProbability: ((sig?.confidencePct ?? 50.0) / 100.0).clamp(0.01, 0.99),
      entryPremium: entryPrem,
      stopLossPremium: slPrem,
      targetPremium: tgtPrem,
      quantity: qty,
    );

    final bool evCheckPass = netEv >= settings.minNetEvInr;
    final bool capitalCheckPass =
        availCap >= (sig?.requiredCapital ?? 0.0) &&
            !widget.appState.riskConfig.killSwitchActive &&
            widget.appState.todayRealizedLossInr <
                widget.appState.riskConfig.maxDailyLossInr;

    // Crucial Mandate: Strategy rejection MUST NEVER appear as a successful overall trade/risk validation
    final bool riskValidated =
        strategyValidated && capitalCheckPass && evCheckPass && (sig?.riskWithinLimits ?? false);

    // Model Agreement & Uncertainty calculation
    final double logisticDir = netOiFlow >= 0 ? 1.0 : -1.0;
    final double hmmDir =
        ai.probBullRegime >= ai.probBearRegime ? 1.0 : -1.0;
    final double pcrDir = pcr >= 0.98 ? 1.0 : -1.0;
    final int agreeCount =
        (logisticDir == hmmDir ? 1 : 0) + (logisticDir == pcrDir ? 1 : 0) + 1;
    final double modelAgreementPct = (agreeCount / 3.0) * 100.0;
    final double uncertaintyPct = (ai.probChopRegime * 100.0).clamp(5.0, 95.0);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A. Signal Engine Header & Live / Backtest / History Sub-Tabs
          Row(
            children: ['Live', 'Backtest', 'History'].map((tab) {
              final active = _subTab == tab;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _subTab = tab),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? QuantTheme.accent : QuantTheme.border,
                      ),
                    ),
                    child: Text(
                      tab,
                      style: QuantTheme.heading(
                        size: 12,
                        color: active
                            ? QuantTheme.bgMain
                            : QuantTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),

          QuantPanel(
            padding: const EdgeInsets.all(10),
            backgroundColor: QuantTheme.bgSecondary,
            child: Row(
              children: [
                Icon(
                  engine.isConnected
                      ? Icons.check_circle
                      : Icons.error_outline,
                  color: engine.isConnected
                      ? QuantTheme.positive
                      : QuantTheme.warning,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        engine.isConnected
                            ? 'Signal Engine Active (${engine.connectionStatusText})'
                            : 'Signal Engine Standby (Reconnecting Feed)',
                        style: QuantTheme.heading(size: 12),
                      ),
                      Text(
                        'Last Update: $lastUpd • Latency: ${latencyMs}ms • Freshness: ${ageSec.toStringAsFixed(1)}s',
                        style: QuantTheme.mono(
                          size: 10,
                          color: QuantTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // B. Instrument Selector (NIFTY 50 | BANK NIFTY | FINNIFTY)
          Row(
            children: UnderlyingIndex.values.map((u) {
              final active = u == idx;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    widget.appState.setSelectedUnderlying(u);
                    _loadSignalHistory();
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color:
                          active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? QuantTheme.accent : QuantTheme.border,
                      ),
                    ),
                    child: Text(
                      u.label,
                      style: QuantTheme.heading(
                        size: 11,
                        color: active
                            ? QuantTheme.accent
                            : QuantTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),

          if (_subTab == 'Backtest')
            _buildInlineBacktestSubView(idx)
          else if (_subTab == 'History')
            _buildRecentSignalsPanel()
          else ...[
            // C. Market Bias Panel
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Market Bias & Regime Probabilities',
                          style: QuantTheme.heading(size: 12)),
                      QuantBadge(
                        text:
                            'Agreement: ${modelAgreementPct.toStringAsFixed(0)}%',
                        color: modelAgreementPct >= 66
                            ? QuantTheme.positive
                            : QuantTheme.warning,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ai.probBullRegime >= ai.probBearRegime
                                  ? 'Bullish'
                                  : 'Bearish',
                              style: QuantTheme.heading(
                                size: 20,
                                color: ai.probBullRegime >= ai.probBearRegime
                                    ? QuantTheme.positive
                                    : QuantTheme.negative,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Spot: ${spot.toStringAsFixed(2)}',
                              style: QuantTheme.mono(
                                  size: 11, color: QuantTheme.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 6,
                        child: Column(
                          children: [
                            _biasRow('Bullish', ai.probBullRegime * 100,
                                QuantTheme.positive),
                            const SizedBox(height: 4),
                            _biasRow('Bearish', ai.probBearRegime * 100,
                                QuantTheme.negative),
                            const SizedBox(height: 4),
                            _biasRow('Sideways/Chop', ai.probChopRegime * 100,
                                QuantTheme.warning),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // D. Current Signal Panel
            QuantPanel(
              borderColor: strategyValidated
                  ? QuantTheme.positive
                  : QuantTheme.border,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Current Signal',
                          style: QuantTheme.heading(size: 13)),
                      QuantBadge(
                        text: sig?.action.label ?? 'NO TRADE',
                        color: sig?.action == SignalAction.buyCe
                            ? QuantTheme.positive
                            : (sig?.action == SignalAction.buyPe
                                ? QuantTheme.negative
                                : QuantTheme.warning),
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  _kvRow('Index & Spot', '${idx.label} (${spot.toStringAsFixed(2)})'),
                  _kvRow(
                    'Contract & Strike',
                    (sig != null && sig.strike > 0)
                        ? '${sig.strike} ${sig.action == SignalAction.buyCe ? "CE" : "PE"}'
                        : 'No Active Contract (Filtered)',
                  ),
                  _kvRow('Expiry', sig?.expiry ?? '-'),
                  _kvRow('Entry Premium', '₹${entryPrem.toStringAsFixed(2)}',
                      color: QuantTheme.accent),
                  _kvRow(
                    'Target / Stop Loss',
                    'Target ₹${tgtPrem.toStringAsFixed(2)}  |  SL ₹${slPrem.toStringAsFixed(2)}',
                    color: QuantTheme.positive,
                  ),
                  _kvRow(
                    'Expected Move / R:R',
                    '+${expMovePts.toStringAsFixed(2)} pts  |  R:R ${rrRatio.toStringAsFixed(2)}x',
                  ),
                  _kvRow(
                    'Ensemble Confidence',
                    '${(sig?.confidencePct ?? 0.0).toStringAsFixed(1)}%',
                    color: QuantTheme.positive,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // E. AI Diagnostics Panel (Truthful Implemented Models Only)
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('AI & Quantitative Diagnostics',
                          style: QuantTheme.heading(size: 12)),
                      Text(
                        ai.activeModel.version,
                        style: QuantTheme.mono(
                            size: 10, color: QuantTheme.accent),
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  _kvRow(
                    '1. Rule-Weighted Logistic Score',
                    '${(sig?.confidencePct ?? 50.0).toStringAsFixed(1)}% (wOI:${ai.wHtfOiFlow.toStringAsFixed(2)}, wMom:${ai.wMicroMomentum.toStringAsFixed(2)})',
                  ),
                  _kvRow(
                    '2. 3-State Gaussian Forward-HMM',
                    'Bull ${(ai.probBullRegime * 100).toStringAsFixed(0)}% / Bear ${(ai.probBearRegime * 100).toStringAsFixed(0)}% / Chop ${(ai.probChopRegime * 100).toStringAsFixed(0)}%',
                  ),
                  _kvRow(
                    '3. Model Agreement & Uncertainty',
                    'Agree ${modelAgreementPct.toStringAsFixed(0)}%  |  Chop Uncertainty ${uncertaintyPct.toStringAsFixed(0)}%',
                  ),
                  _kvRow(
                    '4. HTF OI Confirmation (${settings.lookbackMinutes}m)',
                    'Net Flow ${QuantTheme.fmtSignedLakhs(netOiFlow)} (PCR ${pcr.toStringAsFixed(2)})',
                    color: oiCheckPass
                        ? QuantTheme.positive
                        : QuantTheme.warning,
                  ),
                  _kvRow(
                    '5. Black-76 IV Condition',
                    '${optIv.toStringAsFixed(2)}% (Band ${settings.minIvPct}–${settings.maxIvPct}%)',
                    color: ivCheckPass
                        ? QuantTheme.positive
                        : QuantTheme.negative,
                  ),
                  if (atmRow != null)
                    _kvRow(
                      '6. ATM Analytical Greeks',
                      'Δ ${atmRow.ceDelta.toStringAsFixed(2)} | Γ ${atmRow.ceGamma.toStringAsFixed(4)} | Θ ${atmRow.ceTheta.toStringAsFixed(1)}/d | ν ${atmRow.ceVega.toStringAsFixed(1)}',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // F. Risk Engine Panel
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Risk Engine & Position Sizing',
                          style: QuantTheme.heading(size: 12)),
                      QuantBadge(
                        text: riskValidated
                            ? 'TRADE & RISK APPROVED'
                            : (strategyValidated
                                ? 'RISK REJECTED'
                                : 'STANDBY (NO SIGNAL)'),
                        color: riskValidated
                            ? QuantTheme.positive
                            : (strategyValidated
                                ? QuantTheme.negative
                                : QuantTheme.warning),
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  _kvRow('Available Capital', '₹${availCap.toStringAsFixed(2)}'),
                  _kvRow('Required Premium Outlay',
                      '₹${(sig?.requiredCapital ?? 0.0).toStringAsFixed(2)}'),
                  _kvRow('Quantity & Lot Size',
                      '$qty qty (${idx.defaultLotSize} per lot)'),
                  _kvRow('Max Potential Loss (incl. friction)',
                      '₹${maxPotentialLoss.toStringAsFixed(2)}',
                      color: QuantTheme.negative),
                  _kvRow('Expected Net Reward (after costs)',
                      '₹${expectedNetReward.toStringAsFixed(2)}',
                      color: QuantTheme.positive),
                  _kvRow(
                    'Modeled Net EV (Gate >= ₹${settings.minNetEvInr.toStringAsFixed(0)})',
                    '${netEv >= 0 ? "+" : ""}₹${netEv.toStringAsFixed(2)}',
                    color: evCheckPass
                        ? QuantTheme.positive
                        : QuantTheme.negative,
                  ),
                  _kvRow(
                    'Portfolio Exposure',
                    '${widget.appState.openPositions.where((p) => p.isOpen).length} / ${widget.appState.riskConfig.maxConcurrentPositions} Open Positions',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // G. Decision Trace (Independent Strategy Validation vs Risk Validation Badges)
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Decision Trace (Audit Gate Breakdown)',
                      style: QuantTheme.heading(size: 12)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: QuantTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: strategyValidated
                                  ? QuantTheme.positive
                                  : QuantTheme.negative,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('STRATEGY VALIDATION',
                                  style: QuantTheme.label(size: 9)),
                              const SizedBox(height: 2),
                              Text(
                                strategyValidated ? 'PASSED' : 'REJECTED',
                                style: QuantTheme.mono(
                                  size: 12,
                                  color: strategyValidated
                                      ? QuantTheme.positive
                                      : QuantTheme.negative,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: QuantTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: riskValidated
                                  ? QuantTheme.positive
                                  : QuantTheme.warning,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('RISK & EV VALIDATION',
                                  style: QuantTheme.label(size: 9)),
                              const SizedBox(height: 2),
                              Text(
                                !strategyValidated
                                    ? 'BLOCKED BY STRATEGY'
                                    : (riskValidated ? 'PASSED' : 'REJECTED'),
                                style: QuantTheme.mono(
                                  size: 12,
                                  color: riskValidated
                                      ? QuantTheme.positive
                                      : QuantTheme.warning,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  _gateItem('Market Feed Freshness', freshnessPass,
                      'Age ${ageSec.toStringAsFixed(1)}s (Max 15s)'),
                  _gateItem('IV Permitted Band', ivCheckPass,
                      'IV ${optIv.toStringAsFixed(2)}% vs [${settings.minIvPct}–${settings.maxIvPct}%]'),
                  _gateItem('HTF OI Confirmation', oiCheckPass,
                      '${settings.lookbackMinutes}m ΔOI ${QuantTheme.fmtSignedLakhs(netOiFlow)}'),
                  _gateItem('Strike Liquidity Filter', liqCheckPass,
                      'Min Vol >= ${settings.minVolumeFilter}'),
                  _gateItem('HMM Regime Filter', regimeCheckPass,
                      'Chop ${(ai.probChopRegime * 100).toStringAsFixed(0)}% <= 62%'),
                  _gateItem('Net EV After Costs Gate', evCheckPass,
                      'Net EV ₹${netEv.toStringAsFixed(1)} >= ₹${settings.minNetEvInr.toStringAsFixed(1)}'),
                  _gateItem('Capital & Kill-Switch Gate', capitalCheckPass,
                      widget.appState.riskConfig.killSwitchActive
                          ? 'Kill Switch ACTIVE'
                          : 'Avail ₹${availCap.toStringAsFixed(0)}'),
                  const SizedBox(height: 10),
                  if (sig != null)
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: QuantTheme.accent,
                          foregroundColor: QuantTheme.bgMain,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => SignalDetailsScreen(
                                appState: widget.appState,
                                signal: sig,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.analytics_outlined, size: 17),
                        label: Text(
                          'View Full Signal Analysis & Execution →',
                          style: QuantTheme.heading(
                              size: 12, color: QuantTheme.bgMain),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // H. Recent Signals Log
            _buildRecentSignalsPanel(),
          ],
        ],
      ),
    );
  }

  Widget _buildInlineBacktestSubView(UnderlyingIndex idx) {
    final report = BacktestEngine.runRealisticBacktest(
      index: idx,
      bars: _recentBars,
      riskConfig: widget.appState.riskConfig,
      outOfSampleOnly: false,
    );
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Inline Signal Backtest (${idx.label})',
              style: QuantTheme.heading(size: 13)),
          const Divider(color: QuantTheme.border, height: 14),
          _kvRow('Total Evaluated Trades', '${report.totalTrades}'),
          _kvRow('Out-of-Sample Win Rate',
              '${report.winRatePct.toStringAsFixed(1)}%'),
          _kvRow('Profit Factor', report.profitFactor.toStringAsFixed(2)),
          _kvRow('Net P&L (after statutory charges)',
              '₹${report.netPnl.toStringAsFixed(2)}',
              color: report.netPnl >= 0
                  ? QuantTheme.positive
                  : QuantTheme.negative),
          _kvRow('Expectancy / Trade',
              '₹${report.expectancyPerTrade.toStringAsFixed(2)}'),
        ],
      ),
    );
  }

  Widget _buildRecentSignalsPanel() {
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent Signals Audit Log', style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          if (_recentSignals.isEmpty)
            Text('No historical signals logged yet in current session.',
                style: QuantTheme.label(size: 11))
          else
            ..._recentSignals.take(10).map((raw) {
              final m = raw as Map;
              final ts = (m['timestamp_ms'] as num?)?.toInt() ?? 0;
              final tStr = ts > 0
                  ? DateFormat('dd MMM HH:mm:ss')
                      .format(DateTime.fromMillisecondsSinceEpoch(ts))
                  : '--';
              final act = (m['action'] ?? 'NO TRADE').toString();
              final idxName = (m['index_name'] ?? 'NIFTY 50').toString();
              final strike = (m['strike'] ?? 0).toString();
              final conf =
                  ((m['confidence_pct'] ?? 0) as num).toDouble().toStringAsFixed(1);
              final isBuy = act.contains('BUY');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(tStr, style: QuantTheme.mono(size: 10, color: QuantTheme.textSecondary)),
                    Text('$idxName $strike', style: QuantTheme.mono(size: 11)),
                    QuantBadge(
                      text: '$act ($conf%)',
                      color: isBuy ? QuantTheme.positive : QuantTheme.warning,
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _biasRow(String label, double pct, Color color) {
    return Row(
      children: [
        Icon(Icons.circle, size: 8, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(label, style: QuantTheme.label(size: 10))),
        Text('${pct.toStringAsFixed(1)}%',
            style: QuantTheme.mono(size: 11, color: color)),
      ],
    );
  }

  Widget _kvRow(String k, String v, {Color color = QuantTheme.textPrimary}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: QuantTheme.label(size: 11)),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: QuantTheme.mono(size: 11, color: color, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gateItem(String title, bool passed, String detail) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            passed ? Icons.check_circle : Icons.cancel,
            size: 14,
            color: passed ? QuantTheme.positive : QuantTheme.negative,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(title,
                style: QuantTheme.label(size: 11, color: QuantTheme.textPrimary)),
          ),
          Text(
            detail,
            style: QuantTheme.mono(
              size: 10,
              color: passed ? QuantTheme.positive : QuantTheme.negative,
            ),
          ),
        ],
      ),
    );
  }
}
