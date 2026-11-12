import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models.dart';
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
  String _rangeWindow = '6M'; // '1M' | '3M' | '6M' | '1Y' | 'ALL'
  String _selectedTf = '5m'; // '1m' | '5m' | '15m'
  String _strategyName = 'MTF OI + Black-76 EV Gate';
  String _curveMode = 'Equity'; // 'Equity' | 'Drawdown'
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
    );
    if (!mounted) return;
    setState(() {
      _report = rep as BacktestReport;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final settings = StrategySettingsEngine.instance.current;
    final rep = _report ?? widget.appState.lastBacktestReport;

    double avgWin = 0.0;
    double avgLoss = 0.0;
    int winCount = 0;
    int lossCount = 0;
    final List<double> equityPoints = [25000.0];
    final List<double> drawdownPoints = [0.0];
    double runningEq = 25000.0;
    double peakEq = 25000.0;

    if (rep != null) {
      for (final raw in rep.tradeLogs) {
        final m = raw as Map;
        final pnl = ((m['netPnl'] ?? 0) as num).toDouble();
        runningEq += pnl;
        if (runningEq > peakEq) peakEq = runningEq;
        equityPoints.add(runningEq);
        drawdownPoints.add(peakEq - runningEq);
        if (pnl >= 0) {
          winCount++;
          avgWin += pnl;
        } else {
          lossCount++;
          avgLoss += pnl.abs();
        }
      }
      if (winCount > 0) avgWin /= winCount;
      if (lossCount > 0) avgLoss /= lossCount;
    }

    final maxDdPct = peakEq > 0 && rep != null
        ? ((rep.maxDrawdown / peakEq) * 100.0)
        : 0.0;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Instrument & Strategy Configuration Panel
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Walk-Forward Backtest & Research',
                      style: QuantTheme.heading(size: 13)),
                  GestureDetector(
                    onTap: () => V2ControlDialogs.openStrategySettingsSheet(
                      context,
                      onSaved: _executeBacktest,
                    ),
                    child: QuantBadge(
                      text: 'Tune Parameters ⚙',
                      color: QuantTheme.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Index Selector
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
                            color: active
                                ? QuantTheme.accent
                                : QuantTheme.border,
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
              // Date Range Window (1M | 3M | 6M | 1Y | ALL) & Timeframe (1m | 5m | 15m)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: ['1M', '3M', '6M', '1Y', 'ALL'].map((rng) {
                      final active = _rangeWindow == rng;
                      return GestureDetector(
                        onTap: () {
                          setState(() => _rangeWindow = rng);
                          _executeBacktest();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: active
                                ? QuantTheme.accent
                                : QuantTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            rng,
                            style: QuantTheme.mono(
                              size: 10,
                              color: active
                                  ? QuantTheme.bgMain
                                  : QuantTheme.textPrimary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  Row(
                    children: ['1m', '5m', '15m'].map((tf) {
                      final active = _selectedTf == tf;
                      return GestureDetector(
                        onTap: () {
                          setState(() => _selectedTf = tf);
                          _executeBacktest();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(left: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 5),
                          decoration: BoxDecoration(
                            color: active
                                ? QuantTheme.bgElevated
                                : QuantTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: active
                                  ? QuantTheme.accent
                                  : QuantTheme.border,
                            ),
                          ),
                          child: Text(
                            tf,
                            style: QuantTheme.mono(
                              size: 10,
                              color: active
                                  ? QuantTheme.accent
                                  : QuantTheme.textSecondary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              const Divider(color: QuantTheme.border, height: 14),
              Text(
                'Config: $_strategyName • Target +${settings.targetPct}% | SL -${settings.stopLossPct}% | Hold ${settings.timeExitMinutes}m | Next-Bar Open Fill + Statutory Friction',
                style: QuantTheme.label(size: 10),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // 2. Strategy Performance KPI Card + Equity / Drawdown Curve
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Out-of-Sample Strategy Performance',
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  QuantMetricCell(
                    label: 'WIN RATE',
                    value: '${(rep?.winRatePct ?? 0.0).toStringAsFixed(1)}%',
                    valueColor: QuantTheme.positive,
                  ),
                  QuantMetricCell(
                    label: 'PROFIT FACTOR',
                    value: (rep?.profitFactor ?? 0.0).toStringAsFixed(2),
                    valueColor: QuantTheme.textPrimary,
                  ),
                  QuantMetricCell(
                    label: 'MAX DRAWDOWN',
                    value:
                        '₹${(rep?.maxDrawdown ?? 0.0).toStringAsFixed(0)} (${maxDdPct.toStringAsFixed(1)}%)',
                    valueColor: QuantTheme.negative,
                  ),
                  QuantMetricCell(
                    label: 'TRADES',
                    value: '${rep?.totalTrades ?? 0}',
                    valueColor: QuantTheme.accent,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 145,
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
          ),
        ),
        const SizedBox(height: 10),

        // 3. Detailed Expectancy, Charges & Slippage Breakdown
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Expectancy, Friction & Cost Audit',
                  style: QuantTheme.heading(size: 12)),
              const Divider(color: QuantTheme.border, height: 14),
              _kvRow('Gross P&L (Before Friction)',
                  '₹${(rep?.grossPnl ?? 0.0).toStringAsFixed(2)}'),
              _kvRow('Statutory Charges + Spread/Impact Slippage',
                  '-₹${(rep?.totalCharges ?? 0.0).toStringAsFixed(2)}',
                  color: QuantTheme.warning),
              _kvRow(
                'Net Out-of-Sample P&L',
                '₹${(rep?.netPnl ?? 0.0).toStringAsFixed(2)}',
                color: (rep?.netPnl ?? 0.0) >= 0
                    ? QuantTheme.positive
                    : QuantTheme.negative,
              ),
              _kvRow('Net Expectancy Per Trade',
                  '₹${(rep?.expectancyPerTrade ?? 0.0).toStringAsFixed(2)}'),
              _kvRow('Average Win / Average Loss',
                  '+₹${avgWin.toStringAsFixed(1)}  /  -₹${avgLoss.toStringAsFixed(1)}'),
              _kvRow('Rejected by Risk Engine',
                  '${rep?.rejectedByRiskCount ?? 0} candidate entries'),
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
                        ? 'Running Walk-Forward Harness...'
                        : 'Re-Run Walk-Forward Out-of-Sample Backtest',
                    style:
                        QuantTheme.heading(size: 12, color: QuantTheme.bgMain),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embeddedMode) return body;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: body,
    );
  }

  Widget _kvRow(String k, String v, {Color color = QuantTheme.textPrimary}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: QuantTheme.label(size: 11)),
          Text(v,
              style: QuantTheme.mono(
                  size: 11, color: color, weight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _EquityDrawdownCurvePainter extends CustomPainter {
  final List<double> points;
  final bool isDrawdown;

  _EquityDrawdownCurvePainter({
    required this.points,
    required this.isDrawdown,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = QuantTheme.border.withOpacity(0.45)
      ..strokeWidth = 0.8;
    for (int i = 1; i <= 3; i++) {
      final y = size.height * (i / 4.0);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    if (points.length < 2) return;

    double minV = points.first;
    double maxV = points.first;
    for (final v in points) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    if (maxV <= minV) maxV = minV + 1.0;

    final path = Path();
    final fillPath = Path();
    final n = points.length;
    final stepX = size.width / math.max(1, n - 1);
    final usableH = size.height - 12.0;

    for (int i = 0; i < n; i++) {
      final x = i * stepX;
      final y = usableH - ((points[i] - minV) / (maxV - minV)) * (usableH - 10.0);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final color = isDrawdown ? QuantTheme.negative : QuantTheme.accent;
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = color.withOpacity(0.16)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _EquityDrawdownCurvePainter oldDelegate) => true;
}
