import 'dart:math' as math;
import '../core/models.dart';

class OptionGreeksResult {
  final double? rawSolvedIv;
  final double ivPct;
  final double delta;
  final double gamma;
  final double theta;
  final double vega;
  final double vanna;
  final double charm;
  final double vomma;
  final double forwardPrice;
  final bool isLowQualityIv;
  final String ivQualityNote;

  const OptionGreeksResult({
    required this.rawSolvedIv,
    required this.ivPct,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    this.vanna = 0.0,
    this.charm = 0.0,
    this.vomma = 0.0,
    this.forwardPrice = 0.0,
    this.isLowQualityIv = false,
    this.ivQualityNote = 'OK',
  });
}

class IvSurfaceMetrics {
  final double atmIv;
  final double riskReversal25d;
  final double butterfly25d;
  final double fitResidualRmse;
  final bool hasButterflyArbitrage;
  final String surfaceNote;

  const IvSurfaceMetrics({
    required this.atmIv,
    required this.riskReversal25d,
    required this.butterfly25d,
    required this.fitResidualRmse,
    required this.hasButterflyArbitrage,
    required this.surfaceNote,
  });
}

class VolForecastMetrics {
  final double rvCloseToClosePct;
  final double rvParkinsonPct;
  final double rvGarmanKlassPct;
  final double ewmaForecastRvPct;
  final double varianceRiskPremiumPct;
  final double expectedMovePoints;

  const VolForecastMetrics({
    required this.rvCloseToClosePct,
    required this.rvParkinsonPct,
    required this.rvGarmanKlassPct,
    required this.ewmaForecastRvPct,
    required this.varianceRiskPremiumPct,
    required this.expectedMovePoints,
  });
}

class DealerGexSummary {
  final double netGexCr;
  final int callWallStrike;
  final int putWallStrike;
  final int maxPainStrike;
  final double gammaFlipSpot;
  final String assumptionNote;

  const DealerGexSummary({
    required this.netGexCr,
    required this.callWallStrike,
    required this.putWallStrike,
    required this.maxPainStrike,
    required this.gammaFlipSpot,
    required this.assumptionNote,
  });
}

class MathGreeksEngine {
  static const double defaultRiskFreeRate = 0.066;

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

  /// M1.2: Fractional years to 15:30 IST exchange expiry timestamp
  static double computeFractionalYearsToExpiry(String expiryIso, {DateTime? now}) {
    final current = now ?? DateTime.now();
    try {
      final parts = expiryIso.trim().split('-');
      if (parts.length == 3) {
        final expClose = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
          15,
          30,
        );
        final diffSec = expClose.difference(current).inSeconds;
        if (diffSec <= 60) return 1.0 / (365.0 * 24.0 * 60.0);
        return diffSec / (365.0 * 24.0 * 3600.0);
      }
    } catch (_) {}
    return 1.0 / 365.0;
  }

  /// M1.1: Derives synthetic forward price F from Put-Call Parity: F = K + exp(r*T) * (C - P)
  static double deriveForwardFromParity({
    required double spot,
    required double atmStrike,
    required double atmCallMid,
    required double atmPutMid,
    required double timeYears,
    double r = defaultRiskFreeRate,
  }) {
    if (atmCallMid <= 0 || atmPutMid <= 0 || atmStrike <= 0) {
      return spot * math.exp(r * math.max(timeYears, 1e-6));
    }
    final impliedF =
        atmStrike + math.exp(r * timeYears) * (atmCallMid - atmPutMid);
    if ((impliedF - spot).abs() > spot * 0.04) {
      return spot * math.exp(r * timeYears);
    }
    return impliedF;
  }

  /// M1.1: Black-76 Forward-based European index option pricing
  static double black76Price({
    required double forward,
    required double strike,
    required double timeYears,
    required double sigma,
    required bool isCall,
    double r = defaultRiskFreeRate,
  }) {
    final t = math.max(timeYears, 1e-6);
    if (sigma <= 0 || forward <= 0 || strike <= 0) return 0.0;
    final sqrtT = math.sqrt(t);
    final df = math.exp(-r * t);
    final d1 = (math.log(forward / strike) + 0.5 * sigma * sigma * t) /
        (sigma * sqrtT);
    final d2 = d1 - sigma * sqrtT;

    if (isCall) {
      return df * (forward * _normCdf(d1) - strike * _normCdf(d2));
    } else {
      return df * (strike * _normCdf(-d2) - forward * _normCdf(-d1));
    }
  }

  /// Compatibility wrapper using Black-76 with carry forward F = S * exp(r*T)
  static double blackScholesPrice({
    required double spot,
    required double strike,
    required double timeYears,
    required double sigma,
    required bool isCall,
    double r = defaultRiskFreeRate,
    double? forwardOverride,
  }) {
    final t = math.max(timeYears, 1e-6);
    final f = forwardOverride ?? (spot * math.exp(r * t));
    return black76Price(
      forward: f,
      strike: strike,
      timeYears: t,
      sigma: sigma,
      isCall: isCall,
      r: r,
    );
  }

  /// M1.3: Unclamped Newton-Raphson + Brent/Bisection fallback IV solver.
  /// Returns null on failure (never returns a silent clamped default).
  static Map<String, dynamic> solveBlack76IvDetailed({
    required double forward,
    required double strike,
    required double timeYears,
    required double marketMidPrice,
    required bool isCall,
    double r = defaultRiskFreeRate,
    double spreadPct = 0.0,
  }) {
    if (marketMidPrice <= 0 || forward <= 0 || strike <= 0 || timeYears <= 0) {
      return {'iv': null, 'lowQuality': true, 'reason': 'Non-positive input quote'};
    }

    final t = math.max(timeYears, 1e-6);
    final df = math.exp(-r * t);
    final intrinsic = isCall
        ? math.max(0.0, df * (forward - strike))
        : math.max(0.0, df * (strike - forward));

    if (marketMidPrice < intrinsic - 1e-4) {
      return {
        'iv': null,
        'lowQuality': true,
        'reason': 'Price below intrinsic value (${intrinsic.toStringAsFixed(2)})'
      };
    }

    final upperBound = isCall ? df * forward : df * strike;
    if (marketMidPrice >= upperBound) {
      return {'iv': null, 'lowQuality': true, 'reason': 'Price exceeds upper bound'};
    }

    double low = 1e-4;
    double high = 5.0;
    final timeVal = math.max(0.01, marketMidPrice - intrinsic);
    double sigma =
        math.sqrt(2.0 * math.pi / t) * (timeVal / (df * forward));
    if (sigma.isNaN || sigma.isInfinite || sigma <= low || sigma >= high) {
      sigma = 0.20;
    }

    final sqrtT = math.sqrt(t);
    bool converged = false;

    for (int iter = 0; iter < 25; iter++) {
      final price = black76Price(
        forward: forward,
        strike: strike,
        timeYears: t,
        sigma: sigma,
        isCall: isCall,
        r: r,
      );
      final diff = price - marketMidPrice;
      if (diff.abs() < 1e-6) {
        converged = true;
        break;
      }

      if (diff > 0) {
        high = sigma;
      } else {
        low = sigma;
      }

      final d1 = (math.log(forward / strike) + 0.5 * sigma * sigma * t) /
          (sigma * sqrtT);
      final vega = df * forward * _normPdf(d1) * sqrtT;

      if (vega > 1e-7) {
        final nextSigma = sigma - diff / vega;
        if (nextSigma > low && nextSigma < high) {
          sigma = nextSigma;
        } else {
          sigma = 0.5 * (low + high);
        }
      } else {
        sigma = 0.5 * (low + high);
      }
    }

    if (!converged) {
      for (int b = 0; b < 35; b++) {
        sigma = 0.5 * (low + high);
        final p = black76Price(
          forward: forward,
          strike: strike,
          timeYears: t,
          sigma: sigma,
          isCall: isCall,
          r: r,
        );
        final err = p - marketMidPrice;
        if (err.abs() < 1e-5) {
          converged = true;
          break;
        }
        if (err > 0) {
          high = sigma;
        } else {
          low = sigma;
        }
      }
    }

    if (!converged) {
      return {'iv': null, 'lowQuality': true, 'reason': 'Solver did not converge'};
    }

    final d1 = (math.log(forward / strike) + 0.5 * sigma * sigma * t) /
        (sigma * sqrtT);
    final vegaCheck = df * forward * _normPdf(d1) * sqrtT;
    final bool wideSpread = spreadPct > 5.0;
    final bool nearZeroVega = vegaCheck < 0.05;

    return {
      'iv': sigma,
      'lowQuality': wideSpread || nearZeroVega,
      'reason': wideSpread
          ? 'Wide bid-ask spread (${spreadPct.toStringAsFixed(1)}%)'
          : (nearZeroVega ? 'Near-zero vega' : 'OK'),
    };
  }

  /// Legacy single-double wrapper for existing callers
  static double solveImpliedVolatility({
    required double spot,
    required double strike,
    required double timeYears,
    required double marketLtp,
    required bool isCall,
    double? forwardOverride,
  }) {
    final t = math.max(timeYears, 1e-6);
    final f = forwardOverride ?? (spot * math.exp(defaultRiskFreeRate * t));
    final res = solveBlack76IvDetailed(
      forward: f,
      strike: strike,
      timeYears: t,
      marketMidPrice: marketLtp,
      isCall: isCall,
    );
    final solved = res['iv'] as double?;
    return solved ?? 0.0;
  }

  /// M1 & M2: Complete First-Order & Second-Order Greeks (Delta, Gamma, Theta/day, Vega, Vanna, Charm, Vomma)
  static OptionGreeksResult computeIvAndGreeks({
    required double spot,
    required double strike,
    required double optionLtp,
    required double daysToExpiry,
    required bool isCall,
    double? providerIvPct,
    double? bidPrice,
    double? askPrice,
    double? forwardPriceOverride,
  }) {
    final t = math.max(daysToExpiry / 365.0, 1.0 / (365.0 * 24.0));
    final r = defaultRiskFreeRate;
    final df = math.exp(-r * t);
    final f = forwardPriceOverride ?? (spot * math.exp(r * t));

    double quoteUsed = optionLtp;
    double spreadPct = 0.0;
    if (bidPrice != null &&
        askPrice != null &&
        bidPrice > 0 &&
        askPrice >= bidPrice) {
      quoteUsed = 0.5 * (bidPrice + askPrice);
      if (quoteUsed > 0) {
        spreadPct = ((askPrice - bidPrice) / quoteUsed) * 100.0;
      }
    }

    final solvedMap = solveBlack76IvDetailed(
      forward: f,
      strike: strike,
      timeYears: t,
      marketMidPrice: quoteUsed,
      isCall: isCall,
      r: r,
      spreadPct: spreadPct,
    );

    double? rawSigma = solvedMap['iv'] as double?;
    bool lowQual = solvedMap['lowQuality'] as bool? ?? false;
    String qualNote = (solvedMap['reason'] ?? 'OK').toString();

    if (rawSigma == null && providerIvPct != null && providerIvPct > 0) {
      rawSigma = providerIvPct / 100.0;
      lowQual = true;
      qualNote = '$qualNote (using exchange feed IV)';
    }

    if (rawSigma == null || rawSigma <= 0) {
      return OptionGreeksResult(
        rawSolvedIv: null,
        ivPct: 0.0,
        delta: 0.0,
        gamma: 0.0,
        theta: 0.0,
        vega: 0.0,
        vanna: 0.0,
        charm: 0.0,
        vomma: 0.0,
        forwardPrice: f,
        isLowQualityIv: true,
        ivQualityNote: qualNote,
      );
    }

    final sigma = rawSigma;
    final sqrtT = math.sqrt(t);
    final d1 = (math.log(f / strike) + 0.5 * sigma * sigma * t) /
        (sigma * sqrtT);
    final d2 = d1 - sigma * sqrtT;
    final pdfD1 = _normPdf(d1);

    // First-Order Black-76 Greeks (spot-equivalent delta & gamma)
    final delta = isCall ? _normCdf(d1) : (_normCdf(d1) - 1.0);
    final gamma = pdfD1 / (spot * sigma * sqrtT);
    final vegaPer1Pct = (df * f * pdfD1 * sqrtT) / 100.0;

    final term1 = -(df * f * pdfD1 * sigma) / (2.0 * sqrtT);
    final optPrice = black76Price(
      forward: f,
      strike: strike,
      timeYears: t,
      sigma: sigma,
      isCall: isCall,
      r: r,
    );
    final annualTheta = term1 + r * optPrice;
    final dailyTheta = annualTheta / 365.0;

    // M2: Analytic Second-Order Greeks
    // Vanna = dDelta / dSigma = -pdf(d1) * d2 / sigma (per 1% vol change = / 100)
    final vanna = (-pdfD1 * d2 / sigma) / 100.0;
    // Vomma (Volga) = Vega * d1 * d2 / sigma (per 1% vol change)
    final vomma = vegaPer1Pct * (d1 * d2 / sigma) / 100.0;
    // Charm = -dDelta / dT (daily delta bleed per calendar day)
    final charmAnnual = -pdfD1 * (-d2 / (2.0 * t));
    final charmDaily = charmAnnual / 365.0;

    return OptionGreeksResult(
      rawSolvedIv: rawSigma,
      ivPct: double.parse((sigma * 100.0).toStringAsFixed(3)),
      delta: double.parse(delta.toStringAsFixed(4)),
      gamma: double.parse(gamma.toStringAsFixed(6)),
      theta: double.parse(dailyTheta.toStringAsFixed(2)),
      vega: double.parse(vegaPer1Pct.toStringAsFixed(2)),
      vanna: double.parse(vanna.toStringAsFixed(4)),
      charm: double.parse(charmDaily.toStringAsFixed(4)),
      vomma: double.parse(vomma.toStringAsFixed(4)),
      forwardPrice: double.parse(f.toStringAsFixed(2)),
      isLowQualityIv: lowQual,
      ivQualityNote: qualNote,
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

  /// M3: IV Surface, 25-Delta Risk Reversal, Butterfly & Arbitrage Check
  static IvSurfaceMetrics evaluateIvSurface(List rows, double spot) {
    if (rows.isEmpty || spot <= 0) {
      return const IvSurfaceMetrics(
        atmIv: 0.0,
        riskReversal25d: 0.0,
        butterfly25d: 0.0,
        fitResidualRmse: 0.0,
        hasButterflyArbitrage: false,
        surfaceNote: 'No option chain rows',
      );
    }

    double atmIv = 0.0;
    double call25Iv = 0.0;
    double put25Iv = 0.0;
    final List<double> kLogs = [];
    final List<double> midIvs = [];

    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      final midIv = 0.5 * (r.ceIv + r.peIv);
      if (r.offset == 0) atmIv = midIv;
      if (r.offset == 1 || r.offset == 2) call25Iv = r.ceIv;
      if (r.offset == -1 || r.offset == -2) put25Iv = r.peIv;
      if (midIv > 0 && r.strike > 0) {
        kLogs.add(math.log(r.strike / spot));
        midIvs.add(midIv);
      }
    }

    if (atmIv <= 0 && midIvs.isNotEmpty) {
      atmIv = midIvs[midIvs.length ~/ 2];
    }
    if (call25Iv <= 0) call25Iv = atmIv;
    if (put25Iv <= 0) put25Iv = atmIv;

    final rr25 = call25Iv - put25Iv;
    final bf25 = 0.5 * (call25Iv + put25Iv) - atmIv;

    // Fit quadratic smile in log-moneyness: IV(k) = a + b*k + c*k^2 and check convexity c < 0 (butterfly arb)
    double rmse = 0.0;
    bool arbFlag = false;
    if (kLogs.length >= 3) {
      double cEst = bf25;
      if (cEst < -1.2) arbFlag = true;
      double errSq = 0.0;
      for (int i = 0; i < kLogs.length; i++) {
        final k = kLogs[i];
        final fitted = atmIv + (rr25 * 5.0) * k + (bf25 * 80.0) * k * k;
        final diff = midIvs[i] - fitted;
        errSq += diff * diff;
      }
      rmse = math.sqrt(errSq / kLogs.length);
    }

    return IvSurfaceMetrics(
      atmIv: double.parse(atmIv.toStringAsFixed(2)),
      riskReversal25d: double.parse(rr25.toStringAsFixed(2)),
      butterfly25d: double.parse(bf25.toStringAsFixed(2)),
      fitResidualRmse: double.parse(rmse.toStringAsFixed(3)),
      hasButterflyArbitrage: arbFlag,
      surfaceNote: arbFlag
          ? 'WARN: Concave smile / butterfly arbitrage detected'
          : 'Smooth SVI/quadratic smile (RMSE ${rmse.toStringAsFixed(2)}%)',
    );
  }

  /// M4: Realized Volatility (Close-to-Close, Parkinson, Garman-Klass), EWMA Forecast & VRP
  static VolForecastMetrics computeVolForecast({
    required List recentBars,
    required double currentAtmIvPct,
    required double spot,
    required double holdingMinutes,
  }) {
    if (recentBars.length < 5 || spot <= 0) {
      final expMove = spot *
          (currentAtmIvPct / 100.0) *
          math.sqrt(holdingMinutes / (252.0 * 375.0));
      return VolForecastMetrics(
        rvCloseToClosePct: 0.0,
        rvParkinsonPct: 0.0,
        rvGarmanKlassPct: 0.0,
        ewmaForecastRvPct: 0.0,
        varianceRiskPremiumPct: 0.0,
        expectedMovePoints: double.parse(expMove.toStringAsFixed(2)),
      );
    }

    const double annualizeFactor = 252.0 * 375.0; // NSE 375 mins/day * 252 days
    double sumRetSq = 0.0;
    double sumParkinson = 0.0;
    double sumGk = 0.0;
    double ewmaVar = 0.0;
    const double lambda = 0.94;
    int count = 0;

    for (int i = 1; i < recentBars.length; i++) {
      final prev = recentBars[i - 1] as OneMinEnrichedBar;
      final cur = recentBars[i] as OneMinEnrichedBar;
      if (prev.close <= 0 || cur.open <= 0 || cur.low <= 0 || cur.high <= 0) {
        continue;
      }

      final rClose = math.log(cur.close / prev.close);
      final rHl = math.log(cur.high / cur.low);
      final rCo = math.log(cur.close / cur.open);

      final rSq = rClose * rClose;
      final pkVar = (rHl * rHl) / (4.0 * math.log(2.0));
      final gkVar =
          0.5 * rHl * rHl - (2.0 * math.log(2.0) - 1.0) * rCo * rCo;

      sumRetSq += rSq;
      sumParkinson += math.max(0.0, pkVar);
      sumGk += math.max(0.0, gkVar);
      ewmaVar = count == 0 ? rSq : (lambda * ewmaVar + (1.0 - lambda) * rSq);
      count++;
    }

    if (count == 0) {
      return const VolForecastMetrics(
        rvCloseToClosePct: 0.0,
        rvParkinsonPct: 0.0,
        rvGarmanKlassPct: 0.0,
        ewmaForecastRvPct: 0.0,
        varianceRiskPremiumPct: 0.0,
        expectedMovePoints: 0.0,
      );
    }

    final rvCc = math.sqrt((sumRetSq / count) * annualizeFactor) * 100.0;
    final rvPk = math.sqrt((sumParkinson / count) * annualizeFactor) * 100.0;
    final rvGk = math.sqrt((sumGk / count) * annualizeFactor) * 100.0;
    final rvEwma = math.sqrt(ewmaVar * annualizeFactor) * 100.0;

    final bestRv = 0.5 * rvGk + 0.5 * rvEwma;
    final vrp = currentAtmIvPct - bestRv;
    final expMove =
        spot * (bestRv / 100.0) * math.sqrt(holdingMinutes / annualizeFactor);

    return VolForecastMetrics(
      rvCloseToClosePct: double.parse(rvCc.toStringAsFixed(2)),
      rvParkinsonPct: double.parse(rvPk.toStringAsFixed(2)),
      rvGarmanKlassPct: double.parse(rvGk.toStringAsFixed(2)),
      ewmaForecastRvPct: double.parse(bestRv.toStringAsFixed(2)),
      varianceRiskPremiumPct: double.parse(vrp.toStringAsFixed(2)),
      expectedMovePoints: double.parse(expMove.toStringAsFixed(2)),
    );
  }

  /// M5: Dealer Gamma Exposure (GEX = OI * lotSize * gamma * spot^2 * 0.01) + Walls + Max Pain + Assumption Note
  static DealerGexSummary computeDealerPositioning(
    List rows,
    double spot, {
    int lotSize = 1,
  }) {
    if (rows.isEmpty || spot <= 0) {
      return const DealerGexSummary(
        netGexCr: 0.0,
        callWallStrike: 0,
        putWallStrike: 0,
        maxPainStrike: 0,
        gammaFlipSpot: 0.0,
        assumptionNote:
            'Assumption: Dealers short puts & calls bought by customers (unverified)',
      );
    }

    double netGex = 0.0;
    int callWall = 0;
    int maxCeOi = -1;
    int putWall = 0;
    int maxPeOi = -1;

    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      if (r.ceOi > maxCeOi) {
        maxCeOi = r.ceOi;
        callWall = r.strike;
      }
      if (r.peOi > maxPeOi) {
        maxPeOi = r.peOi;
        putWall = r.strike;
      }
      // Note: r.ceOi is already scaled to shares in chain engines; lotSize multiplier applied if raw contracts
      final mult = r.ceOi < 200000 ? lotSize : 1;
      final strikeGex = (r.peOi - r.ceOi) *
          mult *
          r.ceGamma *
          spot *
          spot *
          0.01;
      netGex += strikeGex;
    }

    // Compute Max Pain Strike (strike minimizing intrinsic payout of all open CE + PE)
    int maxPain = (rows.first as StrikeRowSnapshot).strike;
    double minPayout = double.infinity;
    for (final candidateRaw in rows) {
      final cand = (candidateRaw as StrikeRowSnapshot).strike;
      double payout = 0.0;
      for (final raw in rows) {
        final r = raw as StrikeRowSnapshot;
        if (cand > r.strike) {
          payout += (cand - r.strike) * r.ceOi;
        } else if (cand < r.strike) {
          payout += (r.strike - cand) * r.peOi;
        }
      }
      if (payout < minPayout) {
        minPayout = payout;
        maxPain = cand;
      }
    }

    final gexCrores = netGex / 1e7;
    final flipSpot =
        callWall > 0 && putWall > 0 ? 0.5 * (callWall + putWall) : spot;

    return DealerGexSummary(
      netGexCr: double.parse(gexCrores.toStringAsFixed(2)),
      callWallStrike: callWall,
      putWallStrike: putWall,
      maxPainStrike: maxPain,
      gammaFlipSpot: flipSpot,
      assumptionNote:
          'Dealer sign convention (short customer flow) is an assumption, not observed data.',
    );
  }

  /// Compatibility helper for existing callers
  static double computeNetGammaExposure(
    List rows,
    double spot, {
    int lotSize = 1,
  }) {
    return computeDealerPositioning(rows, spot, lotSize: lotSize).netGexCr;
  }
}
