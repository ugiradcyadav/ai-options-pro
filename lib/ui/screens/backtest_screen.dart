import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../core/ui_haptics.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../data/scrip_master_engine.dart';
import '../../engine/backtest_engine.dart';
import '../../engine/monte_carlo_engine.dart';
import '../../engine/quantstats_engine.dart';
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
  bool _trainingMl = false;
  BacktestReport? _report;
  ThreeWayBacktestReport? _threeWay;
  List<FrictionStressRow> _stressRows = [];
  QuantStatsTearSheet _tearSheet = QuantStatsTearSheet.empty;
  MonteCarloReport _mcReport = MonteCarloReport.empty;

  @override
  void initState() {
    super.initState();
    _executeBacktest();
  }

  Future<void> _trainSadhuMl() async {
    UiHaptics.medium();
    setState(() => _trainingMl = true);
    await widget.appState.trainSadhuMlFromRealBars();
    if (!mounted) return;
    setState(() => _trainingMl = false);
  }

  Future<void> _executeBacktest() async {
    setState(() => _running = true);
    final idx = widget.appState.selectedIndex;
    final bars = await ForeverDatabase.instance
        .getRecentBars(indexName: idx.label, limit: 800);
    final lotSize = ScripMasterEngine.instance.getLotSizeForIndex(idx) ?? 0;
    final cap = DhanDataEngine.instance.availableTradingCapital ?? 0.0;
    final simCap = cap > 0 ? cap : 50000.0;

    final rep = BacktestEngine.runRealisticBacktest(
      index: idx,
      bars: bars,
      riskConfig: widget.appState.riskConfig,
      startingCapital: simCap,
      lotSize: lotSize,
      outOfSampleOnly: true,
    );
    final threeWay = BacktestEngine.runThreeWayHoldout(
      index: idx,
      bars: bars,
      riskConfig: widget.appState.riskConfig,
      startingCapital: simCap,
      lotSize: lotSize,
    );
    final stress = BacktestEngine.runFrictionStressTest(
      index: idx,
      bars: bars,
      riskConfig: widget.appState.riskConfig,
      startingCapital: simCap,
      lotSize: lotSize,
      outOfSampleOnly: true,
    );
    final qs = QuantStatsEngine.computeFromTradeLogs(
      tradeLogs: rep.tradeLogs,
      startingCapitalInr: simCap,
    );

    final tradePnls = rep.tradeLogs
        .map((e) => (((e as Map)['netPnl'] ?? 0) as num).toDouble())
        .toList();
    final mc = await MonteCarloEngine.runAsync(
      tradePnls: tradePnls,
      startingCapitalInr: simCap,
      simulations: 10000,
    );

    if (!mounted) return;
    setState(() {
      _report = rep;
      _threeWay = threeWay;
      _stressRows = stress;
      _tearSheet = qs;
      _mcReport = mc;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final settings = StrategySettingsEngine.instance.current;
    final mlRep = widget.appState.sadhuMlReport;
    final rep = _report ?? widget.appState.lastBacktestReport;
    final _rawCap = DhanDataEngine.instance.availableTradingCapital ?? 0.0;
    final startCap = _rawCap > 0 ? _rawCap : 50000.0;

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
        // 1. Sadhu AI Research Lab Header + Index Selector
        QuantPanel(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Sadhu AI Quant Lab',
                      style: QuantTheme.heading(size: 13.5)),
                  GestureDetector(
                    onTap: () {
                      UiHaptics.tap();
                      V2ControlDialogs.openStrategySettingsSheet(
                        context,
                        onSaved: _executeBacktest,
                      );
                    },
                    child: const QuantBadge(
                      text: 'Tune Settings ⚙',
                      color: QuantTheme.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: UnderlyingIndex.values.map((u) {
                  final active = u == idx;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        UiHaptics.tap();
                        widget.appState.setSelectedUnderlying(u);
                        _executeBacktest();
                      },
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(vertical: 7),
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
                          u.label.replaceAll(' 50', ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: QuantTheme.heading(
                            size: 9.5,
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
                'Per-Contract Timeline • Isolated State • Target +${settings.targetPct}% / SL -${settings.stopLossPct}% / Hold ${settings.timeExitMinutes}m',
                style: QuantTheme.label(size: 9.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 2. Sadhu AI On-Device ML Training Card (Boosted Stumps + Platt Calibration)
        QuantPanel(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Sadhu AI ML Engine (Boosted Stumps)',
                      style: QuantTheme.heading(size: 12)),
                  QuantBadge(
                    text: mlRep.trained ? 'TRAINED' : 'UNTRAINED',
                    color: mlRep.trained
                        ? QuantTheme.positive
                        : QuantTheme.warning,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(mlRep.note, style: QuantTheme.label(size: 10)),
              if (mlRep.trained) ...[
                const Divider(color: QuantTheme.border, height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    QuantMetricCell(
                      label: 'OOS ACC',
                      value: '${mlRep.oosAccuracyPct.toStringAsFixed(1)}%',
                      valueColor: mlRep.oosAccuracyPct >= 55
                          ? QuantTheme.positive
                          : QuantTheme.warning,
                    ),
                    QuantMetricCell(
                      label: 'BRIER SCORE',
                      value: mlRep.oosBrierScore.toStringAsFixed(3),
                      valueColor: mlRep.oosBrierScore < 0.24
                          ? QuantTheme.positive
                          : QuantTheme.warning,
                    ),
                    QuantMetricCell(
                      label: 'STUMPS',
                      value: '${mlRep.stumpCount}',
                      valueColor: QuantTheme.accent,
                    ),
                    QuantMetricCell(
                      label: 'TRN/CAL/OOS',
                      value:
                          '${mlRep.trainSamples}/${mlRep.calSamples}/${mlRep.oosSamples}',
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 38,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: QuantTheme.accent),
                    foregroundColor: QuantTheme.accent,
                  ),
                  onPressed: _trainingMl ? null : _trainSadhuMl,
                  icon: const Icon(Icons.memory, size: 16),
                  label: Text(
                    _trainingMl
                        ? 'Training Sadhu ML on Real Bars...'
                        : 'Train Sadhu ML (Purged Non-Overlapping)',
                    style: QuantTheme.heading(
                        size: 11, color: QuantTheme.accent),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 3. Out-of-Sample Results & Equity Curve
        QuantPanel(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Out-of-Sample (${rep?.totalTrades ?? 0} trades)',
                      style: QuantTheme.heading(size: 12)),
                  Row(
                    children: ['Equity', 'Drawdown'].map((cm) {
                      final active = _curveMode == cm;
                      return GestureDetector(
                        onTap: () {
                          UiHaptics.tap();
                          setState(() => _curveMode = cm);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
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
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'Insufficient recorded real-data trades for OOS evaluation. Keep Angel One connected to build history.',
                    style: QuantTheme.mono(size: 10.5, color: QuantTheme.warning),
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
                        label: 'PF',
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
                  height: 120,
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
                  onPressed: _running
                      ? null
                      : () {
                          UiHaptics.medium();
                          _executeBacktest();
                        },
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(
                    _running
                        ? 'Simulating 10,000 Futures...'
                        : 'Run OOS + 10,000 Monte Carlo + Stress',
                    style:
                        QuantTheme.heading(size: 11.5, color: QuantTheme.bgMain),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 4. Monte Carlo 10,000-Future Pipeline Card
        QuantPanel(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Monte Carlo (10,000 Futures)',
                          style: QuantTheme.heading(size: 12.5)),
                      Text('Bootstrap Resampling • Drawdown Distribution',
                          style: QuantTheme.label(size: 9.5)),
                    ],
                  ),
                  QuantBadge(
                    text: _mcReport.simulations == 0
                        ? 'NEED ≥5 TRADES'
                        : (_mcReport.passesGate ? 'GATE PASS' : 'HIGH RISK'),
                    color: _mcReport.simulations == 0
                        ? QuantTheme.textSecondary
                        : (_mcReport.passesGate
                            ? QuantTheme.positive
                            : QuantTheme.negative),
                  ),
                ],
              ),
              const Divider(color: QuantTheme.border, height: 14),
              if (_mcReport.simulations == 0)
                Text(
                  'One backtest is just 1 path. Record ≥5 OOS trades to simulate 10,000 futures.',
                  style: QuantTheme.label(size: 10.5),
                )
              else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    QuantMetricCell(
                      label: 'P50 DD',
                      value: '${_mcReport.p50MaxDdPct.toStringAsFixed(1)}%',
                    ),
                    QuantMetricCell(
                      label: 'P95 DD',
                      value: '${_mcReport.p95MaxDdPct.toStringAsFixed(1)}%',
                      valueColor: _mcReport.p95MaxDdPct < 15.0
                          ? QuantTheme.positive
                          : QuantTheme.negative,
                    ),
                    QuantMetricCell(
                      label: 'RUIN RISK',
                      value: '${_mcReport.riskOfRuinPct.toStringAsFixed(2)}%',
                      valueColor: _mcReport.riskOfRuinPct < 1.0
                          ? QuantTheme.positive
                          : QuantTheme.negative,
                    ),
                    QuantMetricCell(
                      label: 'PROFITABLE',
                      value:
                          '${_mcReport.profitablePathsPct.toStringAsFixed(0)}%',
                      valueColor: QuantTheme.accent,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 130,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _MonteCarloFanPainter(report: _mcReport),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'P5 End: ₹${_mcReport.p5EndingEquityInr.toStringAsFixed(0)} • P50 End: ₹${_mcReport.p50EndingEquityInr.toStringAsFixed(0)} • P95 End: ₹${_mcReport.p95EndingEquityInr.toStringAsFixed(0)}',
                  style: QuantTheme.mono(
                      size: 9.5, color: QuantTheme.textSecondary),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 5. QuantStats Tear-Sheet
        QuantPanel(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Fund-Grade Risk Tear-Sheet (QuantStats)',
                      style: QuantTheme.heading(size: 12)),
                  QuantBadge(
                    text: _tearSheet.totalTrades > 0
                        ? '${_tearSheet.totalTrades} TRADES'
                        : 'NO TRADES',
                    color: _tearSheet.totalTrades > 0
                        ? QuantTheme.accent
                        : QuantTheme.textSecondary,
                  ),
                ],
              ),
              const Divider(color: QuantTheme.border, height: 14),
              if (_tearSheet.totalTrades == 0)
                Text('Run on recorded trades to compute Sharpe, Sortino, Calmar & VaR.',
                    style: QuantTheme.label(size: 10.5))
              else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    QuantMetricCell(
                      label: 'SHARPE',
                      value: _tearSheet.sharpeRatio.toStringAsFixed(2),
                      valueColor: _tearSheet.sharpeRatio >= 1.0
                          ? QuantTheme.positive
                          : QuantTheme.warning,
                    ),
                    QuantMetricCell(
                      label: 'SORTINO',
                      value: _tearSheet.sortinoRatio.toStringAsFixed(2),
                      valueColor: QuantTheme.accent,
                    ),
                    QuantMetricCell(
                      label: 'CALMAR',
                      value: _tearSheet.calmarRatio.toStringAsFixed(2),
                    ),
                    QuantMetricCell(
                      label: 'VaR 95%',
                      value: '₹${_tearSheet.var95Inr.toStringAsFixed(0)}',
                      valueColor: QuantTheme.negative,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 6. 3-Way Holdout + Stress Test
        if (_threeWay != null)
          QuantPanel(
            padding: const EdgeInsets.all(14),
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
        const SizedBox(height: 12),
        if (_stressRows.isNotEmpty)
          QuantPanel(
            padding: const EdgeInsets.all(14),
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
    return SingleChildScrollView(padding: const EdgeInsets.all(16), child: body);
  }

  Widget _splitCol(String title, BacktestReport r) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: QuantTheme.bgSecondary,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: QuantTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: QuantTheme.heading(size: 9, color: QuantTheme.accent)),
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
  bool shouldRepaint(covariant _EquityDrawdownCurvePainter oldDelegate) =>
      true;
}

class _MonteCarloFanPainter extends CustomPainter {
  final MonteCarloReport report;

  _MonteCarloFanPainter({required this.report});

  @override
  void paint(Canvas canvas, Size size) {
    if (report.sampleEquityPaths.isEmpty || report.medianEquityPath.length < 2) {
      return;
    }

    final fanW = size.width * 0.72;
    final histLeft = fanW + 8.0;
    final histW = size.width - histLeft - 2.0;

    double minEq = report.startingCapitalInr;
    double maxEq = report.startingCapitalInr;
    for (final p in report.sampleEquityPaths) {
      for (final v in p) {
        if (v < minEq) minEq = v;
        if (v > maxEq) maxEq = v;
      }
    }
    if (maxEq <= minEq) maxEq = minEq + 100.0;

    double yFor(double v) =>
        size.height - 8.0 - (((v - minEq) / (maxEq - minEq)) * (size.height - 16.0));

    // Starting capital dashed baseline
    final yBase = yFor(report.startingCapitalInr);
    canvas.drawLine(
      Offset(0, yBase),
      Offset(fanW, yBase),
      Paint()
        ..color = QuantTheme.border
        ..strokeWidth = 0.8,
    );

    // 24 sample simulated futures
    final simPaint = Paint()
      ..color = QuantTheme.accent.withOpacity(0.22)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    for (final pathPts in report.sampleEquityPaths) {
      final path = Path();
      final stepX = fanW / math.max(1, pathPts.length - 1);
      for (int i = 0; i < pathPts.length; i++) {
        final pt = Offset(i * stepX, yFor(pathPts[i]));
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(path, simPaint);
    }

    // Median equity path highlight
    final medPath = Path();
    final medStep = fanW / math.max(1, report.medianEquityPath.length - 1);
    for (int i = 0; i < report.medianEquityPath.length; i++) {
      final pt = Offset(i * medStep, yFor(report.medianEquityPath[i]));
      if (i == 0) {
        medPath.moveTo(pt.dx, pt.dy);
      } else {
        medPath.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(
      medPath,
      Paint()
        ..color = report.passesGate ? QuantTheme.positive : QuantTheme.warning
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );

    // Right side: Drawdown distribution histogram bars
    final buckets = report.ddHistogramBuckets;
    if (buckets.isNotEmpty) {
      final maxCnt = math.max(1, buckets.reduce(math.max));
      final barH = (size.height - 12.0) / buckets.length;
      for (int i = 0; i < buckets.length; i++) {
        final w = (buckets[i] / maxCnt) * histW;
        final col = i >= 7 ? QuantTheme.negative : QuantTheme.accent;
        canvas.drawRect(
          Rect.fromLTWH(histLeft, 6.0 + i * barH, w, math.max(2.0, barH - 2.0)),
          Paint()..color = col.withOpacity(0.75),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MonteCarloFanPainter oldDelegate) => true;
}
