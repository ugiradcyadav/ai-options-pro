import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
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
  String _selectedTf = '5m';
  String _curveMode = 'Equity';
  bool _running = false;
  BacktestReport? _report;

  @override
  void initState() {
    super.initState();
    _executeBacktest();
  }

  Future<void> _executeBacktest() async {
    setState(() => _running = true);
    final rep = await BacktestEngine.runBacktest(
      index: widget.appState.selectedIndex,
      timeframe: _selectedTf,
      riskConfig: widget.appState.riskConfig,
      availableCapital: DhanDataEngine.instance.availableTradingCapital,
      outOfSampleOnly: true,
    );
    if (!mounted) return;
    setState(() {
      _report = rep;
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
                  Text('Unified Walk-Forward OOS Backtester',
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
                  padding: const EdgeInsets.symmetric(vertical: 14),
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
                  height: 130,
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
                        ? 'Running OOS Walk-Forward...'
                        : 'Run Unified OOS Backtest',
                    style: QuantTheme.heading(size: 12, color: QuantTheme.bgMain),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embeddedMode) return body;
    return SingleChildScrollView(padding: const EdgeInsets.all(12), child: body);
  }
}

class _EquityDrawdownCurvePainter extends CustomPainter {
  final List<double> points;
  final bool isDrawdown;

  _EquityDrawdownCurvePainter(
      {required this.points, required this.isDrawdown});

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
