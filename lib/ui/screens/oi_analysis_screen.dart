import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';

class OiAnalysisScreen extends StatefulWidget {
  final AppState appState;
  final bool embeddedMode;

  const OiAnalysisScreen({
    super.key,
    required this.appState,
    this.embeddedMode = false,
  });

  @override
  State<OiAnalysisScreen> createState() => _OiAnalysisScreenState();
}

class _OiAnalysisScreenState extends State<OiAnalysisScreen> {
  String _horizon = '15m'; // '5m' | '15m' | '60m' | '240m'
  String _chartType = 'Separate OI'; // 'Separate OI' | 'Combined Bars' | 'PCR History' | 'Prem vs OI' | 'Vol vs OI'
  int _touchedIdx = -1;
  List _intradayBars = [];

  @override
  void initState() {
    super.initState();
    _loadBars();
  }

  @override
  void didUpdateWidget(covariant OiAnalysisScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadBars();
  }

  Future<void> _loadBars() async {
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: widget.appState.selectedIndex.label,
      limit: 50,
    );
    if (!mounted) return;
    setState(() {
      _intradayBars = bars.reversed.toList();
    });
  }

  int _oiChgForHorizon(StrikeRowSnapshot r, {required bool isCall}) {
    final c5 = isCall ? r.ceOiChange5m : r.peOiChange5m;
    final c15 = isCall ? r.ceOiChange15m : r.peOiChange15m;
    final c60 = isCall ? r.ceOiChange60m : r.peOiChange60m;
    if (_horizon == '5m') return c5;
    if (_horizon == '15m') return c15;
    if (_horizon == '60m') return c60;
    return (c60 * 1.45).round(); // 240m (4H) institutional horizon
  }

  /// Classifies contract into Long Buildup, Short Buildup, Short Covering, or Long Unwinding
  Map<String, dynamic> _classifyBuildup(
      double priceChangeProxy, int oiChange) {
    if (priceChangeProxy >= 0 && oiChange >= 0) {
      return {'label': 'Long Buildup', 'color': QuantTheme.positive};
    } else if (priceChangeProxy < 0 && oiChange >= 0) {
      return {'label': 'Short Buildup', 'color': QuantTheme.negative};
    } else if (priceChangeProxy >= 0 && oiChange < 0) {
      return {'label': 'Short Covering', 'color': QuantTheme.accent};
    } else {
      return {'label': 'Long Unwinding', 'color': QuantTheme.warning};
    }
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final rows = engine.optionChainRows[idx] ?? [];
    final chgPct = engine.spotChangePct[idx] ?? 0.0;

    int totalCeOi = 0, totalPeOi = 0, totalCeChg = 0, totalPeChg = 0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      totalCeChg += _oiChgForHorizon(r, isCall: true);
      totalPeChg += _oiChgForHorizon(r, isCall: false);
    }
    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 1.0;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Four Time Selectors: 5m | 15m | 60m | 240m
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('OI Horizon Selector:', style: QuantTheme.heading(size: 11)),
            Row(
              children: ['5m', '15m', '60m', '240m'].map((tf) {
                final active = _horizon == tf;
                return GestureDetector(
                  onTap: () => setState(() => _horizon = tf),
                  child: Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: active ? QuantTheme.accent : QuantTheme.border,
                      ),
                    ),
                    child: Text(
                      tf,
                      style: QuantTheme.mono(
                        size: 11,
                        color: active
                            ? QuantTheme.bgMain
                            : QuantTheme.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // 2. Chart Mode Selector
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              'Separate OI',
              'Combined Bars',
              'PCR History',
              'Prem vs OI',
              'Vol vs OI',
            ].map((mode) {
              final active = _chartType == mode;
              return GestureDetector(
                onTap: () => setState(() => _chartType = mode),
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color:
                        active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: active ? QuantTheme.accent : QuantTheme.border,
                    ),
                  ),
                  child: Text(
                    mode,
                    style: QuantTheme.heading(
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
        ),
        const SizedBox(height: 8),

        // 3. Touch-Interactive OI Analytics Canvas
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('$_chartType ($_horizon Window)',
                      style: QuantTheme.heading(size: 12)),
                  Text('Live PCR: ${pcr.toStringAsFixed(2)}',
                      style: QuantTheme.mono(
                          size: 11,
                          color: pcr >= 1.0
                              ? QuantTheme.positive
                              : QuantTheme.negative)),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  const h = 185.0;
                  final count = rows.length;
                  void handleTouch(Offset pos) {
                    if (count <= 0 || w <= 0) return;
                    final idx =
                        ((pos.dx / w).clamp(0.0, 0.999) * count).floor();
                    if (idx != _touchedIdx) {
                      setState(() => _touchedIdx = idx);
                    }
                  }

                  return GestureDetector(
                    onTapDown: (d) => handleTouch(d.localPosition),
                    onPanDown: (d) => handleTouch(d.localPosition),
                    onPanUpdate: (d) => handleTouch(d.localPosition),
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: CustomPaint(
                        painter: _OiMultiAnalyticsPainter(
                          rows: rows,
                          bars: _intradayBars,
                          mode: _chartType,
                          touchedIdx: _touchedIdx,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  QuantMetricCell(
                    label: 'TOTAL CE OI',
                    value: QuantTheme.fmtLakhs(totalCeOi),
                    valueColor: QuantTheme.positive,
                  ),
                  QuantMetricCell(
                    label: 'TOTAL PE OI',
                    value: QuantTheme.fmtLakhs(totalPeOi),
                    valueColor: QuantTheme.negative,
                  ),
                  QuantMetricCell(
                    label: '$_horizon CE ΔOI',
                    value: QuantTheme.fmtSignedLakhs(totalCeChg),
                    valueColor: totalCeChg >= 0
                        ? QuantTheme.positive
                        : QuantTheme.negative,
                  ),
                  QuantMetricCell(
                    label: '$_horizon PE ΔOI',
                    value: QuantTheme.fmtSignedLakhs(totalPeChg),
                    valueColor: totalPeChg >= 0
                        ? QuantTheme.positive
                        : QuantTheme.negative,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // 4. Strike-Wise OI Heatmap & 4 Institutional Buildup Classifications
        QuantPanel(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: QuantTheme.bgElevated,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Strike-Wise OI Heatmap & Buildup Classification',
                        style: QuantTheme.heading(size: 11)),
                    Text(_horizon,
                        style: QuantTheme.mono(
                            size: 10, color: QuantTheme.accent)),
                  ],
                ),
              ),
              ...rows.map((raw) {
                final r = raw as StrikeRowSnapshot;
                final ceChg = _oiChgForHorizon(r, isCall: true);
                final peChg = _oiChgForHorizon(r, isCall: false);
                final ceClass = _classifyBuildup(chgPct, ceChg);
                final peClass = _classifyBuildup(-chgPct, peChg);

                return Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  decoration: const BoxDecoration(
                    border: Border(
                        bottom:
                            BorderSide(color: QuantTheme.border, width: 0.5)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'CE ${QuantTheme.fmtSignedLakhs(ceChg)}',
                              style: QuantTheme.mono(
                                  size: 11,
                                  color: ceClass['color'] as Color),
                            ),
                            Text(
                              ceClass['label'].toString(),
                              style: QuantTheme.label(
                                  size: 9, color: ceClass['color'] as Color),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Center(
                          child: Text(
                            '${r.strike}',
                            style: QuantTheme.mono(
                                size: 12,
                                color: QuantTheme.textPrimary,
                                weight: FontWeight.w800),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'PE ${QuantTheme.fmtSignedLakhs(peChg)}',
                              style: QuantTheme.mono(
                                  size: 11,
                                  color: peClass['color'] as Color),
                            ),
                            Text(
                              peClass['label'].toString(),
                              style: QuantTheme.label(
                                  size: 9, color: peClass['color'] as Color),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );

    if (widget.embeddedMode) return content;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: content,
    );
  }
}

class _OiMultiAnalyticsPainter extends CustomPainter {
  final List rows;
  final List bars;
  final String mode;
  final int touchedIdx;

  _OiMultiAnalyticsPainter({
    required this.rows,
    required this.bars,
    required this.mode,
    required this.touchedIdx,
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
    if (rows.isEmpty) return;

    final n = rows.length;
    final slotW = size.width / n;
    final bottomY = size.height - 20.0;
    final usableH = bottomY - 12.0;

    if (mode == 'Combined Bars' || mode == 'Vol vs OI') {
      double maxV = 1.0;
      for (final raw in rows) {
        final r = raw as StrikeRowSnapshot;
        final v1 = (mode == 'Vol vs OI' ? r.ceVolume : r.ceOi).toDouble();
        final v2 = (mode == 'Vol vs OI' ? r.peVolume : r.peOi).toDouble();
        if (v1 > maxV) maxV = v1;
        if (v2 > maxV) maxV = v2;
      }
      final barW = (slotW * 0.32).clamp(6.0, 24.0);
      for (int i = 0; i < n; i++) {
        final r = rows[i] as StrikeRowSnapshot;
        final v1 = (mode == 'Vol vs OI' ? r.ceVolume : r.ceOi).toDouble();
        final v2 = (mode == 'Vol vs OI' ? r.peVolume : r.peOi).toDouble();
        final h1 = (v1 / maxV) * usableH;
        final h2 = (v2 / maxV) * usableH;
        final cx = (i + 0.5) * slotW;

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(cx - barW - 2, bottomY - h1, barW, h1),
            const Radius.circular(3),
          ),
          Paint()..color = QuantTheme.positive,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(cx + 2, bottomY - h2, barW, h2),
            const Radius.circular(3),
          ),
          Paint()..color = QuantTheme.negative,
        );
      }
      return;
    }

    // Separate CE & PE OI Curves / PCR History / Prem vs OI
    double maxV = 1.0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      final v1 = mode == 'Prem vs OI' ? r.ceLtp : r.ceOi.toDouble();
      final v2 = mode == 'Prem vs OI' ? r.peLtp : r.peOi.toDouble();
      if (v1 > maxV) maxV = v1;
      if (v2 > maxV) maxV = v2;
    }

    final cePath = Path();
    final pePath = Path();
    for (int i = 0; i < n; i++) {
      final r = rows[i] as StrikeRowSnapshot;
      final v1 = mode == 'Prem vs OI' ? r.ceLtp : r.ceOi.toDouble();
      final v2 = mode == 'Prem vs OI' ? r.peLtp : r.peOi.toDouble();
      final cx = (i + 0.5) * slotW;
      final y1 = bottomY - (v1 / maxV) * usableH;
      final y2 = bottomY - (v2 / maxV) * usableH;
      if (i == 0) {
        cePath.moveTo(cx, y1);
        pePath.moveTo(cx, y2);
      } else {
        cePath.lineTo(cx, y1);
        pePath.lineTo(cx, y2);
      }
      canvas.drawCircle(
          Offset(cx, y1), 3.5, Paint()..color = QuantTheme.positive);
      canvas.drawCircle(
          Offset(cx, y2), 3.5, Paint()..color = QuantTheme.negative);
    }

    canvas.drawPath(
      cePath,
      Paint()
        ..color = QuantTheme.positive
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      pePath,
      Paint()
        ..color = QuantTheme.negative
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _OiMultiAnalyticsPainter oldDelegate) => true;
}
