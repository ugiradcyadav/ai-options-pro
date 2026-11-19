import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../data/scrip_master_engine.dart';
import '../../engine/backtest_engine.dart';
import '../../engine/strategy_settings.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/v2_control_dialogs.dart';

class BacktestScreen extends StatefulWidget {
  final AppState appState;
  final bool embeddedMode;

  const BacktestScreen({
    super.key,
    required this.appState,
    this.embeddedMode = false,
  });

  @override
  State<BacktestScreen> createState() => _BacktestScreenState();
}

class _BacktestScreenState extends State<BacktestScreen> {
  String _curveMode = 'Equity';
  bool _running = false;
  BacktestReport? _report;
  ThreeWayBacktestReport? _threeWay;
  List<FrictionStressRow> _stressRows = [];

  @override
  void initState() {
    super.initState();
    _executeBacktest();
  }

  Future<void> _executeBacktest() async {
    setState(() => _running = true);
    final idx = widget.appState.selectedIndex;
    final bars = await ForeverDatabase.instance
        .getRecentBars(indexName: idx.label, limit: 600);
    final lotSize = ScripMasterEngine.instance.getLotSizeForIndex(idx) ?? 0;
    final cap = DhanDataEngine.instance.availableTradingCapital ?? 0.0;

    final rep = BacktestEngine.runRealisticBacktest(
      index: idx,
      bars: bars,
      riskConfig: widget.appState.riskConfig,
      startingCapital: cap,
      lotSize: lotSize,
      outOfSampleOnly: true,
    );
    final threeWay = BacktestEngine.runThreeWayHoldout(
      index: idx,
      bars: bars,
      riskConfig: widget.appState.riskConfig,
      startingCapital: cap,
      lotSize: lotSize,
    );
    final stress = BacktestEngine.runFrictionStressTest(
      index: idx,
      bars: bars,
      riskConfig: widget.appState.riskConfig,
      startingCapital: cap,
      lotSize: lotSize,
      outOfSampleOnly: true,
    );

    if (!mounted) return;
    setState(() {
      _report = rep;
      _threeWay = threeWay;
      _stressRows = stress;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final settings = StrategySettingsEngine.instance.current;
    final rep = _report ?? widget.appState.lastBacktestReport;
    final startCap = DhanDataEngine.instance.availableTradingCapital ?? 0.0;

    final List<double> equityPoints = [startCap];
    final List<double> drawdownPoints = [0.0];
    double runningEq = startCap;
    double peakEq = startCap;

    if (rep != null) {
      for (final raw in rep.tradeLogs) {
        final m = raw as Map;
        final pnl = ((m['netPnl'] ?? 0) as num).toDouble();
        runningEq += pnl;
        if (runningEq > peakEq) peakEq = runningEq;
        equityPoints.add(runningEq);
        drawdownPoints.add(peakEq - runningEq);
      }
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Research Lab: 3-Way OOS & Stress Test',
                      style: QuantTheme.heading(size: 13)),
                  GestureDetector(
                    onTap: () => V2ControlDialogs.openStrategySettingsSheet(
                      context,
                      onSaved: _executeBacktest,
                    ),
                    child: const QuantBadge(
                      text: 'Tune Settings ⚙',
                      color: QuantTheme.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: UnderlyingIndex.values.map((u) {
                  final active = u == idx;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        widget.appState.setSelectedUnderlying(u);
                        _executeBacktest();
                      },
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active
                              ? QuantTheme.bgElevated
                              : QuantTheme.bgSecondary,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color:
                                active ? QuantTheme.accent : QuantTheme.border,
                          ),
                        ),
                        child: Text(
                          u.label,
                          style: QuantTheme.heading(
                            size: 10,
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
              const SizedBox(height: 8),
              Text(
                'Same evaluateEntry() • Gap-Aware Stops • 0.15% Sell STT • Target +${settings.targetPct}% / SL -${settings.stopLossPct}% / Hold ${settings.timeExitMinutes}m',
                style: QuantTheme.label(size: 10),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // 1. Primary OOS Results & Equity/Drawdown Curve
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Out-of-Sample Results (${rep?.totalTrades ?? 0} trades)',
                      style: QuantTheme.heading(size: 12)),
                  Row(
                    children: ['Equity', 'Drawdown'].map((cm) {
                      final active = _curveMode == cm;
                      return GestureDetector(
                        onTap: () => setState(() => _curveMode = cm),
                        child: Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: active
                                ? QuantTheme.accent
                                : QuantTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            cm,
                            style: QuantTheme.mono(
                              size: 10,
                              color: active
                                  ? QuantTheme.bgMain
                                  : QuantTheme.textSecondary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (rep == null || rep.totalTrades == 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Insufficient recorded real-data trades for OOS evaluation. Keep broker connected to record live bars.',
                    style: QuantTheme.mono(size: 11, color: QuantTheme.warning),
                  ),
                )
              else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    QuantMetricCell(
                        label: 'WIN RATE',
                        value: '${rep.winRatePct.toStringAsFixed(1)}%',
                        valueColor: QuantTheme.positive),
                    QuantMetricCell(
                        label: 'PROFIT FACTOR',
                        value: rep.profitFactor.toStringAsFixed(2)),
                    QuantMetricCell(
                        label: 'MAX DD',
                        value: '₹${rep.maxDrawdown.toStringAsFixed(0)}',
                        valueColor: QuantTheme.negative),
                    QuantMetricCell(
                        label: 'NET P&L',
                        value: '₹${rep.netPnl.toStringAsFixed(0)}',
                        valueColor: rep.netPnl >= 0
                            ? QuantTheme.positive
                            : QuantTheme.negative),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 125,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _EquityDrawdownCurvePainter(
                      points: _curveMode == 'Equity'
                          ? equityPoints
                          : drawdownPoints,
                      isDrawdown: _curveMode == 'Drawdown',
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: QuantTheme.accent,
                    foregroundColor: QuantTheme.bgMain,
                  ),
                  onPressed: _running ? null : _executeBacktest,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(
                    _running
                        ? 'Running 3-Way & Stress Test...'
                        : 'Run 3-Way Holdout & Stress Test',
                    style:
                        QuantTheme.heading(size: 12, color: QuantTheme.bgMain),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // 2. 3-Way Split (50% Train / 25% Frozen OOS / 25% Final Holdout)
        if (_threeWay != null)
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('3-Way Chronological Holdout',
                    style: QuantTheme.heading(size: 12)),
                const SizedBox(height: 4),
                Text(_threeWay!.summaryNote, style: QuantTheme.label(size: 10)),
                const Divider(color: QuantTheme.border, height: 14),
                if (!_threeWay!.hasSufficientBars)
                  Text('Keep collecting live 1m bars to unlock 3-way split.',
                      style: QuantTheme.mono(size: 10, color: QuantTheme.warning))
                else
                  Row(
                    children: [
                      _splitCol('TRAIN (50%)', _threeWay!.trainReport),
                      _splitCol('FROZEN OOS', _threeWay!.frozenOosReport),
                      _splitCol('HOLDOUT (25%)', _threeWay!.finalHoldoutReport),
                    ],
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),

        // 3. Fee & Slippage Sensitivity Stress-Test (1.0x / 1.5x / 2.0x)
        if (_stressRows.isNotEmpty)
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Friction & Slippage Sensitivity (1.0x → 2.0x)',
                    style: QuantTheme.heading(size: 12)),
                const Divider(color: QuantTheme.border, height: 14),
                ..._stressRows.map((s) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(s.label, style: QuantTheme.label(size: 10.5)),
                          Row(
                            children: [
                              Text(
                                'Net ₹${s.netPnlInr.toStringAsFixed(0)} (PF ${s.profitFactor.toStringAsFixed(2)})',
                                style: QuantTheme.mono(
                                  size: 10.5,
                                  color: s.netPnlInr >= 0
                                      ? QuantTheme.positive
                                      : QuantTheme.negative,
                                ),
                              ),
                              const SizedBox(width: 6),
                              QuantBadge(
                                text: s.totalTrades == 0
                                    ? 'N/A'
                                    : (s.survives ? 'PASS' : 'FAIL'),
                                color: s.totalTrades == 0
                                    ? QuantTheme.textSecondary
                                    : (s.survives
                                        ? QuantTheme.positive
                                        : QuantTheme.negative),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )),
              ],
            ),
          ),
      ],
    );

    if (widget.embeddedMode) return body;
    return SingleChildScrollView(padding: const EdgeInsets.all(12), child: body);
  }

  Widget _splitCol(String title, BacktestReport r) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: QuantTheme.bgSecondary,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: QuantTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: QuantTheme.heading(size: 9, color: QuantTheme.accent)),
            const SizedBox(height: 4),
            Text('Trades: ${r.totalTrades}', style: QuantTheme.mono(size: 9.5)),
            Text('WR: ${r.winRatePct.toStringAsFixed(0)}%',
                style: QuantTheme.mono(size: 9.5)),
            Text(
              '₹${r.netPnl.toStringAsFixed(0)}',
              style: QuantTheme.mono(
                size: 10,
                color: r.netPnl >= 0
                    ? QuantTheme.positive
                    : QuantTheme.negative,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EquityDrawdownCurvePainter extends CustomPainter {
  final List<double> points;
  final bool isDrawdown;

  _EquityDrawdownCurvePainter({required this.points, required this.isDrawdown});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    double minV = points.first, maxV = points.first;
    for (final v in points) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    if (maxV <= minV) maxV = minV + 1.0;

    final path = Path();
    final stepX = size.width / math.max(1, points.length - 1);
    final usableH = size.height - 12.0;
    for (int i = 0; i < points.length; i++) {
      final x = i * stepX;
      final y =
          usableH - ((points[i] - minV) / (maxV - minV)) * (usableH - 10.0);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = isDrawdown ? QuantTheme.negative : QuantTheme.accent
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _EquityDrawdownCurvePainter oldDelegate) => true;
}
