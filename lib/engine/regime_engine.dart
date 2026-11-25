import 'dart:math' as math;
import '../core/models.dart';

class MeasuredRegimeSnapshot {
  final String indexLabel;
  final bool hasSufficientData;
  final int barCount;
  final String regimeLabel; // 'TRENDING BULL' | 'TRENDING BEAR' | 'VOLATILE CHOP' | 'CALM RANGE' | 'COLLECTING'
  final double bullProb;
  final double bearProb;
  final double chopProb;
  final double? realizedVolPct;
  final double? volPercentile; // 0..100 vs rolling windows
  final double? efficiencyRatio; // 0..1 Kaufman ER
  final double? adxValue; // 0..100 Wilder-style ADX
  final double? vwapDistancePct;
  final double? indiaVix;
  final String summaryNote;

  const MeasuredRegimeSnapshot({
    required this.indexLabel,
    required this.hasSufficientData,
    required this.barCount,
    required this.regimeLabel,
    required this.bullProb,
    required this.bearProb,
    required this.chopProb,
    this.realizedVolPct,
    this.volPercentile,
    this.efficiencyRatio,
    this.adxValue,
    this.vwapDistancePct,
    this.indiaVix,
    required this.summaryNote,
  });

  factory MeasuredRegimeSnapshot.collecting(String indexLabel, int bars) {
    return MeasuredRegimeSnapshot(
      indexLabel: indexLabel,
      hasSufficientData: false,
      barCount: bars,
      regimeLabel: 'COLLECTING ($bars/15m)',
      bullProb: 0.0,
      bearProb: 0.0,
      chopProb: 0.0,
      summaryNote: 'Need at least 15 real 1-min spot bars for measured regime.',
    );
  }
}

/// Pure, stateless, per-index measured market regime engine (zero hardcoded HMM drift)
class RegimeEngine {
  static MeasuredRegimeSnapshot evaluate({
    required String indexLabel,
    required List<OneMinEnrichedBar> spotBars,
    double? liveSpot,
    double? indiaVix,
  }) {
    final clean = spotBars
        .where((b) => b.close > 0 && b.high >= b.low)
        .toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    if (clean.length < 15) {
      return MeasuredRegimeSnapshot.collecting(indexLabel, clean.length);
    }

    final n = clean.length;
    final winLen = math.min(20, n);
    final win = clean.sublist(n - winLen);

    // 1. Kaufman Efficiency Ratio (0 = pure chop, 1 = straight trend)
    final netMove = win.last.close - win.first.close;
    double pathLen = 0.0;
    for (int i = 1; i < win.length; i++) {
      pathLen += (win[i].close - win[i - 1].close).abs();
    }
    final er = pathLen > 1e-9
        ? (netMove.abs() / pathLen).clamp(0.0, 1.0).toDouble()
        : 0.0;

    // 2. Wilder-style ADX & Directional Movement on real H/L/C
    double trSum = 0.0, plusDmSum = 0.0, minusDmSum = 0.0;
    for (int i = 1; i < win.length; i++) {
      final cur = win[i];
      final prev = win[i - 1];
      final upMove = cur.high - prev.high;
      final downMove = prev.low - cur.low;
      if (upMove > downMove && upMove > 0) plusDmSum += upMove;
      if (downMove > upMove && downMove > 0) minusDmSum += downMove;
      final tr = math.max(
        cur.high - cur.low,
        math.max((cur.high - prev.close).abs(), (cur.low - prev.close).abs()),
      );
      trSum += tr;
    }
    final plusDi = trSum > 1e-9 ? (plusDmSum / trSum) * 100.0 : 0.0;
    final minusDi = trSum > 1e-9 ? (minusDmSum / trSum) * 100.0 : 0.0;
    final diSum = plusDi + minusDi;
    final adx = diSum > 1e-9
        ? (((plusDi - minusDi).abs() / diSum) * 100.0).clamp(0.0, 100.0).toDouble()
        : 0.0;

    // 3. Realized 1m Volatility (Annualized %) & Rolling Vol Percentile
    final logRets = <double>[];
    for (int i = 1; i < clean.length; i++) {
      if (clean[i - 1].close > 0 && clean[i].close > 0) {
        logRets.add(math.log(clean[i].close / clean[i - 1].close));
      }
    }
    double stdOf(List<double> vals) {
      if (vals.length < 2) return 0.0;
      final m = vals.reduce((a, b) => a + b) / vals.length;
      double s2 = 0.0;
      for (final v in vals) {
        final d = v - m;
        s2 += d * d;
      }
      return math.sqrt(s2 / (vals.length - 1));
    }

    final recentRets = logRets.length > 14
        ? logRets.sublist(logRets.length - 14)
        : logRets;
    final curVol1m = stdOf(recentRets);
    // 252 trading days * 375 mins/day = 94,500 mins/year
    final rvAnnPct = curVol1m * math.sqrt(94500.0) * 100.0;

    double volPct = 50.0;
    if (logRets.length >= 20) {
      final histVols = <double>[];
      for (int end = 10; end <= logRets.length; end++) {
        histVols.add(stdOf(logRets.sublist(end - 10, end)));
      }
      final below = histVols.where((v) => v <= curVol1m).length;
      volPct = (below / histVols.length) * 100.0;
    }

    // 4. Session VWAP / Typical-Price Mean Distance (%)
    double tpSum = 0.0;
    for (final b in clean) {
      tpSum += (b.high + b.low + b.close) / 3.0;
    }
    final sessionMean = tpSum / clean.length;
    final spotNow = (liveSpot != null && liveSpot > 0) ? liveSpot : clean.last.close;
    final vwapDistPct = sessionMean > 0
        ? ((spotNow - sessionMean) / sessionMean) * 100.0
        : 0.0;

    // 5. Transparent Measured Scores -> Normalized Probabilities
    final trendStrength = ((er * 0.55) + ((adx / 100.0) * 0.45)).clamp(0.0, 1.0).toDouble();
    final dirSign = (netMove > 0 ? 0.5 : -0.5) +
        (vwapDistPct > 0.02 ? 0.3 : (vwapDistPct < -0.02 ? -0.3 : 0.0)) +
        (plusDi > minusDi ? 0.2 : -0.2);

    final rawChop = (1.0 - trendStrength).clamp(0.08, 0.90).toDouble();
    final dirMass = 1.0 - rawChop;
    final bullShare = ((dirSign + 1.0) * 0.5).clamp(0.05, 0.95).toDouble();
    final bullP = dirMass * bullShare;
    final bearP = dirMass * (1.0 - bullShare);

    String label = 'CALM RANGE';
    if (bullP >= 0.48 && bullP > bearP) {
      label = 'TRENDING BULL';
    } else if (bearP >= 0.48 && bearP > bullP) {
      label = 'TRENDING BEAR';
    } else if (volPct >= 75.0 || (indiaVix != null && indiaVix >= 18.0)) {
      label = 'VOLATILE CHOP';
    }

    return MeasuredRegimeSnapshot(
      indexLabel: indexLabel,
      hasSufficientData: true,
      barCount: clean.length,
      regimeLabel: label,
      bullProb: bullP,
      bearProb: bearP,
      chopProb: rawChop,
      realizedVolPct: rvAnnPct,
      volPercentile: volPct,
      efficiencyRatio: er,
      adxValue: adx,
      vwapDistancePct: vwapDistPct,
      indiaVix: indiaVix,
      summaryNote:
          'ER ${(er * 100).toStringAsFixed(0)}% • ADX ${adx.toStringAsFixed(0)} • RV ${rvAnnPct.toStringAsFixed(1)}% (P${volPct.toStringAsFixed(0)}) • VWAP ${vwapDistPct >= 0 ? "+" : ""}${vwapDistPct.toStringAsFixed(2)}%',
    );
  }
}
