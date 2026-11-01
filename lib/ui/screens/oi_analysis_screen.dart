import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/math_greeks.dart';
import '../../state/app_state.dart';

class OiAnalysisScreen extends StatefulWidget {
  final AppState appState;

  const OiAnalysisScreen({super.key, required this.appState});

  @override
  State<OiAnalysisScreen> createState() => _OiAnalysisScreenState();
}

class _OiAnalysisScreenState extends State<OiAnalysisScreen> {
  String _selectedMetricTab = 'OI'; // 'OI', 'Price', 'Volume', 'IV'
  String _oiLookback = '15m'; // '5m', '15m', '60m'
  int _touchedIndex = -1;
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
    final idxName = widget.appState.selectedIndex.label;
    final bars = await ForeverDatabase.instance
        .getRecentBars(indexName: idxName, limit: 40);
    if (!mounted) return;
    setState(() {
      _intradayBars = bars.reversed.toList();
    });
  }

  String _fmtLakhs(num val) {
    final v = val.toDouble();
    if (v.abs() >= 100000) {
      return '${(v / 100000.0).toStringAsFixed(2)}L';
    }
    if (v.abs() >= 1000) {
      return '${(v / 1000.0).toStringAsFixed(1)}K';
    }
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final rows = engine.optionChainRows[idx] ?? [];
    final spot = engine.spotPrices[idx] ?? 0.0;
    final ai = AiRecalibrationEngine.instance;

    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeChg = 0;
    int totalPeChg = 0;
    double atmCeIv = 0.0;
    double atmPeIv = 0.0;

    for (final r in rows) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      final cChg = _oiLookback == '5m'
          ? r.ceOiChange5m
          : (_oiLookback == '15m' ? r.ceOiChange15m : r.ceOiChange60m);
      final pChg = _oiLookback == '5m'
          ? r.peOiChange5m
          : (_oiLookback == '15m' ? r.peOiChange15m : r.peOiChange60m);
      totalCeChg += cChg;
      totalPeChg += pChg;
      if (r.offset == 0) {
        atmCeIv = r.ceIv;
        atmPeIv = r.peIv;
      }
    }

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 0.0;
    final ivSkew = atmPeIv - atmCeIv;
    final netGex = MathGreeksEngine.computeNetGammaExposure(rows, spot);
    final healthScore =
        ((1.0 - ai.probChopRegime) * 100.0).clamp(15.0, 98.0);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Index Switcher (NIFTY 50 | BANK NIFTY | FINNIFTY)
          Row(
            children: UnderlyingIndex.values.map((u) {
              final active = idx == u;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _touchedIndex = -1);
                    widget.appState.setSelectedUnderlying(u);
                    _loadBars();
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      u.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // AI & Quantitative Market Health Monitor Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.monitor_heart,
                            color: Color(0xFF00E676), size: 18),
                        const SizedBox(width: 6),
                        Text(
                          'AI Market Health (${idx.label})',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: healthScore >= 60
                            ? const Color(0xFF00C853).withOpacity(0.2)
                            : const Color(0xFFFFAB00).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Health: ${healthScore.toStringAsFixed(0)}/100',
                        style: TextStyle(
                          color: healthScore >= 60
                              ? const Color(0xFF00E676)
                              : const Color(0xFFFFAB00),
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _healthMetric('Live PCR', pcr.toStringAsFixed(2),
                        pcr >= 1.0 ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                    _healthMetric('IV Skew (PE-CE)',
                        '${ivSkew >= 0 ? "+" : ""}${ivSkew.toStringAsFixed(1)}%',
                        Colors.cyanAccent),
                    _healthMetric(
                        'Net GEX',
                        netGex >= 0 ? '+Pin/Support' : '-Breakout Vol',
                        netGex >= 0
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFFAB00)),
                    _healthMetric(
                        'HMM Regime',
                        ai.probBullRegime >= ai.probBearRegime
                            ? 'Bull ${(ai.probBullRegime * 100).toStringAsFixed(0)}%'
                            : 'Bear ${(ai.probBearRegime * 100).toStringAsFixed(0)}%',
                        ai.probBullRegime >= ai.probBearRegime
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFF5252)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Metric Mode Switcher (OI | Price | Volume | IV)
          Row(
            children: ['OI', 'Price', 'Volume', 'IV'].map((tab) {
              final active = _selectedMetricTab == tab;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() {
                    _selectedMetricTab = tab;
                    _touchedIndex = -1;
                  }),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF2979FF)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active
                            ? const Color(0xFF2979FF)
                            : const Color(0xFF1E325C),
                      ),
                    ),
                    child: Text(
                      tab,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Lookback selector when OI tab is active
          if (_selectedMetricTab == 'OI')
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'OI Change Window:',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Row(
                    children: ['5m', '15m', '60m'].map((lb) {
                      final active = _oiLookback == lb;
                      return GestureDetector(
                        onTap: () => setState(() => _oiLookback = lb),
                        child: Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: active
                                ? const Color(0xFF00C853)
                                : const Color(0xFF101B33),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            lb,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),

          // Main Touch-Interactive Chart Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: rows.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'Waiting for live broker data...',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInteractiveHeader(rows),
                      const SizedBox(height: 10),
                      _buildInteractiveCanvas(rows),
                      const SizedBox(height: 6),
                      const Center(
                        child: Text(
                          '👆 Touch or drag across any bar/line to inspect live values',
                          style: TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),

          // Summary Totals Footer
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _healthMetric('Total CE OI', _fmtLakhs(totalCeOi),
                    const Color(0xFF00E676)),
                _healthMetric('Total PE OI', _fmtLakhs(totalPeOi),
                    const Color(0xFFFF5252)),
                _healthMetric('$_oiLookback CE Chg',
                    '${totalCeChg >= 0 ? "+" : ""}${_fmtLakhs(totalCeChg)}',
                    const Color(0xFF00E676)),
                _healthMetric('$_oiLookback PE Chg',
                    '${totalPeChg >= 0 ? "+" : ""}${_fmtLakhs(totalPeChg)}',
                    const Color(0xFFFF5252)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _healthMetric(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 10)),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildInteractiveHeader(List rows) {
    if (_selectedMetricTab == 'Price' && _intradayBars.isNotEmpty) {
      final idx = (_touchedIndex >= 0 && _touchedIndex < _intradayBars.length)
          ? _touchedIndex
          : _intradayBars.length - 1;
      final b = _intradayBars[idx] as OneMinEnrichedBar;
      final ts = DateFormat('HH:mm')
          .format(DateTime.fromMillisecondsSinceEpoch(b.timestampMs));
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Time: $ts (${b.strike} ${b.optionType})',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('Spot: ${b.underlyingSpot.toStringAsFixed(1)}',
                style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
            Text(
                'O:${b.open.toStringAsFixed(1)} H:${b.high.toStringAsFixed(1)} L:${b.low.toStringAsFixed(1)} C:${b.close.toStringAsFixed(1)}',
                style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    }

    final idx = (_touchedIndex >= 0 && _touchedIndex < rows.length)
        ? _touchedIndex
        : rows.length ~/ 2;
    final r = rows[idx] as StrikeRowSnapshot;

    if (_selectedMetricTab == 'OI') {
      final ceChg = _oiLookback == '5m'
          ? r.ceOiChange5m
          : (_oiLookback == '15m' ? r.ceOiChange15m : r.ceOiChange60m);
      final peChg = _oiLookback == '5m'
          ? r.peOiChange5m
          : (_oiLookback == '15m' ? r.peOiChange15m : r.peOiChange60m);
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Strike: ${r.strike}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
            Text('CE OI: ${_fmtLakhs(r.ceOi)} (${_fmtLakhs(ceChg)})',
                style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('PE OI: ${_fmtLakhs(r.peOi)} (${_fmtLakhs(peChg)})',
                style: const TextStyle(
                    color: Color(0xFFFF5252),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    } else if (_selectedMetricTab == 'Volume') {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Strike: ${r.strike}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
            Text('CE Vol: ${_fmtLakhs(r.ceVolume)}',
                style: const TextStyle(
                    color: Color(0xFF2979FF),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('PE Vol: ${_fmtLakhs(r.peVolume)}',
                style: const TextStyle(
                    color: Color(0xFFFFAB00),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    } else {
      // IV & Greeks tab
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Strike: ${r.strike}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
            Text('CE IV: ${r.ceIv.toStringAsFixed(2)}% (Δ ${r.ceDelta.toStringAsFixed(2)})',
                style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('PE IV: ${r.peIv.toStringAsFixed(2)}% (θ ${r.ceTheta.toStringAsFixed(1)})',
                style: const TextStyle(
                    color: Color(0xFFFF5252),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    }
  }

  Widget _buildInteractiveCanvas(List rows) {
    final itemCount = (_selectedMetricTab == 'Price' && _intradayBars.isNotEmpty)
        ? _intradayBars.length
        : rows.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        const h = 210.0;

        void handleTouch(Offset localPos) {
          if (itemCount <= 0 || w <= 0) return;
          final ratio = (localPos.dx / w).clamp(0.0, 0.999);
          final idx = (ratio * itemCount).floor();
          if (idx != _touchedIndex) {
            setState(() => _touchedIndex = idx);
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
              painter: _InteractiveMetricPainter(
                mode: _selectedMetricTab,
                rows: rows,
                bars: _intradayBars,
                touchedIndex: _touchedIndex,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _InteractiveMetricPainter extends CustomPainter {
  final String mode;
  final List rows;
  final List bars;
  final int touchedIndex;

  _InteractiveMetricPainter({
    required this.mode,
    required this.rows,
    required this.bars,
    required this.touchedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0xFF1E325C).withOpacity(0.5)
      ..strokeWidth = 1;

    for (int i = 1; i <= 3; i++) {
      final y = size.height * (i / 4.0);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (mode == 'Price' && bars.isNotEmpty) {
      _paintPriceCandlesAndLine(canvas, size);
      return;
    }

    if (rows.isEmpty) return;

    if (mode == 'OI' || mode == 'Volume') {
      _paintDualStrikeBars(canvas, size, isVolume: mode == 'Volume');
    } else {
      _paintIvSkewCurve(canvas, size);
    }
  }

  void _paintDualStrikeBars(Canvas canvas, Size size, {required bool isVolume}) {
    double maxVal = 1.0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      final v1 = (isVolume ? r.ceVolume : r.ceOi).toDouble();
      final v2 = (isVolume ? r.peVolume : r.peOi).toDouble();
      if (v1 > maxVal) maxVal = v1;
      if (v2 > maxVal) maxVal = v2;
    }

    final n = rows.length;
    final slotW = size.width / n;
    final barW = (slotW * 0.32).clamp(6.0, 28.0);
    final bottomY = size.height - 22.0;
    final usableH = bottomY - 12.0;

    final cePaint = Paint()
      ..color = isVolume ? const Color(0xFF2979FF) : const Color(0xFF00E676);
    final pePaint = Paint()
      ..color = isVolume ? const Color(0xFFFFAB00) : const Color(0xFFFF5252);

    for (int i = 0; i < n; i++) {
      final r = rows[i] as StrikeRowSnapshot;
      final v1 = (isVolume ? r.ceVolume : r.ceOi).toDouble();
      final v2 = (isVolume ? r.peVolume : r.peOi).toDouble();

      final h1 = (v1 / maxVal) * usableH;
      final h2 = (v2 / maxVal) * usableH;
      final centerX = (i + 0.5) * slotW;

      if (i == touchedIndex) {
        final hlPaint = Paint()
          ..color = Colors.white.withOpacity(0.12)
          ..style = PaintingStyle.fill;
        canvas.drawRect(
            Rect.fromLTWH(i * slotW, 0, slotW, size.height), hlPaint);
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(centerX - barW - 2, bottomY - h1, barW, h1),
          const Radius.circular(4),
        ),
        cePaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(centerX + 2, bottomY - h2, barW, h2),
          const Radius.circular(4),
        ),
        pePaint,
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '${r.strike}',
          style: TextStyle(
            color: i == touchedIndex ? Colors.white : Colors.white60,
            fontSize: 10,
            fontWeight:
                i == touchedIndex ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - tp.width / 2, bottomY + 5));
    }
  }

  void _paintPriceCandlesAndLine(Canvas canvas, Size size) {
    double minP = double.infinity;
    double maxP = -double.infinity;
    for (final raw in bars) {
      final b = raw as OneMinEnrichedBar;
      if (b.low < minP) minP = b.low;
      if (b.high > maxP) maxP = b.high;
    }
    if (maxP <= minP) maxP = minP + 1.0;

    final n = bars.length;
    final stepX = size.width / math.max(1, n - 1);
    final usableH = size.height - 24.0;
    final path = Path();

    for (int i = 0; i < n; i++) {
      final b = bars[i] as OneMinEnrichedBar;
      final x = i * stepX;
      final y = usableH - ((b.close - minP) / (maxP - minP)) * (usableH - 16.0);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }

      // Draw high-low wick & candle body
      final yHigh =
          usableH - ((b.high - minP) / (maxP - minP)) * (usableH - 16.0);
      final yLow =
          usableH - ((b.low - minP) / (maxP - minP)) * (usableH - 16.0);
      final isBull = b.close >= b.open;
      final cPaint = Paint()
        ..color = isBull ? const Color(0xFF00E676) : const Color(0xFFFF5252)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(x, yHigh), Offset(x, yLow), cPaint);
    }

    final linePaint = Paint()
      ..color = const Color(0xFF2979FF)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, linePaint);

    if (touchedIndex >= 0 && touchedIndex < n) {
      final b = bars[touchedIndex] as OneMinEnrichedBar;
      final tx = touchedIndex * stepX;
      final ty =
          usableH - ((b.close - minP) / (maxP - minP)) * (usableH - 16.0);
      final crossPaint = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(tx, 0), Offset(tx, size.height), crossPaint);
      canvas.drawCircle(
          Offset(tx, ty), 4.5, Paint()..color = const Color(0xFF00E676));
    }
  }

  void _paintIvSkewCurve(Canvas canvas, Size size) {
    double minIv = 100.0;
    double maxIv = 5.0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      if (r.ceIv < minIv) minIv = r.ceIv;
      if (r.peIv < minIv) minIv = r.peIv;
      if (r.ceIv > maxIv) maxIv = r.ceIv;
      if (r.peIv > maxIv) maxIv = r.peIv;
    }
    minIv -= 1.0;
    maxIv += 1.0;

    final n = rows.length;
    final slotW = size.width / n;
    final bottomY = size.height - 22.0;
    final usableH = bottomY - 16.0;

    final cePath = Path();
    final pePath = Path();

    for (int i = 0; i < n; i++) {
      final r = rows[i] as StrikeRowSnapshot;
      final cx = (i + 0.5) * slotW;
      final cyCe =
          bottomY - ((r.ceIv - minIv) / (maxIv - minIv)) * usableH;
      final cyPe =
          bottomY - ((r.peIv - minIv) / (maxIv - minIv)) * usableH;

      if (i == 0) {
        cePath.moveTo(cx, cyCe);
        pePath.moveTo(cx, cyPe);
      } else {
        cePath.lineTo(cx, cyCe);
        pePath.lineTo(cx, cyPe);
      }

      canvas.drawCircle(
          Offset(cx, cyCe), 4.0, Paint()..color = const Color(0xFF00E676));
      canvas.drawCircle(
          Offset(cx, cyPe), 4.0, Paint()..color = const Color(0xFFFF5252));

      if (i == touchedIndex) {
        canvas.drawLine(Offset(cx, 0), Offset(cx, bottomY),
            Paint()..color = Colors.white54);
      }

      final tp = TextPainter(
        text: TextSpan(
          text: '${r.strike}',
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, bottomY + 5));
    }

    canvas.drawPath(
      cePath,
      Paint()
        ..color = const Color(0xFF00E676)
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      pePath,
      Paint()
        ..color = const Color(0xFFFF5252)
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _InteractiveMetricPainter oldDelegate) => true;
}
