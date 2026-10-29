import 'dart:math' as math;
import 'package:flutter/material.dart';

class DualSeriesLineChart extends StatelessWidget {
  final List<double> greenSeries; // CE or Primary series
  final List<double> redSeries;   // PE or Secondary series
  final bool showGreen;
  final bool showRed;
  final String rightBadgeGreen;
  final String rightBadgeRed;
  final double height;

  const DualSeriesLineChart({
    super.key,
    required this.greenSeries,
    required this.redSeries,
    this.showGreen = true,
    this.showRed = true,
    this.rightBadgeGreen = '',
    this.rightBadgeRed = '',
    this.height = 155,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _DualLinePainter(
          greenSeries: greenSeries,
          redSeries: redSeries,
          showGreen: showGreen,
          showRed: showRed,
        ),
        child: Stack(
          children: [
            if (rightBadgeGreen.isNotEmpty && showGreen)
              Positioned(
                right: 6,
                top: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00C853).withOpacity(0.22),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF00E676), width: 0.8),
                  ),
                  child: Text(
                    rightBadgeGreen,
                    style: const TextStyle(
                      color: Color(0xFF00E676),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (rightBadgeRed.isNotEmpty && showRed)
              Positioned(
                right: 6,
                top: 40,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD50000).withOpacity(0.22),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFFFF5252), width: 0.8),
                  ),
                  child: Text(
                    rightBadgeRed,
                    style: const TextStyle(
                      color: Color(0xFFFF5252),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            const Positioned(
              bottom: 0,
              left: 28,
              right: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('09:15', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  Text('10:30', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  Text('11:45', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  Text('13:00', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  Text('14:15', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  Text('15:30', style: TextStyle(color: Colors.white38, fontSize: 10)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DualLinePainter extends CustomPainter {
  final List<double> greenSeries;
  final List<double> redSeries;
  final bool showGreen;
  final bool showRed;

  _DualLinePainter({
    required this.greenSeries,
    required this.redSeries,
    required this.showGreen,
    required this.showRed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final chartW = size.width - 34;
    final chartH = size.height - 22;
    const leftPad = 28.0;
    const topPad = 6.0;

    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.07)
      ..strokeWidth = 1;

    for (int i = 0; i <= 3; i++) {
      final y = topPad + (chartH / 3) * i;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width - 4, y), gridPaint);
    }

    final allVals = <double>[];
    if (showGreen) allVals.addAll(greenSeries);
    if (showRed) allVals.addAll(redSeries);
    if (allVals.isEmpty) return;

    double minV = allVals.reduce(math.min);
    double maxV = allVals.reduce(math.max);
    if ((maxV - minV).abs() < 1e-4) {
      maxV += 10;
      minV -= 10;
    }

    void drawLine(List<double> pts, Color color) {
      if (pts.length < 2) return;
      final path = Path();
      for (int i = 0; i < pts.length; i++) {
        final x = leftPad + (i / (pts.length - 1)) * chartW;
        final norm = (pts[i] - minV) / (maxV - minV);
        final y = topPad + chartH - (norm * chartH);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final p = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(path, p);
    }

    if (showRed && redSeries.isNotEmpty) {
      drawLine(redSeries, const Color(0xFFFF5252));
    }
    if (showGreen && greenSeries.isNotEmpty) {
      drawLine(greenSeries, const Color(0xFF00E676));
    }
  }

  @override
  bool shouldRepaint(covariant _DualLinePainter oldDelegate) => true;
}

class OiChangeHistogramChart extends StatelessWidget {
  final List<double> ceDeltas;
  final List<double> peDeltas;
  final double height;

  const OiChangeHistogramChart({
    super.key,
    required this.ceDeltas,
    required this.peDeltas,
    this.height = 135,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _HistogramPainter(ceDeltas: ceDeltas, peDeltas: peDeltas),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final List<double> ceDeltas;
  final List<double> peDeltas;

  _HistogramPainter({required this.ceDeltas, required this.peDeltas});

  @override
  void paint(Canvas canvas, Size size) {
    final leftPad = 24.0;
    final chartW = size.width - leftPad - 6;
    final midY = size.height / 2;

    final zeroPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    canvas.drawLine(Offset(leftPad, midY), Offset(size.width - 6, midY), zeroPaint);

    final count = math.min(ceDeltas.length, peDeltas.length);
    if (count == 0) return;

    double maxAbs = 100.0;
    for (int i = 0; i < count; i++) {
      maxAbs = math.max(maxAbs, ceDeltas[i].abs());
      maxAbs = math.max(maxAbs, peDeltas[i].abs());
    }

    final slotW = chartW / count;
    final barW = (slotW * 0.36).clamp(2.0, 7.0);

    final cePaint = Paint()..color = const Color(0xFF00E676);
    final pePaint = Paint()..color = const Color(0xFFFF5252);

    for (int i = 0; i < count; i++) {
      final xCenter = leftPad + (i + 0.5) * slotW;
      final ceH = (ceDeltas[i] / maxAbs) * (size.height * 0.42);
      final peH = (peDeltas[i] / maxAbs) * (size.height * 0.42);

      canvas.drawRect(
        Rect.fromLTRB(xCenter - barW, midY - ceH, xCenter, midY),
        cePaint,
      );
      canvas.drawRect(
        Rect.fromLTRB(xCenter, midY - peH, xCenter + barW, midY),
        pePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter oldDelegate) => true;
}

class MultiStrikeComparisonChart extends StatelessWidget {
  final List<double> s1;
  final List<double> s2;
  final List<double> s3;
  final List<double> s4;
  final double height;

  const MultiStrikeComparisonChart({
    super.key,
    required this.s1,
    required this.s2,
    required this.s3,
    required this.s4,
    this.height = 145,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _MultiLinePainter([s1, s2, s3, s4], const [
          Color(0xFFFFAB00),
          Color(0xFF00E676),
          Color(0xFF2979FF),
          Color(0xFFFF5252),
        ]),
      ),
    );
  }
}

class _MultiLinePainter extends CustomPainter {
  final List<List<double>> seriesList;
  final List<Color> colors;

  _MultiLinePainter(this.seriesList, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 24.0;
    final chartW = size.width - leftPad - 8;
    final chartH = size.height - 20;

    final grid = Paint()
      ..color = Colors.white.withOpacity(0.07)
      ..strokeWidth = 1;
    for (int i = 0; i <= 3; i++) {
      final y = 6 + (chartH / 3) * i;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width - 6, y), grid);
    }

    final flat = seriesList.expand((e) => e).toList();
    if (flat.isEmpty) return;
    double minV = flat.reduce(math.min);
    double maxV = flat.reduce(math.max);
    if ((maxV - minV).abs() < 1e-3) {
      maxV += 10;
      minV -= 10;
    }

    for (int s = 0; s < seriesList.length; s++) {
      final pts = seriesList[s];
      if (pts.length < 2) continue;
      final path = Path();
      for (int i = 0; i < pts.length; i++) {
        final x = leftPad + (i / (pts.length - 1)) * chartW;
        final norm = (pts[i] - minV) / (maxV - minV);
        final y = 6 + chartH - (norm * chartH);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final p = Paint()
        ..color = colors[s % colors.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant _MultiLinePainter oldDelegate) => true;
}
