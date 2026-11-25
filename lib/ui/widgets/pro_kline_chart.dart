import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../engine/trendline_engine.dart';
import '../theme/quant_theme.dart';

/// Native 60fps KLineChart-inspired candlestick chart with pinch-zoom, drag-pan,
/// crosshair HUD, EMA 9/21, VWAP, Volume histogram & pytrendline Auto S/R overlays.
class ProKLineChart extends StatefulWidget {
  final List<OneMinEnrichedBar> bars;
  final double? liveLtp;
  final double? entryLine;
  final double? stopLossLine;
  final double? targetLine;
  final bool showSpotOverlay;

  const ProKLineChart({
    super.key,
    required this.bars,
    this.liveLtp,
    this.entryLine,
    this.stopLossLine,
    this.targetLine,
    this.showSpotOverlay = false,
  });

  @override
  State<ProKLineChart> createState() => _ProKLineChartState();
}

class _ProKLineChartState extends State<ProKLineChart> {
  int _visibleCount = 42;
  int _rightOffset = 0; // 0 = anchored to latest candle
  int _touchedLocalIdx = -1;
  bool _showEma = true;
  bool _showVwap = true;
  bool _showTrendlines = true;

  double _scaleBaseCount = 42;
  double _dragAccumPx = 0.0;

  @override
  Widget build(BuildContext context) {
    final allBars = widget.bars;
    if (allBars.isEmpty) {
      return QuantPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              'NO DATA — Connect Angel One SmartAPI to stream real 1m candles.',
              textAlign: TextAlign.center,
              style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
            ),
          ),
        ),
      );
    }

    final total = allBars.length;
    final clampedVisible = _visibleCount.clamp(12, math.max(12, math.min(120, total)));
    final maxOffset = math.max(0, total - clampedVisible);
    final clampedOffset = _rightOffset.clamp(0, maxOffset);
    final endIdx = total - clampedOffset;
    final startIdx = math.max(0, endIdx - clampedVisible);
    final visibleBars = allBars.sublist(startIdx, endIdx);

    final sr = TrendlineEngine.detect(visibleBars, pivotWindow: 2);
    final selBar = (_touchedLocalIdx >= 0 && _touchedLocalIdx < visibleBars.length)
        ? visibleBars[_touchedLocalIdx]
        : visibleBars.last;

    final srBadgeColor = sr.breakoutState == 'ABOVE_RES'
        ? QuantTheme.positive
        : (sr.breakoutState == 'BELOW_SUP'
            ? QuantTheme.negative
            : QuantTheme.accent);

    return QuantPanel(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Controls: Overlay toggles + Auto-fit reset + S/R breakout status
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  _toggleChip('EMA', _showEma, () => setState(() => _showEma = !_showEma)),
                  _toggleChip('VWAP', _showVwap, () => setState(() => _showVwap = !_showVwap)),
                  _toggleChip('S/R', _showTrendlines,
                      () => setState(() => _showTrendlines = !_showTrendlines)),
                  _toggleChip('Reset', false, () {
                    setState(() {
                      _visibleCount = 42;
                      _rightOffset = 0;
                      _touchedLocalIdx = -1;
                    });
                  }),
                ],
              ),
              QuantBadge(text: sr.breakoutState, color: srBadgeColor),
            ],
          ),
          const SizedBox(height: 6),

          // Live OHLCV Crosshair HUD
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${DateFormat("HH:mm").format(DateTime.fromMillisecondsSinceEpoch(selBar.timestampMs))} • ${selBar.strike} ${selBar.optionType}',
                style: QuantTheme.heading(size: 10.5),
              ),
              Text(
                'O:${selBar.open.toStringAsFixed(1)} H:${selBar.high.toStringAsFixed(1)} L:${selBar.low.toStringAsFixed(1)} C:${selBar.close.toStringAsFixed(1)}',
                style: QuantTheme.mono(
                  size: 9.5,
                  color: selBar.close >= selBar.open
                      ? QuantTheme.positive
                      : QuantTheme.negative,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Interactive Pinch-Zoom + Pan + Crosshair Canvas
          LayoutBuilder(
            builder: (ctx, constraints) {
              final w = constraints.maxWidth;
              final chartW = w - 48.0; // reserve right price axis

              void updateCrosshair(Offset pos) {
                if (visibleBars.isEmpty || chartW <= 0) return;
                final i = ((pos.dx / chartW).clamp(0.0, 0.999) * visibleBars.length).floor();
                if (i != _touchedLocalIdx) {
                  setState(() => _touchedLocalIdx = i);
                }
              }

              return GestureDetector(
                onTapDown: (d) => updateCrosshair(d.localPosition),
                onDoubleTap: () => setState(() {
                  _visibleCount = 42;
                  _rightOffset = 0;
                  _touchedLocalIdx = -1;
                }),
                onScaleStart: (d) {
                  _scaleBaseCount = _visibleCount.toDouble();
                  _dragAccumPx = 0.0;
                },
                onScaleUpdate: (d) {
                  setState(() {
                    if (d.pointerCount >= 2 && (d.scale - 1.0).abs() > 0.02) {
                      _visibleCount = (_scaleBaseCount / d.scale)
                          .round()
                          .clamp(12, math.max(12, math.min(120, total)));
                    } else if (d.pointerCount == 1) {
                      _dragAccumPx += d.focalPointDelta.dx;
                      final pxPerBar = math.max(4.0, chartW / math.max(1, visibleBars.length));
                      if (_dragAccumPx.abs() >= pxPerBar) {
                        final shift = (_dragAccumPx / pxPerBar).truncate();
                        _rightOffset = (_rightOffset + shift).clamp(0, maxOffset);
                        _dragAccumPx -= shift * pxPerBar;
                      }
                      updateCrosshair(d.localFocalPoint);
                    }
                  });
                },
                child: SizedBox(
                  width: w,
                  height: 250,
                  child: CustomPaint(
                    painter: _ProKLinePainter(
                      bars: visibleBars,
                      trendlines: _showTrendlines ? sr : TrendlineAnalysis.empty,
                      touchedIdx: _touchedLocalIdx,
                      liveLtp: widget.liveLtp,
                      entryLine: widget.entryLine,
                      stopLossLine: widget.stopLossLine,
                      targetLine: widget.targetLine,
                      showEma: _showEma,
                      showVwap: _showVwap,
                      showSpotOverlay: widget.showSpotOverlay,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 6),

          // Footer: Auto Support / Resistance levels + Gesture Hint
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Sup: ${sr.currentSupport?.toStringAsFixed(1) ?? "N/A"} | Res: ${sr.currentResistance?.toStringAsFixed(1) ?? "N/A"}',
                style: QuantTheme.mono(size: 9.5, color: QuantTheme.accent),
              ),
              Text(
                'Pinch zoom • Drag pan • 2x tap reset',
                style: QuantTheme.label(size: 9),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toggleChip(String text, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: active ? QuantTheme.accent : QuantTheme.bgSecondary,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: active ? QuantTheme.accent : QuantTheme.border,
          ),
        ),
        child: Text(
          text,
          style: QuantTheme.mono(
            size: 9,
            color: active ? QuantTheme.bgMain : QuantTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ProKLinePainter extends CustomPainter {
  final List<OneMinEnrichedBar> bars;
  final TrendlineAnalysis trendlines;
  final int touchedIdx;
  final double? liveLtp;
  final double? entryLine;
  final double? stopLossLine;
  final double? targetLine;
  final bool showEma;
  final bool showVwap;
  final bool showSpotOverlay;

  _ProKLinePainter({
    required this.bars,
    required this.trendlines,
    required this.touchedIdx,
    required this.liveLtp,
    required this.entryLine,
    required this.stopLossLine,
    required this.targetLine,
    required this.showEma,
    required this.showVwap,
    required this.showSpotOverlay,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    const rightAxisW = 48.0;
    const volPaneH = 44.0;
    const topPad = 8.0;
    final chartW = size.width - rightAxisW;
    final priceH = size.height - volPaneH - topPad - 8.0;
    final volTop = topPad + priceH + 6.0;

    double minP = double.infinity, maxP = -double.infinity;
    double minS = double.infinity, maxS = -double.infinity;
    int maxVol = 1;

    for (final b in bars) {
      if (b.low < minP) minP = b.low;
      if (b.high > maxP) maxP = b.high;
      if (b.underlyingSpot < minS) minS = b.underlyingSpot;
      if (b.underlyingSpot > maxS) maxS = b.underlyingSpot;
      if (b.intervalVolume > maxVol) maxVol = b.intervalVolume;
    }
    if (liveLtp != null && liveLtp! > 0) {
      minP = math.min(minP, liveLtp!);
      maxP = math.max(maxP, liveLtp!);
    }
    final padP = math.max(0.5, (maxP - minP) * 0.08);
    minP -= padP;
    maxP += padP;
    if (maxS <= minS) maxS = minS + 1.0;

    double yFor(double p) =>
        topPad + priceH - (((p - minP) / math.max(1e-6, maxP - minP)) * priceH);

    // 1. Horizontal Grid & Right Price Axis Labels
    final gridPaint = Paint()
      ..color = QuantTheme.border.withOpacity(0.4)
      ..strokeWidth = 0.7;
    for (int i = 0; i <= 4; i++) {
      final frac = i / 4.0;
      final y = topPad + priceH * frac;
      canvas.drawLine(Offset(0, y), Offset(chartW, y), gridPaint);
      final pVal = maxP - frac * (maxP - minP);
      _drawText(canvas, pVal.toStringAsFixed(1), Offset(chartW + 4, y - 5),
          QuantTheme.textSecondary, 8.5);
    }
    canvas.drawLine(Offset(chartW, 0), Offset(chartW, size.height), gridPaint);
    canvas.drawLine(Offset(0, volTop - 2), Offset(chartW, volTop - 2), gridPaint);

    // 2. Candles + Volume Bars + EMA9/EMA21/VWAP paths
    final n = bars.length;
    final slotW = chartW / math.max(1, n);
    final candleW = (slotW * 0.62).clamp(2.0, 10.0);

    final ema9Path = Path();
    final ema21Path = Path();
    final vwapPath = Path();
    final spotPath = Path();

    double ema9 = bars.first.close;
    double ema21 = bars.first.close;
    double pvSum = 0.0, vSum = 0.0;

    for (int i = 0; i < n; i++) {
      final b = bars[i];
      final cx = (i + 0.5) * slotW;
      final isBull = b.close >= b.open;
      final col = isBull ? QuantTheme.positive : QuantTheme.negative;

      // Wick & Body
      canvas.drawLine(Offset(cx, yFor(b.high)), Offset(cx, yFor(b.low)),
          Paint()..color = col..strokeWidth = 1.1);
      final yO = yFor(b.open);
      final yC = yFor(b.close);
      canvas.drawRect(
        Rect.fromLTWH(cx - candleW / 2, math.min(yO, yC), candleW,
            math.max(1.8, (yO - yC).abs())),
        Paint()..color = col,
      );

      // Volume Histogram Bar
      final vH = (b.intervalVolume / maxVol) * (volPaneH - 4.0);
      canvas.drawRect(
        Rect.fromLTWH(cx - candleW / 2, size.height - vH - 2, candleW, vH),
        Paint()..color = col.withOpacity(0.45),
      );

      // EMA 9, EMA 21, VWAP
      ema9 = i == 0 ? b.close : (b.close * 0.2 + ema9 * 0.8);
      ema21 = i == 0 ? b.close : (b.close * (2.0 / 22.0) + ema21 * (20.0 / 22.0));
      final typ = (b.high + b.low + b.close) / 3.0;
      pvSum += typ * math.max(1, b.intervalVolume);
      vSum += math.max(1, b.intervalVolume);
      final vwap = pvSum / vSum;

      final ySpot = topPad + priceH -
          (((b.underlyingSpot - minS) / (maxS - minS)) * priceH);

      if (i == 0) {
        ema9Path.moveTo(cx, yFor(ema9));
        ema21Path.moveTo(cx, yFor(ema21));
        vwapPath.moveTo(cx, yFor(vwap));
        spotPath.moveTo(cx, ySpot);
      } else {
        ema9Path.lineTo(cx, yFor(ema9));
        ema21Path.lineTo(cx, yFor(ema21));
        vwapPath.lineTo(cx, yFor(vwap));
        spotPath.lineTo(cx, ySpot);
      }
    }

    if (showEma) {
      canvas.drawPath(
        ema9Path,
        Paint()
          ..color = const Color(0xFF38BDF8)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(
        ema21Path,
        Paint()
          ..color = const Color(0xFFC084FC)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
    }

    if (showVwap) {
      canvas.drawPath(
        vwapPath,
        Paint()
          ..color = QuantTheme.warning
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke,
      );
    }

    if (showSpotOverlay) {
      canvas.drawPath(
        spotPath,
        Paint()
          ..color = QuantTheme.accent.withOpacity(0.45)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke,
      );
    }

    // 3. pytrendline Auto Support & Resistance Trendlines
    if (trendlines.supportLine != null) {
      final s = trendlines.supportLine!;
      canvas.drawLine(
        Offset((s.startIdx + 0.5) * slotW, yFor(s.startPrice).clamp(topPad, topPad + priceH)),
        Offset((s.endIdx + 0.5) * slotW, yFor(s.endPrice).clamp(topPad, topPad + priceH)),
        Paint()
          ..color = QuantTheme.positive
          ..strokeWidth = 1.6,
      );
    }
    if (trendlines.resistanceLine != null) {
      final r = trendlines.resistanceLine!;
      canvas.drawLine(
        Offset((r.startIdx + 0.5) * slotW, yFor(r.startPrice).clamp(topPad, topPad + priceH)),
        Offset((r.endIdx + 0.5) * slotW, yFor(r.endPrice).clamp(topPad, topPad + priceH)),
        Paint()
          ..color = QuantTheme.negative
          ..strokeWidth = 1.6,
      );
    }

    // 4. Optional Signal SL / Target / Entry lines
    void drawHLine(double? price, Color col, String tag) {
      if (price == null || price < minP || price > maxP) return;
      final y = yFor(price);
      canvas.drawLine(
        Offset(0, y),
        Offset(chartW, y),
        Paint()..color = col.withOpacity(0.8)..strokeWidth = 1.0,
      );
      _drawText(canvas, tag, Offset(4, y - 10), col, 8.0);
    }

    drawHLine(entryLine, QuantTheme.accent, 'ENTRY');
    drawHLine(targetLine, QuantTheme.positive, 'TGT');
    drawHLine(stopLossLine, QuantTheme.negative, 'SL');

    // 5. Live LTP Dashed Horizontal Line + Right Axis Pill
    final ltpVal = (liveLtp != null && liveLtp! > 0) ? liveLtp! : bars.last.close;
    final yLtp = yFor(ltpVal).clamp(topPad, topPad + priceH);
    final dashPaint = Paint()
      ..color = QuantTheme.accent
      ..strokeWidth = 1.0;
    for (double x = 0; x < chartW; x += 7) {
      canvas.drawLine(Offset(x, yLtp), Offset(math.min(chartW, x + 4), yLtp), dashPaint);
    }
    final pill = RRect.fromRectAndRadius(
      Rect.fromLTWH(chartW + 2, yLtp - 7, rightAxisW - 3, 14),
      const Radius.circular(3),
    );
    canvas.drawRRect(pill, Paint()..color = QuantTheme.accent);
    _drawText(canvas, ltpVal.toStringAsFixed(1), Offset(chartW + 4, yLtp - 5),
        QuantTheme.bgMain, 8.0);

    // 6. Crosshair Overlay
    if (touchedIdx >= 0 && touchedIdx < n) {
      final cx = (touchedIdx + 0.5) * slotW;
      final cy = yFor(bars[touchedIdx].close);
      final crossPaint = Paint()
        ..color = QuantTheme.textSecondary.withOpacity(0.65)
        ..strokeWidth = 0.8;
      canvas.drawLine(Offset(cx, topPad), Offset(cx, size.height), crossPaint);
      canvas.drawLine(Offset(0, cy), Offset(chartW, cy), crossPaint);
    }
  }

  void _drawText(Canvas canvas, String text, Offset pos, Color col, double sz) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: QuantTheme.mono(size: sz, color: col, weight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _ProKLinePainter oldDelegate) => true;
}
