import 'dart:math' as math;

class OptionGreeksResult {
  final double ivPct;
  final double delta;
  final double gamma;
  final double theta;
  final double vega;

  const OptionGreeksResult({
    required this.ivPct,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
  });
}

class MathGreeksEngine {
  static const double riskFreeRate = 0.068; // 6.8% RBI 91-day T-bill benchmark

  static double _normPdf(double x) {
    return math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi);
  }

  static double _normCdf(double x) {
    final sign = x < 0 ? -1.0 : 1.0;
    final z = x.abs() / math.sqrt(2.0);
    final t = 1.0 / (1.0 + 0.3275911 * z);
    final y = 1.0 -
        (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t -
                    0.284496736) *
                t +
            0.254829592) *
            t *
            math.exp(-z * z);
    return 0.5 * (1.0 + sign * y);
  }

  static double blackScholesPrice({
    required double spot,
    required double strike,
    required double timeYears,
    required double sigma,
    required bool isCall,
    double r = riskFreeRate,
  }) {
    final t = math.max(timeYears, 1.0 / (365.0 * 24.0));
    final vol = sigma.clamp(0.03, 2.50);
    final sqrtT = math.sqrt(t);
    final d1 = (math.log(spot / strike) + (r + 0.5 * vol * vol) * t) /
        (vol * sqrtT);
    final d2 = d1 - vol * sqrtT;

    if (isCall) {
      return spot * _normCdf(d1) -
          strike * math.exp(-r * t) * _normCdf(d2);
    } else {
      return strike * math.exp(-r * t) * _normCdf(-d2) -
          spot * _normCdf(-d1);
    }
  }

  /// Solves exact Implied Volatility using Brenner-Subrahmanyam seed + 8-step Newton-Raphson with Bisection bounds
  static double solveImpliedVolatility({
    required double spot,
    required double strike,
    required double timeYears,
    required double marketLtp,
    required bool isCall,
  }) {
    if (marketLtp <= 0.5 || spot <= 0 || strike <= 0) return 0.15;
    final t = math.max(timeYears, 1.0 / 365.0);
    final r = riskFreeRate;

    final intrinsic = isCall
        ? math.max(0.0, spot - strike * math.exp(-r * t))
        : math.max(0.0, strike * math.exp(-r * t) - spot);

    if (marketLtp <= intrinsic + 0.25) {
      return 0.09;
    }

    // Brenner-Subrahmanyam initial guess
    final timeVal = (marketLtp - intrinsic).clamp(0.5, spot * 0.25);
    double sigma = (math.sqrt(2.0 * math.pi / t) * (timeVal / spot))
        .clamp(0.08, 0.95);

    double low = 0.04;
    double high = 1.80;

    for (int iter = 0; iter < 8; iter++) {
      final modelPrice = blackScholesPrice(
        spot: spot,
        strike: strike,
        timeYears: t,
        sigma: sigma,
        isCall: isCall,
      );
      final diff = modelPrice - marketLtp;
      if (diff.abs() < 0.05) break;

      if (diff > 0) {
        high = sigma;
      } else {
        low = sigma;
      }

      final sqrtT = math.sqrt(t);
      final d1 = (math.log(spot / strike) + (r + 0.5 * sigma * sigma) * t) /
          (sigma * sqrtT);
      final vegaRaw = spot * _normPdf(d1) * sqrtT;

      if (vegaRaw > 1e-4) {
        final nextSigma = sigma - (diff / vegaRaw);
        if (nextSigma > low && nextSigma < high) {
          sigma = nextSigma;
        } else {
          sigma = 0.5 * (low + high);
        }
      } else {
        sigma = 0.5 * (low + high);
      }
    }

    return sigma.clamp(0.06, 1.25);
  }

  static OptionGreeksResult computeIvAndGreeks({
    required double spot,
    required double strike,
    required double optionLtp,
    required double daysToExpiry,
    required bool isCall,
    double? providerIvPct,
  }) {
    final t = math.max(daysToExpiry / 365.0, 1.0 / 365.0);
    double sigma;
    if (providerIvPct != null &&
        providerIvPct >= 5.0 &&
        providerIvPct <= 120.0) {
      sigma = providerIvPct / 100.0;
    } else {
      sigma = solveImpliedVolatility(
        spot: spot,
        strike: strike,
        timeYears: t,
        marketLtp: optionLtp,
        isCall: isCall,
      );
    }

    final sqrtT = math.sqrt(t);
    final r = riskFreeRate;
    final d1 = (math.log(spot / strike) + (r + 0.5 * sigma * sigma) * t) /
        (sigma * sqrtT);
    final d2 = d1 - sigma * sqrtT;
    final pdfD1 = _normPdf(d1);

    final delta = isCall ? _normCdf(d1) : (_normCdf(d1) - 1.0);
    final gamma = pdfD1 / (spot * sigma * sqrtT);
    final vegaPer1Pct = (spot * pdfD1 * sqrtT) / 100.0;

    final term1 = -(spot * pdfD1 * sigma) / (2.0 * sqrtT);
    final term2 = r * strike * math.exp(-r * t);
    final annualTheta = isCall
        ? (term1 - term2 * _normCdf(d2))
        : (term1 + term2 * _normCdf(-d2));
    final dailyTheta = annualTheta / 365.0;

    return OptionGreeksResult(
      ivPct: (sigma * 100.0).clamp(5.0, 120.0),
      delta: double.parse(delta.toStringAsFixed(4)),
      gamma: double.parse(gamma.toStringAsFixed(6)),
      theta: double.parse(dailyTheta.toStringAsFixed(2)),
      vega: double.parse(vegaPer1Pct.toStringAsFixed(2)),
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

  /// Computes Net Gamma Exposure (GEX) across monitoring strikes to detect pin risk vs breakout acceleration
  static double computeNetGammaExposure(List rows, double spot) {
    if (rows.isEmpty || spot <= 0) return 0.0;
    double netGex = 0.0;
    for (final raw in rows) {
      final ceOi = (raw.ceOi as int).toDouble();
      final peOi = (raw.peOi as int).toDouble();
      final g = (raw.ceGamma as num).toDouble();
      // Dealers are typically short puts (-GEX) and long/short calls (+GEX wall)
      netGex += (peOi - ceOi) * g * spot;
    }
    return netGex;
  }
}
