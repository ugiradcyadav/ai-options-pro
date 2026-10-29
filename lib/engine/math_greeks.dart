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
  static const double riskFreeRate = 0.068; // 6.8% India 91-day T-Bill reference

  /// Standard Normal PDF
  static double _normPdf(double x) {
    return (1.0 / math.sqrt(2.0 * math.pi)) * math.exp(-0.5 * x * x);
  }

  /// Standard Normal CDF (Abramowitz & Stegun approximation, max error < 7.5e-8)
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

  /// Calculates Black-Scholes option price for given volatility sigma (decimal)
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

  /// Solves Implied Volatility and analytical Greeks when provider feed omits them
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
    double sigma = (providerIvPct != null && providerIvPct > 0)
        ? (providerIvPct / 100.0)
        : 0.18;

    // Newton-Raphson IV refinement if provider IV is absent
    if (providerIvPct == null || providerIvPct <= 0) {
      for (int i = 0; i < 12; i++) {
        final price = blackScholesPrice(
          spot: spot,
          strike: strike,
          timeYears: t,
          sigma: sigma,
          isCall: isCall,
        );
        final diff = price - optionLtp;
        if (diff.abs() < 0.05) break;

        final sqrtT = math.sqrt(t);
        final d1 = (math.log(spot / strike) +
                (riskFreeRate + 0.5 * sigma * sigma) * t) /
            (sigma * sqrtT);
        final vegaRaw = spot * _normPdf(d1) * sqrtT;
        if (vegaRaw < 1e-5) break;
        sigma = (sigma - diff / vegaRaw).clamp(0.04, 2.50);
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

    return OptionGreeksResult(
      ivPct: providerIvPct != null && providerIvPct > 0
          ? providerIvPct
          : (sigma * 100.0),
      delta: providerDelta ?? calcDelta,
      gamma: providerGamma ?? calcGamma,
      theta: providerTheta ?? calcTheta,
      vega: providerVega ?? calcVega,
    );
  }

  /// Calculates Order Book Imbalance Ratio in range [-1.0, +1.0]
  static double calculateOrderBookImbalance({
    required double totalBidQty,
    required double totalAskQty,
  }) {
    final sum = totalBidQty + totalAskQty;
    if (sum <= 0) return 0.0;
    return ((totalBidQty - totalAskQty) / sum).clamp(-1.0, 1.0);
  }

  /// Bid-Ask Spread percentage
  static double calculateSpreadPct({
    required double bid,
    required double ask,
    required double ltp,
  }) {
    if (bid <= 0 || ask <= 0 || ask < bid || ltp <= 0) return 0.0;
    return ((ask - bid) / ltp) * 100.0;
  }
}
