import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../data/scrip_master_engine.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/backtest_engine.dart';
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
  String _subTab = 'Live';
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
      limit: 80,
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
    final chain = engine.optionChainRows[idx] ?? const [];
    final spot = engine.spotPrices[idx] ?? 0.0;
    final sig = widget.appState.activeSignal;
    final health = engine.dataHealth;
    final availCap = engine.availableTradingCapital;

    final latencyMs = (engine.dataDelaySec * 1000).round();
    final lastUpd = engine.lastSyncTimestampMs > 0
        ? DateFormat('HH:mm:ss').format(
            DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs))
        : '--:--:--';

    StrikeRowSnapshot? atmRow;
    for (final r in chain) {
      if (r.offset == 0) {
        atmRow = r;
        break;
      }
    }

    final isCall = sig?.action == SignalAction.buyCe;
    final strategyPassed = sig?.strategyPassed == true;
    final riskPassed = strategyPassed && (sig?.riskWithinLimits == true);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                        color: active ? QuantTheme.bgMain : QuantTheme.textPrimary,
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Signal Engine (${health.label})',
                          style: QuantTheme.heading(size: 12)),
                      Text(
                        'Last Update: $lastUpd • Latency: ${latencyMs}ms',
                        style: QuantTheme.mono(
                            size: 10, color: QuantTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                QuantBadge(
                  text: health.label,
                  color: health == DataHealthStatus.live
                      ? QuantTheme.positive
                      : QuantTheme.negative,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

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
            // Current Signal Panel
            QuantPanel(
              borderColor:
                  riskPassed ? QuantTheme.positive : QuantTheme.border,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Current Signal', style: QuantTheme.heading(size: 13)),
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
                  _kvRow('Spot Price',
                      spot > 0 ? '${idx.label} (${spot.toStringAsFixed(2)})' : 'NO DATA'),
                  _kvRow('Contract',
                      (sig != null && sig.strike > 0) ? sig.tradingSymbol : 'NONE'),
                  _kvRow('Entry / Target / SL',
                      (sig != null && sig.entryPremium > 0)
                          ? '₹${sig.entryPremium.toStringAsFixed(2)} / ₹${sig.targetPremium.toStringAsFixed(2)} / ₹${sig.stopLossPremium.toStringAsFixed(2)}'
                          : 'NO DATA'),
                  _kvRow('Available Capital',
                      availCap != null ? '₹${availCap.toStringAsFixed(2)}' : 'NO DATA'),
                  _kvRow('Lot Size & Qty',
                      (sig != null && sig.lotSize > 0) ? '${sig.quantity} (${sig.lotSize}/lot)' : 'N/A'),
                  if (atmRow != null)
                    _kvRow(
                      'ATM Greeks (${isCall ? "CE" : "PE"})',
                      'IV ${(isCall ? atmRow.ceIv : atmRow.peIv)?.toStringAsFixed(2) ?? "N/A"}% | Δ ${(isCall ? atmRow.ceDelta : atmRow.peDelta).toStringAsFixed(2)} | Θ ${(isCall ? atmRow.ceTheta : atmRow.peTheta).toStringAsFixed(1)}/d',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Independent Strategy Validation vs Risk Validation Decision Trace
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Decision Trace (Independent Audit Gates)',
                      style: QuantTheme.heading(size: 12)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _gateBox('STRATEGY GATE',
                            strategyPassed ? 'PASSED' : 'REJECTED',
                            strategyPassed ? QuantTheme.positive : QuantTheme.negative),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _gateBox(
                          'RISK & CAPITAL GATE',
                          !strategyPassed
                              ? 'BLOCKED BY STRATEGY'
                              : (riskPassed ? 'PASSED' : 'REJECTED'),
                          riskPassed ? QuantTheme.positive : QuantTheme.warning,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  Text(
                    sig?.riskNote ?? 'NO DATA — Awaiting live feed.',
                    style: QuantTheme.mono(size: 11, color: QuantTheme.warning),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Model: ${ai.activeModel.version} | Gate A5: ${ai.activeModel.passedEvaluationGate ? "PASSED" : "Rules-Only"} | Lookback: ${settings.lookbackMinutes}m',
                    style: QuantTheme.label(size: 10),
                  ),
                  const SizedBox(height: 10),
                  if (sig != null)
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: QuantTheme.accent,
                          foregroundColor: QuantTheme.bgMain,
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
                        label: Text('Open Signal Details & Execution →',
                            style: QuantTheme.heading(
                                size: 12, color: QuantTheme.bgMain)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _buildRecentSignalsPanel(),
          ],
        ],
      ),
    );
  }

  Widget _buildInlineBacktestSubView(UnderlyingIndex idx) {
    final lot = ScripMasterEngine.instance.getLotSizeForIndex(idx) ?? 0;
    final cap = DhanDataEngine.instance.availableTradingCapital ?? 0.0;
    final report = BacktestEngine.runRealisticBacktest(
      index: idx,
      bars: _recentBars,
      riskConfig: widget.appState.riskConfig,
      startingCapital: cap,
      lotSize: lot,
      outOfSampleOnly: true,
    );
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Unified OOS Backtest (${idx.label})',
              style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          _kvRow('Total OOS Trades', '${report.totalTrades}'),
          _kvRow('Win Rate', '${report.winRatePct.toStringAsFixed(1)}%'),
          _kvRow('Net P&L (0.15% STT)', '₹${report.netPnl.toStringAsFixed(2)}'),
        ],
      ),
    );
  }

  Widget _buildRecentSignalsPanel() {
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent Signals Log', style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          if (_recentSignals.isEmpty)
            Text('No real signals logged yet.', style: QuantTheme.label(size: 11))
          else
            ..._recentSignals.take(10).map((raw) {
              final m = raw as Map;
              final ts = (m['timestamp_ms'] as num?)?.toInt() ?? 0;
              final tStr = ts > 0
                  ? DateFormat('dd MMM HH:mm')
                      .format(DateTime.fromMillisecondsSinceEpoch(ts))
                  : '--';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(tStr, style: QuantTheme.mono(size: 10)),
                    Text('${m['index_name']} ${m['strike']}',
                        style: QuantTheme.mono(size: 11)),
                    QuantBadge(
                        text: '${m['action']}', color: QuantTheme.accent),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _gateBox(String title, String status, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: QuantTheme.bgSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: QuantTheme.label(size: 9)),
          const SizedBox(height: 2),
          Text(status, style: QuantTheme.mono(size: 11, color: color)),
        ],
      ),
    );
  }

  Widget _kvRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: QuantTheme.label(size: 11)),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.right, style: QuantTheme.mono(size: 11)),
          ),
        ],
      ),
    );
  }
}
