import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/flow_data_engine.dart';
import '../theme/quant_theme.dart';

/// 1. Money Rotation Particle Flow Painter (Outflows left <- | -> Inflows right)
class MoneyRotationPainter extends CustomPainter {
  final List<SectorFlowSnapshot> outflows;
  final List<SectorFlowSnapshot> inflows;
  final double animValue; // 0.0 .. 1.0

  MoneyRotationPainter({
    required this.outflows,
    required this.inflows,
    required this.animValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midX = size.width * 0.5;
    final topPad = 14.0;
    final botPad = 14.0;
    final usableH = size.height - topPad - botPad;

    // Central spine bar
    final spinePaint = Paint()
      ..color = QuantTheme.accent
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(midX, topPad),
      Offset(midX, size.height - botPad),
      spinePaint,
    );

    final outRows = outflows.take(4).toList();
    final inRows = inflows.take(4).toList();

    // Draw Left Outflow ribbons & moving particles
    for (int i = 0; i < outRows.length; i++) {
      final yEnd = topPad + ((i + 0.5) / math.max(1, outRows.length)) * usableH;
      final yStart = topPad + ((i + 0.5) / math.max(1, outRows.length)) * usableH * 0.8 + usableH * 0.1;
      final xEnd = 78.0;

      final ribbon = Path()
        ..moveTo(midX - 4, yStart)
        ..cubicTo(midX - 40, yStart, xEnd + 40, yEnd, xEnd, yEnd);
      canvas.drawPath(
        ribbon,
        Paint()
          ..color = QuantTheme.negative.withOpacity(0.18)
          ..strokeWidth = 9.0
          ..style = PaintingStyle.stroke,
      );

      // Animated red particles flowing left
      for (int p = 0; p < 5; p++) {
        final t = (animValue + p * 0.2 + i * 0.07) % 1.0;
        final px = midX - 4 - (midX - 4 - xEnd) * t;
        final py = yStart + (yEnd - yStart) * t + math.sin(t * math.pi * 2) * 3;
        canvas.drawCircle(
          Offset(px, py),
          2.6,
          Paint()..color = QuantTheme.negative.withOpacity(0.85),
        );
      }

      _drawLabel(
        canvas,
        '${outRows[i].name} ${outRows[i].changePct.toStringAsFixed(1)}%',
        Offset(4, yEnd - 7),
        QuantTheme.negative,
        TextAlign.left,
      );
    }

    // Draw Right Inflow ribbons & moving particles
    for (int i = 0; i < inRows.length; i++) {
      final yEnd = topPad + ((i + 0.5) / math.max(1, inRows.length)) * usableH;
      final yStart = topPad + ((i + 0.5) / math.max(1, inRows.length)) * usableH * 0.8 + usableH * 0.1;
      final xEnd = size.width - 78.0;

      final ribbon = Path()
        ..moveTo(midX + 4, yStart)
        ..cubicTo(midX + 40, yStart, xEnd - 40, yEnd, xEnd, yEnd);
      canvas.drawPath(
        ribbon,
        Paint()
          ..color = QuantTheme.positive.withOpacity(0.18)
          ..strokeWidth = 9.0
          ..style = PaintingStyle.stroke,
      );

      // Animated green particles flowing right
      for (int p = 0; p < 5; p++) {
        final t = (animValue + p * 0.2 + i * 0.09) % 1.0;
        final px = midX + 4 + (xEnd - (midX + 4)) * t;
        final py = yStart + (yEnd - yStart) * t + math.sin(t * math.pi * 2) * 3;
        canvas.drawCircle(
          Offset(px, py),
          2.6,
          Paint()..color = QuantTheme.positive.withOpacity(0.85),
        );
      }

      _drawLabel(
        canvas,
        '${inRows[i].name} +${inRows[i].changePct.toStringAsFixed(1)}%',
        Offset(xEnd + 6, yEnd - 7),
        QuantTheme.positive,
        TextAlign.left,
      );
    }
  }

  void _drawLabel(
      Canvas canvas, String text, Offset pos, Color color, TextAlign align) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: QuantTheme.mono(size: 9, color: color, weight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: 74);
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant MoneyRotationPainter oldDelegate) => true;
}

/// 2. "Follow the Money" Radial Hub -> Sectors Order Flow Painter
class OrderFlowHubPainter extends CustomPainter {
  final List<SectorFlowSnapshot> sectors;
  final double animValue;

  OrderFlowHubPainter({required this.sectors, required this.animValue});

  @override
  void paint(Canvas canvas, Size size) {
    final hubCenter = Offset(58, size.height * 0.5);
    const hubRadius = 42.0;

    // Subtle technical grid
    final gridPaint = Paint()
      ..color = QuantTheme.border.withOpacity(0.25)
      ..strokeWidth = 0.6;
    for (double x = 0; x < size.width; x += 24) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += 24) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final topSectors = sectors.take(6).toList();
    final rightX = size.width * 0.56;
    final rowH = (size.height - 16) / math.max(1, topSectors.length);

    for (int i = 0; i < topSectors.length; i++) {
      final s = topSectors[i];
      final targetY = 8 + (i + 0.5) * rowH;
      final col = s.isInflow ? QuantTheme.positive : QuantTheme.negative;

      final path = Path()
        ..moveTo(hubCenter.dx + hubRadius, hubCenter.dy)
        ..cubicTo(
          hubCenter.dx + hubRadius + 38,
          hubCenter.dy,
          rightX - 38,
          targetY,
          rightX,
          targetY,
        );

      canvas.drawPath(
        path,
        Paint()
          ..color = col.withOpacity(0.45)
          ..strokeWidth = (1.5 + s.changePct.abs()).clamp(1.5, 4.0)
          ..style = PaintingStyle.stroke,
      );

      // Travelling money pulse dot along the curve
      final t = (animValue + i * 0.16) % 1.0;
      final pm = path.computeMetrics().first;
      final pos = pm.getTangentForOffset(pm.length * t)?.position;
      if (pos != null) {
        canvas.drawCircle(pos, 3.0, Paint()..color = col);
      }

      // Sector pill card on right
      final cardRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(rightX + 4, targetY - 13, size.width - rightX - 8, 26),
        const Radius.circular(6),
      );
      canvas.drawRRect(cardRect, Paint()..color = QuantTheme.bgSecondary);
      canvas.drawRRect(
        cardRect,
        Paint()
          ..color = col.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );

      final tp = TextPainter(
        text: TextSpan(
          children: [
            TextSpan(
              text: '${s.name}  ',
              style: QuantTheme.heading(size: 9.5, color: QuantTheme.textPrimary),
            ),
            TextSpan(
              text:
                  '${s.changePct >= 0 ? "+" : ""}${s.changePct.toStringAsFixed(2)}%',
              style: QuantTheme.mono(size: 9.5, color: col),
            ),
          ],
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - rightX - 16);
      tp.paint(canvas, Offset(rightX + 10, targetY - 6));
    }

    // Draw Left Hub Circle
    canvas.drawCircle(
      hubCenter,
      hubRadius + 5,
      Paint()..color = QuantTheme.accent.withOpacity(0.12),
    );
    canvas.drawCircle(
      hubCenter,
      hubRadius,
      Paint()..color = QuantTheme.bgElevated,
    );
    canvas.drawCircle(
      hubCenter,
      hubRadius,
      Paint()
        ..color = QuantTheme.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final hubTp = TextPainter(
      text: TextSpan(
        text: 'NSE\nFLOW\n${sectors.length} SECT',
        style: QuantTheme.mono(
            size: 9, color: QuantTheme.textPrimary, weight: FontWeight.w800),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: hubRadius * 1.8);
    hubTp.paint(
      canvas,
      Offset(hubCenter.dx - hubTp.width / 2, hubCenter.dy - hubTp.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant OrderFlowHubPainter oldDelegate) => true;
}

/// 3. Order Book Wall Depth Painter (Cumulative Bid Wall Green vs Ask Wall Red)
class OrderBookWallPainter extends CustomPainter {
  final List<StrikeRowSnapshot> rows;
  final double spot;

  OrderBookWallPainter({required this.rows, required this.spot});

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty || spot <= 0) return;

    final sorted = List<StrikeRowSnapshot>.from(rows)
      ..sort((a, b) => a.strike.compareTo(b.strike));

    // Left side: Put/Bid support walls (below spot); Right side: Call/Ask resistance walls (above spot)
    final leftSide = sorted.where((r) => r.strike <= spot).toList();
    final rightSide = sorted.where((r) => r.strike >= spot).toList();

    final midX = size.width * 0.5;
    final botY = size.height - 16.0;
    final usableH = botY - 16.0;

    // Cumulative depth moving outward from spot
    final bidCum = <double>[];
    double sumB = 0;
    for (int i = leftSide.length - 1; i >= 0; i--) {
      final r = leftSide[i];
      sumB += (r.peBidQty + r.ceBidQty + r.peOi).toDouble();
      bidCum.add(sumB);
    }

    final askCum = <double>[];
    double sumA = 0;
    for (int i = 0; i < rightSide.length; i++) {
      final r = rightSide[i];
      sumA += (r.ceAskQty + r.peAskQty + r.ceOi).toDouble();
      askCum.add(sumA);
    }

    final maxVal = math.max(
      1.0,
      math.max(bidCum.isNotEmpty ? bidCum.last : 1.0,
          askCum.isNotEmpty ? askCum.last : 1.0),
    );

    // Draw Green Bid Wall (left)
    if (bidCum.isNotEmpty) {
      final path = Path()..moveTo(midX, botY);
      final step = (midX - 6) / math.max(1, bidCum.length);
      for (int i = 0; i < bidCum.length; i++) {
        final x = midX - (i + 1) * step;
        final y = botY - (bidCum[i] / maxVal) * usableH;
        path.lineTo(x, y);
      }
      final fill = Path.from(path)
        ..lineTo(6, botY)
        ..close();
      canvas.drawPath(
          fill, Paint()..color = QuantTheme.positive.withOpacity(0.22));
      canvas.drawPath(
        path,
        Paint()
          ..color = QuantTheme.positive
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
      );
    }

    // Draw Red Ask Wall (right)
    if (askCum.isNotEmpty) {
      final path = Path()..moveTo(midX, botY);
      final step = (midX - 6) / math.max(1, askCum.length);
      for (int i = 0; i < askCum.length; i++) {
        final x = midX + (i + 1) * step;
        final y = botY - (askCum[i] / maxVal) * usableH;
        path.lineTo(x, y);
      }
      final fill = Path.from(path)
        ..lineTo(size.width - 6, botY)
        ..close();
      canvas.drawPath(
          fill, Paint()..color = QuantTheme.negative.withOpacity(0.22));
      canvas.drawPath(
        path,
        Paint()
          ..color = QuantTheme.negative
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
      );
    }

    // Center dashed spot divider
    canvas.drawLine(
      Offset(midX, 8),
      Offset(midX, botY),
      Paint()
        ..color = QuantTheme.textSecondary.withOpacity(0.6)
        ..strokeWidth = 1.0,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: 'SPOT ${spot.toStringAsFixed(0)}',
        style: QuantTheme.mono(size: 9, color: QuantTheme.accent),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(midX - tp.width / 2, botY + 2));
  }

  @override
  bool shouldRepaint(covariant OrderBookWallPainter oldDelegate) => true;
}

/// 4. 8-Signal Radar Spider Chart Painter (OI, Options, VWAP, Vol Profile, RSI, Price Action, VIX Calm, S/R Room)
class SignalRadarPainter extends CustomPainter {
  final RadarSignalAxes axes;

  SignalRadarPainter({required this.axes});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.34;
    const labels = [
      'OI',
      'Options',
      'VWAP',
      'Vol Profile',
      'RSI',
      'Price Action',
      'VIX Calm',
      'S/R Room',
    ];
    final values = [
      axes.oiScore,
      axes.optionsScore,
      axes.vwapScore,
      axes.volProfileScore,
      axes.rsiScore,
      axes.priceActionScore,
      axes.vixCalmScore,
      axes.srRoomScore,
    ];

    final ringPaint = Paint()
      ..color = QuantTheme.border.withOpacity(0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // 4 Concentric octagons
    for (int ring = 1; ring <= 4; ring++) {
      final r = radius * (ring / 4.0);
      final p = Path();
      for (int i = 0; i < 8; i++) {
        final angle = -math.pi / 2 + (i * 2 * math.pi / 8);
        final pt =
            Offset(center.dx + r * math.cos(angle), center.dy + r * math.sin(angle));
        if (i == 0) {
          p.moveTo(pt.dx, pt.dy);
        } else {
          p.lineTo(pt.dx, pt.dy);
        }
      }
      p.close();
      canvas.drawPath(p, ringPaint);
    }

    // Spokes + Labels
    final poly = Path();
    final pts = <Offset>[];
    for (int i = 0; i < 8; i++) {
      final angle = -math.pi / 2 + (i * 2 * math.pi / 8);
      final outer = Offset(center.dx + radius * math.cos(angle),
          center.dy + radius * math.sin(angle));
      canvas.drawLine(center, outer, ringPaint);

      final v = values[i];
      final norm = ((v ?? 50.0) / 100.0).clamp(0.08, 1.0);
      final pt = Offset(center.dx + radius * norm * math.cos(angle),
          center.dy + radius * norm * math.sin(angle));
      pts.add(pt);
      if (i == 0) {
        poly.moveTo(pt.dx, pt.dy);
      } else {
        poly.lineTo(pt.dx, pt.dy);
      }

      // Label placement
      final lblPos = Offset(
        center.dx + (radius + 26) * math.cos(angle),
        center.dy + (radius + 22) * math.sin(angle),
      );
      final valStr = v != null ? v.round().toString() : 'n/a';
      final tp = TextPainter(
        text: TextSpan(
          children: [
            TextSpan(
              text: '${labels[i]}\n',
              style: QuantTheme.label(size: 8.5, color: QuantTheme.textSecondary),
            ),
            TextSpan(
              text: valStr,
              style: QuantTheme.mono(
                size: 9.5,
                color: v == null
                    ? QuantTheme.textSecondary
                    : (v >= 55
                        ? QuantTheme.positive
                        : (v <= 45 ? QuantTheme.negative : QuantTheme.accent)),
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(lblPos.dx - tp.width / 2, lblPos.dy - tp.height / 2));
    }
    poly.close();

    final bias = axes.overallBias;
    final polyColor = bias == 'bullish'
        ? QuantTheme.positive
        : (bias == 'bearish' ? QuantTheme.negative : QuantTheme.accent);

    canvas.drawPath(poly, Paint()..color = polyColor.withOpacity(0.22));
    canvas.drawPath(
      poly,
      Paint()
        ..color = polyColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );
    for (final pt in pts) {
      canvas.drawCircle(pt, 3.2, Paint()..color = polyColor);
    }
  }

  @override
  bool shouldRepaint(covariant SignalRadarPainter oldDelegate) => true;
}
