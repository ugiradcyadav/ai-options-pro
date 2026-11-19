import 'dart:math' as math;
import '../core/models.dart';

class PricingRateConfig {
  // Dated config: 91-day T-Bill / MIBOR proxy — verify periodically against RBI/FBIL
  static const String effectiveDate = '2026-11-01';
  static const double riskFreeRate = 0.066;
}

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
  final double? atmIv;
  final double? riskReversal25d;
  final double? butterfly25d;
  final double? fitResidualRmse;
  final double quadA;
  final double quadB;
  final double quadC;
  final bool hasButterflyArbitrage;
  final String surfaceNote;

  const IvSurfaceMetrics({
    required this.atmIv,
    required this.riskReversal25d,
    required this.butterfly25d,
    required this.fitResidualRmse,
    this.quadA = 0.0,
    this.quadB = 0.0,
    this.quadC = 0.0,
    required this.hasButterflyArbitrage,
    required this.surfaceNote,
  });
}

class VolForecastMetrics {
  final double? rvCloseToClosePct;
  final double? rvParkinsonPct;
  final double? rvGarmanKlassPct;
  final double? ewmaForecastRvPct;
  final double? varianceRiskPremiumPct;
  final double? expectedMovePoints;
  final int validIntervalsUsed;

  const VolForecastMetrics({
    required this.rvCloseToClosePct,
    required this.rvParkinsonPct,
    required this.rvGarmanKlassPct,
    required this.ewmaForecastRvPct,
    required this.varianceRiskPremiumPct,
    required this.expectedMovePoints,
    this.validIntervalsUsed = 0,
  });
}

class DealerGexSummary {
  final double netGexCr;
  final int callWallStrike;
  final int putWallStrike;
  final int maxPainStrike;
  final double? gammaFlipSpot;
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
  static const double defaultRiskFreeRate = PricingRateConfig.riskFreeRate;
  static const double nseTradingMinutesPerYear = 252.0 * 375.0;

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

  /// WP-7: Put-Call Parity Forward: F = K + exp(r*T) * (C - P)
  static double deriveForwardFromParity({
    required double spot,
    required double atmStrike,
    required double atmCallMid,
    required double atmPutMid,
    required double timeYears,
    double r = defaultRiskFreeRate,
  }) {
    if (atmCallMid <= 0 || atmPutMid <= 0 || atmStrike <= 0 || timeYears <= 0) {
      return spot * math.exp(r * math.max(timeYears, 0.0));
    }
    final impliedF =
        atmStrike + math.exp(r * timeYears) * (atmCallMid - atmPutMid);
    if ((impliedF - spot).abs() > spot * 0.05) {
      return spot * math.exp(r * timeYears);
    }
    return impliedF;
  }

  /// Black-76 Forward-based European index option pricing
  static double black76Price({
    required double forward,
    required double strike,
    required double timeYears,
    required double sigma,
    required bool isCall,
    double r = defaultRiskFreeRate,
  }) {
    if (timeYears <= 0 || sigma <= 0 || forward <= 0 || strike <= 0) {
      final df = math.exp(-r * math.max(timeYears, 0.0));
      return isCall
          ? math.max(0.0, df * (forward - strike))
          : math.max(0.0, df * (strike - forward));
    }
    final sqrtT = math.sqrt(timeYears);
    final df = math.exp(-r * timeYears);
    final d1 = (math.log(forward / strike) + 0.5 * sigma * sigma * timeYears) /
        (sigma * sqrtT);
    final d2 = d1 - sigma * sqrtT;

    if (isCall) {
      return df * (forward * _normCdf(d1) - strike * _normCdf(d2));
    } else {
      return df * (strike * _normCdf(-d2) - forward * _normCdf(-d1));
    }
  }

  /// Unclamped Newton-Raphson + Bisection fallback IV solver. Returns null on failure.
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
      return {'iv': null, 'lowQuality': true, 'reason': 'Non-positive quote or expired'};
    }

    final df = math.exp(-r * timeYears);
    final intrinsic = isCall
        ? math.max(0.0, df * (forward - strike))
        : math.max(0.0, df * (strike - forward));

    if (marketMidPrice < intrinsic - 1e-4) {
      return {
        'iv': null,
        'lowQuality': true,
        'reason': 'Price below intrinsic (${intrinsic.toStringAsFixed(2)})'
      };
    }

    final upperBound = isCall ? df * forward : df * strike;
    if (marketMidPrice >= upperBound) {
      return {'iv': null, 'lowQuality': true, 'reason': 'Price exceeds upper bound'};
    }

    double low = 1e-4;
    double high = 5.0;
    final timeVal = math.max(0.001, marketMidPrice - intrinsic);
    double sigma =
        math.sqrt(2.0 * math.pi / timeYears) * (timeVal / (df * forward));
    if (sigma.isNaN || sigma.isInfinite || sigma <= low || sigma >= high) {
      sigma = 0.20;
    }

    final sqrtT = math.sqrt(timeYears);
    bool converged = false;

    for (int iter = 0; iter < 30; iter++) {
      final price = black76Price(
        forward: forward,
        strike: strike,
        timeYears: timeYears,
        sigma: sigma,
        isCall: isCall,
        r: r,
      );
      final diff = price - marketMidPrice;
      if (diff.abs() < 1e-8) {
        converged = true;
        break;
      }
      if (diff > 0) {
        high = sigma;
      } else {
        low = sigma;
      }

      final d1 = (math.log(forward / strike) + 0.5 * sigma * sigma * timeYears) /
          (sigma * sqrtT);
      final vega = df * forward * _normPdf(d1) * sqrtT;

      if (vega > 1e-8) {
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
      for (int b = 0; b < 50; b++) {
        sigma = 0.5 * (low + high);
        final p = black76Price(
          forward: forward,
          strike: strike,
          timeYears: timeYears,
          sigma: sigma,
          isCall: isCall,
          r: r,
        );
        final err = p - marketMidPrice;
        if (err.abs() < 1e-7) {
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
      return {'iv': null, 'lowQuality': true, 'reason': 'IV solver did not converge'};
    }

    final d1 = (math.log(forward / strike) + 0.5 * sigma * sigma * timeYears) /
        (sigma * sqrtT);
    final vegaCheck = df * forward * _normPdf(d1) * sqrtT;
    final bool wideSpread = spreadPct > 5.0;
    final bool nearZeroVega = vegaCheck < 0.05;

    return {
      'iv': sigma,
      'lowQuality': wideSpread || nearZeroVega,
      'reason': wideSpread
          ? 'Wide spread (${spreadPct.toStringAsFixed(1)}%)'
          : (nearZeroVega ? 'Near-zero vega' : 'OK'),
    };
  }

  /// WP-7: Full-precision First & Second-Order Black-76 Greeks (NO rounding before downstream use)
  static OptionGreeksResult computeIvAndGreeks({
    required double spot,
    required double strike,
    required double optionLtp,
    required double daysToExpiry,
    required bool isCall,
    double? timeYearsOverride,
    double? bidPrice,
    double? askPrice,
    double? forwardPriceOverride,
    double r = defaultRiskFreeRate,
  }) {
    final t = timeYearsOverride ?? (daysToExpiry / 365.0);
    if (t <= 0 || spot <= 0 || strike <= 0) {
      return const OptionGreeksResult(
        rawSolvedIv: null,
        ivPct: 0.0,
        delta: 0.0,
        gamma: 0.0,
        theta: 0.0,
        vega: 0.0,
        isLowQualityIv: true,
        ivQualityNote: 'Expired or invalid input',
      );
    }

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

    final double? rawSigma = solvedMap['iv'] as double?;
    final bool lowQual = solvedMap['lowQuality'] as bool? ?? false;
    final String qualNote = (solvedMap['reason'] ?? 'OK').toString();

    if (rawSigma == null || rawSigma <= 0) {
      return OptionGreeksResult(
        rawSolvedIv: null,
        ivPct: 0.0,
        delta: 0.0,
        gamma: 0.0,
        theta: 0.0,
        vega: 0.0,
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

    // Full-precision Black-76 Greeks (discounted forward delta & gamma)
    final delta = isCall ? (df * _normCdf(d1)) : (df * (_normCdf(d1) - 1.0));
    final gamma = (df * pdfD1) / (f * sigma * sqrtT);
    final vegaPer1Pct = (df * f * pdfD1 * sqrtT) / 100.0;

    final optPrice = black76Price(
      forward: f,
      strike: strike,
      timeYears: t,
      sigma: sigma,
      isCall: isCall,
      r: r,
    );
    final annualTheta = -(df * f * pdfD1 * sigma) / (2.0 * sqrtT) + r * optPrice;
    final dailyTheta = annualTheta / 365.0;

    // Second-Order Analytic Greeks (full precision)
    final vanna = (-df * pdfD1 * d2 / sigma) / 100.0;
    final vomma = vegaPer1Pct * (d1 * d2 / sigma) / 100.0;
    final charmAnnual = -df * pdfD1 * (-d2 / (2.0 * t)) + r * delta;
    final charmDaily = charmAnnual / 365.0;

    return OptionGreeksResult(
      rawSolvedIv: rawSigma,
      ivPct: sigma * 100.0,
      delta: delta,
      gamma: gamma,
      theta: dailyTheta,
      vega: vegaPer1Pct,
      vanna: vanna,
      charm: charmDaily,
      vomma: vomma,
      forwardPrice: f,
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

  /// WP-7: True 25-delta strike lookup + Ordinary Least Squares quadratic smile fit in log-moneyness
  static IvSurfaceMetrics evaluateIvSurface(List rows, double spot) {
    if (rows.isEmpty || spot <= 0) {
      return const IvSurfaceMetrics(
        atmIv: null,
        riskReversal25d: null,
        butterfly25d: null,
        fitResidualRmse: null,
        hasButterflyArbitrage: false,
        surfaceNote: 'NO DATA',
      );
    }

    double? atmIv;
    double? call25Iv;
    double? put25Iv;
    double bestCallDeltaErr = double.infinity;
    double bestPutDeltaErr = double.infinity;

    final ks = <double>[];
    final ivs = <double>[];

    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      if (r.ceIv != null && r.ceIv! > 0) {
        final dErr = (r.ceDelta - 0.25).abs();
        if (dErr < bestCallDeltaErr) {
          bestCallDeltaErr = dErr;
          call25Iv = r.ceIv;
        }
      }
      if (r.peIv != null && r.peIv! > 0) {
        final dErr = (r.peDelta.abs() - 0.25).abs();
        if (dErr < bestPutDeltaErr) {
          bestPutDeltaErr = dErr;
          put25Iv = r.peIv;
        }
      }

      double? strikeIv;
      if (r.ceIv != null && r.peIv != null && r.ceIv! > 0 && r.peIv! > 0) {
        strikeIv = 0.5 * (r.ceIv! + r.peIv!);
      } else if (r.strike >= spot && r.ceIv != null && r.ceIv! > 0) {
        strikeIv = r.ceIv;
      } else if (r.strike < spot && r.peIv != null && r.peIv! > 0) {
        strikeIv = r.peIv;
      }

      if (r.offset == 0 && strikeIv != null) {
        atmIv = strikeIv;
      }
      if (strikeIv != null && r.strike > 0) {
        ks.add(math.log(r.strike / spot));
        ivs.add(strikeIv);
      }
    }

    if (atmIv == null && ivs.isNotEmpty) {
      atmIv = ivs[ivs.length ~/ 2];
    }

    final rr25 = (call25Iv != null && put25Iv != null)
        ? (call25Iv - put25Iv)
        : null;
    final bf25 = (call25Iv != null && put25Iv != null && atmIv != null)
        ? (0.5 * (call25Iv + put25Iv) - atmIv)
        : null;

    // Fit quadratic iv(k) = a + b*k + c*k^2 via 3x3 normal equations
    double a = atmIv ?? 0.0, b = 0.0, c = 0.0;
    double? rmse;
    bool arbFlag = false;

    if (ks.length >= 3) {
      double s0 = ks.length.toDouble();
      double s1 = 0, s2 = 0, s3 = 0, s4 = 0;
      double sy = 0, sxy = 0, sx2y = 0;
      for (int i = 0; i < ks.length; i++) {
        final k = ks[i];
        final k2 = k * k;
        final y = ivs[i];
        s1 += k;
        s2 += k2;
        s3 += k2 * k;
        s4 += k2 * k2;
        sy += y;
        sxy += k * y;
        sx2y += k2 * y;
      }

      final coeffs = _solve3x3(
        [
          [s0, s1, s2],
          [s1, s2, s3],
          [s2, s3, s4],
        ],
        [sy, sxy, sx2y],
      );
      if (coeffs != null) {
        a = coeffs[0];
        b = coeffs[1];
        c = coeffs[2];
        double errSq = 0.0;
        for (int i = 0; i < ks.length; i++) {
          final k = ks[i];
          final fit = a + b * k + c * k * k;
          final d = ivs[i] - fit;
          errSq += d * d;
        }
        rmse = math.sqrt(errSq / ks.length);
        // Concave wings (c < 0) indicate potential butterfly arbitrage violation
        arbFlag = c < -0.05;
      }
    }

    return IvSurfaceMetrics(
      atmIv: atmIv,
      riskReversal25d: rr25,
      butterfly25d: bf25,
      fitResidualRmse: rmse,
      quadA: a,
      quadB: b,
      quadC: c,
      hasButterflyArbitrage: arbFlag,
      surfaceNote: rmse == null
          ? 'Insufficient valid IV points for smile fit'
          : (arbFlag
              ? 'WARN: Concave smile (c=${c.toStringAsFixed(2)}) • RMSE ${rmse.toStringAsFixed(2)}%'
              : 'OLS Quadratic Smile • RMSE ${rmse.toStringAsFixed(2)}%'),
    );
  }

  static List<double>? _solve3x3(
      List<List<double>> m, List<double> rhs) {
    final a = [
      [m[0][0], m[0][1], m[0][2], rhs[0]],
      [m[1][0], m[1][1], m[1][2], rhs[1]],
      [m[2][0], m[2][1], m[2][2], rhs[2]],
    ];
    for (int col = 0; col < 3; col++) {
      int pivot = col;
      for (int r = col + 1; r < 3; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      if (a[pivot][col].abs() < 1e-12) return null;
      final tmp = a[col];
      a[col] = a[pivot];
      a[pivot] = tmp;

      final div = a[col][col];
      for (int j = col; j < 4; j++) {
        a[col][j] /= div;
      }
      for (int r = 0; r < 3; r++) {
        if (r == col) continue;
        final factor = a[r][col];
        for (int j = col; j < 4; j++) {
          a[r][j] -= factor * a[col][j];
        }
      }
    }
    return [a[0][3], a[1][3], a[2][3]];
  }

  /// WP-7: Realized Volatility on UNDERLYING INDEX 1m bars, excluding overnight/session gaps (> 15 min)
  static VolForecastMetrics computeVolForecast({
    required List recentSpotBars,
    required double? currentAtmIvPct,
    required double spot,
    required double holdingMinutes,
  }) {
    // Filter strictly to underlying SPOT bars (never compute RV on option premiums)
    final spotBars = recentSpotBars
        .map((e) => e as OneMinEnrichedBar)
        .where((b) => b.optionType.toUpperCase() == 'SPOT' && b.close > 0)
        .toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    if (spotBars.length < 5 || spot <= 0) {
      return const VolForecastMetrics(
        rvCloseToClosePct: null,
        rvParkinsonPct: null,
        rvGarmanKlassPct: null,
        ewmaForecastRvPct: null,
        varianceRiskPremiumPct: null,
        expectedMovePoints: null,
        validIntervalsUsed: 0,
      );
    }

    double sumRetSq = 0.0;
    double sumParkinson = 0.0;
    double sumGk = 0.0;
    double ewmaVar = 0.0;
    const double lambda = 0.94;
    int count = 0;

    for (int i = 1; i < spotBars.length; i++) {
      final prev = spotBars[i - 1];
      final cur = spotBars[i];
      // WP-7: Exclude overnight or multi-minute data gaps (> 15 minutes)
      final dtMs = cur.timestampMs - prev.timestampMs;
      if (dtMs <= 0 || dtMs > 15 * 60 * 1000) continue;
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

    if (count < 4) {
      return VolForecastMetrics(
        rvCloseToClosePct: null,
        rvParkinsonPct: null,
        rvGarmanKlassPct: null,
        ewmaForecastRvPct: null,
        varianceRiskPremiumPct: null,
        expectedMovePoints: null,
        validIntervalsUsed: count,
      );
    }

    final rvCc = math.sqrt((sumRetSq / count) * nseTradingMinutesPerYear) * 100.0;
    final rvPk =
        math.sqrt((sumParkinson / count) * nseTradingMinutesPerYear) * 100.0;
    final rvGk = math.sqrt((sumGk / count) * nseTradingMinutesPerYear) * 100.0;
    final rvEwma = math.sqrt(ewmaVar * nseTradingMinutesPerYear) * 100.0;

    final bestRv = 0.5 * rvGk + 0.5 * rvEwma;
    // Consistent trading-time basis for both VRP and expected move
    final vrp = currentAtmIvPct != null ? (currentAtmIvPct - bestRv) : null;
    final expMove = spot *
        (bestRv / 100.0) *
        math.sqrt(holdingMinutes / nseTradingMinutesPerYear);

    return VolForecastMetrics(
      rvCloseToClosePct: rvCc,
      rvParkinsonPct: rvPk,
      rvGarmanKlassPct: rvGk,
      ewmaForecastRvPct: bestRv,
      varianceRiskPremiumPct: vrp,
      expectedMovePoints: expMove,
      validIntervalsUsed: count,
    );
  }

  /// WP-7: Per-strike GEX using separate CE & PE gamma + normalized OI lots * lotSize + True Spot-Grid Gamma Flip
  static DealerGexSummary computeDealerPositioning(
    List rows,
    double spot, {
    double timeYears = 3.0 / 365.0,
  }) {
    if (rows.isEmpty || spot <= 0) {
      return const DealerGexSummary(
        netGexCr: 0.0,
        callWallStrike: 0,
        putWallStrike: 0,
        maxPainStrike: 0,
        gammaFlipSpot: null,
        assumptionNote:
            'Dealer sign convention (dealers short customer flow) is an assumption, not observed data.',
      );
    }

    double netGex = 0.0;
    int callWall = 0;
    int maxCeOi = -1;
    int putWall = 0;
    int maxPeOi = -1;
    int minStrike = 9999999;
    int maxStrike = 0;

    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      if (r.strike < minStrike) minStrike = r.strike;
      if (r.strike > maxStrike) maxStrike = r.strike;
      if (r.ceOi > maxCeOi) {
        maxCeOi = r.ceOi;
        callWall = r.strike;
      }
      if (r.peOi > maxPeOi) {
        maxPeOi = r.peOi;
        putWall = r.strike;
      }
      // WP-7: OI is already normalized to lots; multiply by exact master lotSize and separate CE/PE gamma
      final peGex = r.peOi * r.lotSize * r.peGamma * spot * spot * 0.01;
      final ceGex = r.ceOi * r.lotSize * r.ceGamma * spot * spot * 0.01;
      netGex += (peGex - ceGex);
    }

    // Max Pain across the full band
    int maxPain = (rows.first as StrikeRowSnapshot).strike;
    double minPayout = double.infinity;
    for (final candidateRaw in rows) {
      final cand = (candidateRaw as StrikeRowSnapshot).strike;
      double payout = 0.0;
      for (final raw in rows) {
        final r = raw as StrikeRowSnapshot;
        if (cand > r.strike) {
          payout += (cand - r.strike) * r.ceOi * r.lotSize;
        } else if (cand < r.strike) {
          payout += (r.strike - cand) * r.peOi * r.lotSize;
        }
      }
      if (payout < minPayout) {
        minPayout = payout;
        maxPain = cand;
      }
    }

    // WP-7: True Gamma Flip — spot where cumulative net GEX crosses zero across a spot grid
    double? gammaFlip;
    if (maxStrike > minStrike && timeYears > 0) {
      const int gridSteps = 24;
      final stepSize = (maxStrike - minStrike) / gridSteps;
      double? prevSpot;
      double? prevGex;

      for (int g = 0; g <= gridSteps; g++) {
        final sGrid = minStrike + (g * stepSize);
        final gexAtS = _computeGridNetGex(rows, sGrid, timeYears);
        if (prevSpot != null && prevGex != null) {
          if ((prevGex <= 0 && gexAtS >= 0) ||
              (prevGex >= 0 && gexAtS <= 0)) {
            final denom = (gexAtS - prevGex).abs();
            if (denom > 1e-9) {
              final frac = prevGex.abs() / denom;
              gammaFlip = prevSpot + frac * (sGrid - prevSpot);
              break;
            }
          }
        }
        prevSpot = sGrid;
        prevGex = gexAtS;
      }
    }

    return DealerGexSummary(
      netGexCr: netGex / 1e7,
      callWallStrike: callWall,
      putWallStrike: putWall,
      maxPainStrike: maxPain,
      gammaFlipSpot: gammaFlip,
      assumptionNote:
          'Dealer sign convention (dealers short customer flow) is an assumption, not observed data.',
    );
  }

  static double _computeGridNetGex(List rows, double sGrid, double tYears) {
    final df = math.exp(-defaultRiskFreeRate * tYears);
    final fGrid = sGrid * math.exp(defaultRiskFreeRate * tYears);
    final sqrtT = math.sqrt(tYears);
    double sum = 0.0;

    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      final ceSig = (r.ceIv != null && r.ceIv! > 0) ? (r.ceIv! / 100.0) : null;
      final peSig = (r.peIv != null && r.peIv! > 0) ? (r.peIv! / 100.0) : null;

      double ceGam = r.ceGamma;
      if (ceSig != null && fGrid > 0 && r.strike > 0) {
        final d1 = (math.log(fGrid / r.strike) + 0.5 * ceSig * ceSig * tYears) /
            (ceSig * sqrtT);
        ceGam = (df * _normPdf(d1)) / (fGrid * ceSig * sqrtT);
      }

      double peGam = r.peGamma;
      if (peSig != null && fGrid > 0 && r.strike > 0) {
        final d1 = (math.log(fGrid / r.strike) + 0.5 * peSig * peSig * tYears) /
            (peSig * sqrtT);
        peGam = (df * _normPdf(d1)) / (fGrid * peSig * sqrtT);
      }

      sum += (r.peOi * r.lotSize * peGam - r.ceOi * r.lotSize * ceGam) *
          sGrid *
          sGrid *
          0.01;
    }
    return sum;
  }
}
