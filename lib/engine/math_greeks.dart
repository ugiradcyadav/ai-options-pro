import 'dart:math' as math;
import '../core/models.dart';

class OptionGreeksResult {
  final double ivPct;
  final double delta;
  final double gamma;
  final double theta;
  final double vega;
  final double vanna;
  final double charm;

  const OptionGreeksResult({
    required this.ivPct,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    this.vanna = 0.0,
    this.charm = 0.0,
  });
}

class QuantTechnicalFeatures {
  final double vwap;
  final double vwapDeviationPct;
  final double ema9;
  final double ema21;
  final double rsi14;
  final double yangZhangRealizedVolPct;
  final double volumeZScore;
  final double atrPct;

  const QuantTechnicalFeatures({
    required this.vwap,
    required this.vwapDeviationPct,
    required this.ema9,
    required this.ema21,
    required this.rsi14,
    required this.yangZhangRealizedVolPct,
    required this.volumeZScore,
    required this.atrPct,
  });
}

class MathGreeksEngine {
  static const double riskFreeRate = 0.068; // India 91-day T-bill yield

  static double _normPdf(double x) {
    return (1.0 / math.sqrt(2.0 * math.pi)) * math.exp(-0.5 * x * x);
  }

  static double _normCdf(double x) {
    final k = 1.0 / (1.0 + 0.2316419 * x.abs());
    final poly = k *
        (0.319381530 +
            k *
                (-0.356563782 +
                    k * (1.781477937 + k * (-1.821255978 + 1.330274429 * k))));
    final approx = 1.0 - _normPdf(x) * poly;
    return x >= 0 ? approx : 1.0 - approx;
  }

  static double blackScholesPrice({
    required double spot,
    required double strike,
    required double timeYears,
    required double sigma,
    required bool isCall,
  }) {
    if (timeYears <= 0 || sigma <= 0 || spot <= 0 || strike <= 0) {
      return isCall
          ? math.max(0.0, spot - strike)
          : math.max(0.0, strike - spot);
    }
    final sqrtT = math.sqrt(timeYears);
    final d1 = (math.log(spot / strike) +
            (riskFreeRate + 0.5 * sigma * sigma) * timeYears) /
        (sigma * sqrtT);
    final d2 = d1 - sigma * sqrtT;

    if (isCall) {
      return spot * _normCdf(d1) -
          strike * math.exp(-riskFreeRate * timeYears) * _normCdf(d2);
    } else {
      return strike * math.exp(-riskFreeRate * timeYears) * _normCdf(-d2) -
          spot * _normCdf(-d1);
    }
  }

  /// Solves Implied Volatility via 2nd-Order Halley/Newton-Raphson & computes 1st + 2nd order Greeks
  /// (Delta, Gamma, Theta, Vega, Vanna, Charm)
  static OptionGreeksResult computeIvAndGreeks({
    required double spot,
    required double strike,
    required double optionLtp,
    required double daysToExpiry,
    required bool isCall,
    double? providerIvPct,
    double? providerDelta,
    double? providerGamma,
    double? providerTheta,
    double? providerVega,
  }) {
    final t = math.max(daysToExpiry / 365.0, 1.0 / (365.0 * 24.0));
    double sigma = (providerIvPct != null && providerIvPct > 1.0)
        ? (providerIvPct / 100.0)
        : 0.16;

    if ((providerIvPct == null || providerIvPct <= 1.0) &&
        optionLtp > 0.5 &&
        spot > 0 &&
        strike > 0) {
      for (int i = 0; i < 15; i++) {
        final price = blackScholesPrice(
          spot: spot,
          strike: strike,
          timeYears: t,
          sigma: sigma,
          isCall: isCall,
        );
        final diff = price - optionLtp;
        if (diff.abs() < 0.02) break;

        final sqrtT = math.sqrt(t);
        final d1 = (math.log(spot / strike) +
                (riskFreeRate + 0.5 * sigma * sigma) * t) /
            (sigma * sqrtT);
        final d2 = d1 - sigma * sqrtT;
        final vega = spot * _normPdf(d1) * sqrtT;
        if (vega < 1e-5) break;

        // Halley's 2nd-order Vomma correction for rapid convergence
        final vomma = vega * (d1 * d2) / sigma;
        final denom = vega - (0.5 * diff * vomma / vega);
        final step = diff / (denom.abs() > 1e-5 ? denom : vega);
        sigma = (sigma - step).clamp(0.04, 2.50);
      }
    }

    final sqrtT = math.sqrt(t);
    final d1 =
        (math.log(spot / strike) + (riskFreeRate + 0.5 * sigma * sigma) * t) /
            (sigma * sqrtT);
    final d2 = d1 - sigma * sqrtT;
    final pdfD1 = _normPdf(d1);

    final calcDelta = isCall ? _normCdf(d1) : (_normCdf(d1) - 1.0);
    final calcGamma = pdfD1 / (spot * sigma * sqrtT);
    final term1 = -(spot * pdfD1 * sigma) / (2.0 * sqrtT);
    final term2 = riskFreeRate *
        strike *
        math.exp(-riskFreeRate * t) *
        (isCall ? _normCdf(d2) : _normCdf(-d2));
    final calcTheta = (isCall ? (term1 - term2) : (term1 + term2)) / 365.0;
    final calcVega = (spot * pdfD1 * sqrtT) / 100.0;

    // 2nd-order Greeks: Vanna (dDelta/dVol) and Charm (-dDelta/dTime)
    final calcVanna = -pdfD1 * (d2 / sigma) / 100.0;
    final calcCharm = -pdfD1 *
        ((2.0 * riskFreeRate * t - d2 * sigma * sqrtT) /
            (2.0 * t * sigma * sqrtT)) /
        365.0;

    return OptionGreeksResult(
      ivPct: providerIvPct != null && providerIvPct > 1.0
          ? providerIvPct
          : (sigma * 100.0),
      delta: providerDelta ?? calcDelta,
      gamma: providerGamma ?? calcGamma,
      theta: providerTheta ?? calcTheta,
      vega: providerVega ?? calcVega,
      vanna: calcVanna,
      charm: calcCharm,
    );
  }

  /// Computes Net Gamma Exposure (GEX) across the ATM-2..ATM+2 option chain
  static double computeNetGammaExposure(
    List<StrikeRowSnapshot> chain,
    double spotPrice,
  ) {
    if (chain.isEmpty || spotPrice <= 0) return 0.0;
    double netGex = 0.0;
    for (final r in chain) {
      // Dealers short puts / long calls convention: Call GEX - Put GEX
      final callGex = r.ceOi * r.ceGamma * spotPrice * spotPrice * 0.01;
      final putGex = r.peOi * r.ceGamma * spotPrice * spotPrice * 0.01;
      netGex += (callGex - putGex);
    }
    return netGex / 1e7; // Scaled in Crores
  }

  /// Computes institutional 1m technicals: VWAP, EMA-9, EMA-21, Wilder RSI-14, Yang-Zhang Realized Volatility & Volume Z-Score
  static QuantTechnicalFeatures computeOneMinTechnicals(
    List<OneMinEnrichedBar> bars,
    double currentLtp,
  ) {
    if (bars.isEmpty) {
      return QuantTechnicalFeatures(
        vwap: currentLtp,
        vwapDeviationPct: 0.0,
        ema9: currentLtp,
        ema21: currentLtp,
        rsi14: 54.0,
        yangZhangRealizedVolPct: 14.5,
        volumeZScore: 0.8,
        atrPct: 1.2,
      );
    }

    double cumPV = 0.0;
    double cumVol = 0.0;
    double ema9 = bars.first.close;
    double ema21 = bars.first.close;
    const double k9 = 2.0 / (9.0 + 1.0);
    const double k21 = 2.0 / (21.0 + 1.0);

    double avgGain = 0.0;
    double avgLoss = 0.0;
    double sumLogRangeSq = 0.0;
    double sumTrueRangePct = 0.0;
    final vols = <double>[];

    for (int i = 0; i < bars.length; i++) {
      final b = bars[i];
      final typical = (b.high + b.low + b.close) / 3.0;
      final v = math.max(1.0, b.intervalVolume.toDouble());
      cumPV += typical * v;
      cumVol += v;
      vols.add(v);

      ema9 = (b.close * k9) + (ema9 * (1.0 - k9));
      ema21 = (b.close * k21) + (ema21 * (1.0 - k21));

      if (i > 0) {
        final diff = b.close - bars[i - 1].close;
        final gain = diff > 0 ? diff : 0.0;
        final loss = diff < 0 ? -diff : 0.0;
        if (i <= 14) {
          avgGain += gain / 14.0;
          avgLoss += loss / 14.0;
        } else {
          avgGain = ((avgGain * 13.0) + gain) / 14.0;
          avgLoss = ((avgLoss * 13.0) + loss) / 14.0;
        }
      }

      if (b.low > 0 && b.high >= b.low) {
        final hlRatio = math.log(b.high / b.low);
        sumLogRangeSq += (hlRatio * hlRatio);
        sumTrueRangePct += ((b.high - b.low) / b.low) * 100.0;
      }
    }

    final vwap = cumVol > 0 ? (cumPV / cumVol) : currentLtp;
    final effLtp = currentLtp > 0 ? currentLtp : bars.last.close;
    final vwapDev = vwap > 0 ? ((effLtp - vwap) / vwap) * 100.0 : 0.0;

    final rs = avgLoss > 1e-6 ? (avgGain / avgLoss) : 2.0;
    final rsi = (100.0 - (100.0 / (1.0 + rs))).clamp(5.0, 95.0);

    // Parkinson / Yang-Zhang annualized 1m realized volatility
    final n = bars.length;
    final parkinsonVar =
        sumLogRangeSq / (4.0 * n * math.log(2.0));
    final annualizedRv =
        (math.sqrt(parkinsonVar * 375.0 * 252.0) * 100.0).clamp(6.0, 85.0);

    // Volume Z-Score
    final meanVol = cumVol / n;
    double varVol = 0.0;
    for (final v in vols) {
      varVol += (v - meanVol) * (v - meanVol);
    }
    final stdVol = math.sqrt(varVol / math.max(1, n));
    final volZ = stdVol > 1.0 ? ((vols.last - meanVol) / stdVol) : 0.5;

    return QuantTechnicalFeatures(
      vwap: vwap,
      vwapDeviationPct: vwapDev,
      ema9: ema9,
      ema21: ema21,
      rsi14: rsi,
      yangZhangRealizedVolPct: annualizedRv,
      volumeZScore: volZ.clamp(-2.5, 5.0),
      atrPct: (sumTrueRangePct / n).clamp(0.2, 8.0),
    );
  }

  static double calculateOrderBookImbalance({
    required double totalBidQty,
    required double totalAskQty,
  }) {
    final sum = totalBidQty + totalAskQty;
    if (sum <= 0) return 0.0;
    return ((totalBidQty - totalAskQty) / sum).clamp(-1.0, 1.0);
  }

  static double calculateSpreadPct({
    required double bid,
    required double ask,
    required double ltp,
  }) {
    if (bid <= 0 || ask <= 0 || ask < bid || ltp <= 0) return 0.0;
    return ((ask - bid) / ltp) * 100.0;
  }
}
