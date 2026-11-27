import 'dart:math' as math;
import 'package:flutter/material.dart';

class QuantTheme {
  // Daylight Tactical Pro Palette (Glare-free ceramic surfaces + deep navy command bars)
  static const Color bgMain = Color(0xFFF4F6F9);
  static const Color bgSecondary = Color(0xFFECEFF4);
  static const Color bgPanel = Color(0xFFFFFFFF);
  static const Color bgElevated = Color(0xFFF8FAFC);
  static const Color headerNavy = Color(0xFF0F1E36);
  static const Color headerNavySoft = Color(0xFF1A2F52);
  static const Color border = Color(0xFFD8E0EA);
  static const Color accent = Color(0xFF0F1E36);
  static const Color positive = Color(0xFF0D8A55);
  static const Color negative = Color(0xFFD9383A);
  static const Color warning = Color(0xFFD97706);
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF475569);

  static ThemeData buildTheme() {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: bgMain,
      primaryColor: headerNavy,
      canvasColor: bgSecondary,
      dividerColor: border,
      fontFamily: 'sans-serif',
      colorScheme: const ColorScheme.light(
        primary: headerNavy,
        secondary: positive,
        surface: bgPanel,
        error: negative,
        onPrimary: Colors.white,
        onSurface: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: headerNavy,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  static TextStyle mono({
    double size = 12,
    Color color = textPrimary,
    FontWeight weight = FontWeight.w600,
  }) {
    return TextStyle(
      fontFamily: 'monospace',
      fontSize: size,
      color: color,
      fontWeight: weight,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  static TextStyle label({
    double size = 11,
    Color color = textSecondary,
    FontWeight weight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: 0.15,
    );
  }

  static TextStyle heading({
    double size = 13,
    Color color = textPrimary,
    FontWeight weight = FontWeight.w700,
  }) {
    return TextStyle(
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: 0.2,
    );
  }

  static String fmtLakhs(num val) {
    final v = val.toDouble();
    if (v.abs() >= 10000000) {
      return '${(v / 10000000.0).toStringAsFixed(2)}Cr';
    }
    if (v.abs() >= 100000) {
      return '${(v / 100000.0).toStringAsFixed(2)}L';
    }
    if (v.abs() >= 1000) {
      return '${(v / 1000.0).toStringAsFixed(1)}K';
    }
    return v.toStringAsFixed(0);
  }

  static String fmtSignedLakhs(num val) {
    final s = fmtLakhs(val);
    return val >= 0 ? '+$s' : s;
  }

  static String fmtInr(num val, {int decimals = 2}) {
    return '₹${val.toDouble().toStringAsFixed(decimals)}';
  }
}

class QuantPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color backgroundColor;
  final Color borderColor;
  final double radius;
  final VoidCallback? onTap;

  const QuantPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin,
    this.backgroundColor = QuantTheme.bgPanel,
    this.borderColor = QuantTheme.border,
    this.radius = 12.0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: 1.0),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F1E36),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: box);
    }
    return box;
  }
}

class QuantBadge extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool darkSurface;

  const QuantBadge({
    super.key,
    required this.text,
    required this.color,
    this.icon,
    this.darkSurface = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: darkSurface
            ? color.withOpacity(0.24)
            : color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: darkSurface
              ? color.withOpacity(0.75)
              : color.withOpacity(0.45),
          width: 0.9,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: QuantTheme.mono(
              size: 10,
              color: color,
              weight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class QuantMetricCell extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;
  final CrossAxisAlignment alignment;

  const QuantMetricCell({
    super.key,
    required this.label,
    required this.value,
    this.valueColor = QuantTheme.textPrimary,
    this.alignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignment,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: QuantTheme.label(size: 10)),
        const SizedBox(height: 3),
        Text(
          value,
          style: QuantTheme.mono(
            size: 12,
            color: valueColor,
            weight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class RegimeArcGauge extends StatelessWidget {
  final double bullProb; // 0..1
  final double bearProb; // 0..1
  final double chopProb; // 0..1

  const RegimeArcGauge({
    super.key,
    required this.bullProb,
    required this.bearProb,
    required this.chopProb,
  });

  @override
  Widget build(BuildContext context) {
    final isBull = bullProb >= bearProb && bullProb >= chopProb;
    final isBear = bearProb > bullProb && bearProb >= chopProb;
    final domPct =
        ((isBull ? bullProb : (isBear ? bearProb : chopProb)) * 100).round();
    final domLabel = isBull ? 'Bullish' : (isBear ? 'Bearish' : 'Sideways');
    final domColor = isBull
        ? QuantTheme.positive
        : (isBear ? QuantTheme.negative : QuantTheme.warning);

    return SizedBox(
      width: 132,
      height: 82,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          CustomPaint(
            size: const Size(132, 76),
            painter: _ArcGaugePainter(
              bullProb: bullProb,
              bearProb: bearProb,
              chopProb: chopProb,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$domPct%',
                style: QuantTheme.mono(
                  size: 18,
                  color: QuantTheme.textPrimary,
                  weight: FontWeight.w800,
                ),
              ),
              Text(
                domLabel,
                style: QuantTheme.heading(size: 11, color: domColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArcGaugePainter extends CustomPainter {
  final double bullProb;
  final double bearProb;
  final double chopProb;

  _ArcGaugePainter({
    required this.bullProb,
    required this.bearProb,
    required this.chopProb,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect =
        Rect.fromLTWH(10, 10, size.width - 20, (size.height - 10) * 1.8);
    const startAngle = math.pi;
    const totalSweep = math.pi;

    final bgPaint = Paint()
      ..color = QuantTheme.border
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startAngle, totalSweep, false, bgPaint);

    final sum = math.max(0.01, bullProb + bearProb + chopProb);
    final sBear = (bearProb / sum) * totalSweep;
    final sChop = (chopProb / sum) * totalSweep;
    final sBull = (bullProb / sum) * totalSweep;

    final pBear = Paint()
      ..color = QuantTheme.negative
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke;
    final pChop = Paint()
      ..color = QuantTheme.warning
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke;
    final pBull = Paint()
      ..color = QuantTheme.positive
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke;

    canvas.drawArc(rect, startAngle, sBear, false, pBear);
    canvas.drawArc(rect, startAngle + sBear, sChop, false, pChop);
    canvas.drawArc(rect, startAngle + sBear + sChop, sBull, false, pBull);
  }

  @override
  bool shouldRepaint(covariant _ArcGaugePainter oldDelegate) => true;
}
