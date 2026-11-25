import 'dart:math' as math;
import '../core/models.dart';
import '../data/angel_smartapi_engine.dart';
import '../data/constituent_flow_engine.dart';
import '../data/scrip_master_engine.dart';
import '../data/strike_selector.dart';

class FuturesBasisSnapshot {
  final UnderlyingIndex index;
  final String tradingSymbol;
  final String expiryIso;
  final double futuresLtp;
  final double spotLtp;
  final double basisPoints;
  final double basisPct;
  final double basisDeltaPoints; // vs previous tick/poll
  final int futOiLots;
  final int futVolume;
  final String posture; // 'PREMIUM EXPAND' | 'PREMIUM SHRINK' | 'DISCOUNT' | 'FAIR'
  final int fetchedAtMs;

  const FuturesBasisSnapshot({
    required this.index,
    required this.tradingSymbol,
    required this.expiryIso,
    required this.futuresLtp,
    required this.spotLtp,
    required this.basisPoints,
    required this.basisPct,
    required this.basisDeltaPoints,
    required this.futOiLots,
    required this.futVolume,
    required this.posture,
    required this.fetchedAtMs,
  });
}

class HeavyweightContribution {
  final String symbol;
  final double weightPct;
  final double changePct;
  final double estIndexPoints;

  const HeavyweightContribution({
    required this.symbol,
    required this.weightPct,
    required this.changePct,
    required this.estIndexPoints,
  });
}

class IndexContributionSummary {
  final List<HeavyweightContribution> topDrivers;
  final double netEstimatedPoints;
  final bool isNarrowTrap;
  final String trapNote;

  const IndexContributionSummary({
    required this.topDrivers,
    required this.netEstimatedPoints,
    required this.isNarrowTrap,
    required this.trapNote,
  });

  static const empty = IndexContributionSummary(
    topDrivers: [],
    netEstimatedPoints: 0.0,
    isNarrowTrap: false,
    trapNote: 'Awaiting live constituent quotes.',
  );
}

class StraddleGammaSnapshot {
  final int atmStrike;
  final double atmStraddlePrice;
  final double impliedMovePct;
  final double? decaySinceOpenPct;
  final double dteDays;
  final bool isZeroDte;
  final bool gammaBlastAlert;
  final String statusNote;

  const StraddleGammaSnapshot({
    required this.atmStrike,
    required this.atmStraddlePrice,
    required this.impliedMovePct,
    required this.decaySinceOpenPct,
    required this.dteDays,
    required this.isZeroDte,
    required this.gammaBlastAlert,
    required this.statusNote,
  });
}

class IntradayLevelsSnapshot {
  final double? orbHigh;
  final double? orbLow;
  final double? sessionHigh;
  final double? sessionLow;
  final String stateLabel; // 'ABOVE ORB' | 'BELOW ORB' | 'INSIDE ORB' | 'COLLECTING'
  final bool divergenceTrap;
  final String note;

  const IntradayLevelsSnapshot({
    this.orbHigh,
    this.orbLow,
    this.sessionHigh,
    this.sessionLow,
    required this.stateLabel,
    required this.divergenceTrap,
    required this.note,
  });

  static const collecting = IntradayLevelsSnapshot(
    stateLabel: 'COLLECTING',
    divergenceTrap: false,
    note: 'Recording real 1m spot bars for 15m ORB & session levels.',
  );
}

/// Real-time Minor Intraday Drivers: Futures Basis, Heavyweight Points, 0-DTE Straddle/Gamma & ORB
class MinorIntelEngine {
  static final MinorIntelEngine instance = MinorIntelEngine._();
  MinorIntelEngine._();

  // Published benchmark constituent weights (%) for top heavyweights per index
  static const Map<UnderlyingIndex, Map<String, double>>
      _benchmarkWeights = {
    UnderlyingIndex.nifty50: {
      'HDFCBANK': 12.6, 'RELIANCE': 8.5, 'ICICIBANK': 8.4, 'INFY': 6.0,
      'BHARTIARTL': 4.4, 'ITC': 4.1, 'LT': 4.0, 'TCS': 3.8,
      'SBIN': 3.2, 'AXISBANK': 3.0, 'KOTAKBANK': 2.8, 'M&M': 2.5,
      'BAJFINANCE': 2.2, 'HINDUNILVR': 2.0, 'SUNPHARMA': 1.8, 'MARUTI': 1.6,
      'NTPC': 1.5, 'HCLTECH': 1.5, 'TITAN': 1.4, 'TATAMOTORS': 1.4,
    },
    UnderlyingIndex.bankNifty: {
      'HDFCBANK': 28.5, 'ICICIBANK': 24.5, 'SBIN': 10.2, 'KOTAKBANK': 9.8,
      'AXISBANK': 9.5, 'INDUSINDBK': 4.5, 'BANKBARODA': 3.0, 'PNB': 2.5,
      'FEDERALBNK': 2.4, 'IDFCFIRSTB': 1.8, 'AUBANK': 1.8, 'CANBK': 1.5,
    },
    UnderlyingIndex.finNifty: {
      'HDFCBANK': 31.0, 'ICICIBANK': 23.0, 'KOTAKBANK': 10.0, 'AXISBANK': 9.2,
      'SBIN': 7.5, 'BAJFINANCE': 6.5, 'BAJAJFINSV': 3.5, 'SBILIFE': 2.2,
      'HDFCLIFE': 2.0, 'SHRIRAMFIN': 1.8, 'CHOLAFIN': 1.4, 'PFC': 1.0,
      'RECLTD': 0.9,
    },
    UnderlyingIndex.sensex: {
      'HDFCBANK': 14.5, 'RELIANCE': 10.2, 'ICICIBANK': 9.8, 'INFY': 7.0,
      'BHARTIARTL': 5.1, 'ITC': 4.8, 'LT': 4.6, 'TCS': 4.5,
      'SBIN': 3.7, 'AXISBANK': 3.5, 'KOTAKBANK': 3.3, 'M&M': 2.9,
      'BAJFINANCE': 2.6, 'HINDUNILVR': 2.3, 'SUNPHARMA': 2.1, 'MARUTI': 1.9,
    },
  };

  final Map<UnderlyingIndex, FuturesBasisSnapshot> _basisCache = {};
  final Map<UnderlyingIndex, bool> _basisInFlight = {};
  final Map<String, double> _sessionOpenStraddle = {};

  FuturesBasisSnapshot? getFuturesBasis(UnderlyingIndex idx) => _basisCache[idx];

  Future<FuturesBasisSnapshot?> refreshFuturesBasis(
    UnderlyingIndex idx,
    double liveSpot, {
    bool force = false,
  }) async {
    if (liveSpot <= 0) return _basisCache[idx];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final prev = _basisCache[idx];
    if (!force && prev != null && (nowMs - prev.fetchedAtMs) < 5000) {
      return prev;
    }
    if (_basisInFlight[idx] == true) return prev;

    final fut = ScripMasterEngine.instance.getNearestFutureForIndex(idx);
    if (fut == null) return prev;

    final angel = AngelSmartApiEngine.instance;
    if (!angel.isConfigured || !angel.hasValidJwt) return prev;

    _basisInFlight[idx] = true;
    try {
      final fetched = await angel.fetchBatchMarketQuotes(
        exchange: fut.exchangeSegment,
        tokens: [fut.securityId],
      );
      if (fetched.isEmpty) return prev;
      final q = fetched.first;
      final futLtp = ((q['ltp'] ?? 0) as num).toDouble();
      if (futLtp <= 0) return prev;

      final basisPts = futLtp - liveSpot;
      final basisPct = (basisPts / liveSpot) * 100.0;
      final deltaPts = prev != null ? (basisPts - prev.basisPoints) : 0.0;
      final oiLots = AngelSmartApiEngine.normalizeAngelOiToLots(
        ((q['opnInterest'] ?? 0) as num).toInt(),
        fut.lotSize,
      );
      final vol = ((q['tradeVolume'] ?? 0) as num).toInt();

      String posture = 'FAIR BASIS';
      if (basisPts < -5.0) {
        posture = 'DISCOUNT (HEDGE)';
      } else if (deltaPts >= 2.0) {
        posture = 'PREMIUM EXPAND';
      } else if (deltaPts <= -2.0) {
        posture = 'PREMIUM SHRINK';
      } else if (basisPts > 0) {
        posture = 'PREMIUM';
      }

      final snap = FuturesBasisSnapshot(
        index: idx,
        tradingSymbol: fut.tradingSymbol,
        expiryIso: fut.expiryIso,
        futuresLtp: futLtp,
        spotLtp: liveSpot,
        basisPoints: basisPts,
        basisPct: basisPct,
        basisDeltaPoints: deltaPts,
        futOiLots: oiLots,
        futVolume: vol,
        posture: posture,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      _basisCache[idx] = snap;
      return snap;
    } finally {
      _basisInFlight[idx] = false;
    }
  }

  /// Calculates estimated Index Points Contribution from real live constituent quotes
  static IndexContributionSummary computeHeavyweightPoints({
    required UnderlyingIndex index,
    required double spot,
    required IndexConstituentFlowSnapshot? constituents,
  }) {
    if (spot <= 0 || constituents == null || constituents.items.isEmpty) {
      return IndexContributionSummary.empty;
    }

    final weights = _benchmarkWeights[index] ?? const <String, double>{};
    final items = constituents.items;
    final list = <HeavyweightContribution>[];
    double netPts = 0.0;

    for (final st in items) {
      final w = weights[st.symbol] ?? (10.0 / math.max(1, items.length));
      final pts = spot * (w / 100.0) * (st.changePct / 100.0);
      netPts += pts;
      list.add(HeavyweightContribution(
        symbol: st.symbol,
        weightPct: w,
        changePct: st.changePct,
        estIndexPoints: pts,
      ));
    }

    list.sort((a, b) => b.estIndexPoints.abs().compareTo(a.estIndexPoints.abs()));
    final top3 = list.take(3).toList();
    final top3Sum = top3.fold<double>(0.0, (s, e) => s + e.estIndexPoints);
    final advRatio = constituents.inflows.length / math.max(1, items.length);

    bool narrowTrap = false;
    String note = 'Broad participation across ${items.length} constituents.';
    if (netPts.abs() > 8.0) {
      final topShare = (top3Sum.abs() / math.max(1.0, netPts.abs()));
      if (netPts > 0 && topShare > 0.70 && advRatio < 0.45) {
        narrowTrap = true;
        note =
            'NARROW RALLY TRAP: Top-3 heavyweights lifting index while ${(100 - advRatio * 100).toStringAsFixed(0)}% stocks are RED.';
      } else if (netPts < 0 && topShare > 0.70 && advRatio > 0.55) {
        narrowTrap = true;
        note =
            'NARROW SELLOFF: Top-3 heavyweights dragging index while ${(advRatio * 100).toStringAsFixed(0)}% stocks are GREEN.';
      } else {
        final lead = top3
            .map((e) =>
                '${e.symbol} ${e.estIndexPoints >= 0 ? "+" : ""}${e.estIndexPoints.toStringAsFixed(1)}pt')
            .join(' • ');
        note = 'Drivers: $lead';
      }
    }

    return IndexContributionSummary(
      topDrivers: list.take(5).toList(),
      netEstimatedPoints: netPts,
      isNarrowTrap: narrowTrap,
      trapNote: note,
    );
  }

  /// Live ATM Straddle Premium, Intraday Decay % & 0-DTE Gamma Blast Alert
  StraddleGammaSnapshot? evaluateStraddleAndGamma({
    required UnderlyingIndex index,
    required String expiryIso,
    required double spot,
    required List<StrikeRowSnapshot> rows,
    DateTime? nowUtc,
  }) {
    if (rows.isEmpty || spot <= 0 || expiryIso.isEmpty) return null;

    StrikeRowSnapshot? atm;
    int maxCallStrike = 0, maxCallOi = -1;
    int maxPutStrike = 0, maxPutOi = -1;
    for (final r in rows) {
      if (r.offset == 0) atm = r;
      if (r.ceOi > maxCallOi) {
        maxCallOi = r.ceOi;
        maxCallStrike = r.strike;
      }
      if (r.peOi > maxPutOi) {
        maxPutOi = r.peOi;
        maxPutStrike = r.strike;
      }
    }
    if (atm == null || atm.ceLtp <= 0 || atm.peLtp <= 0) return null;

    final straddle = atm.ceLtp + atm.peLtp;
    final impMovePct = (straddle / spot) * 100.0;
    final tYears = StrikeSelectionEngine.computeFractionalYearsToExpiryIst(
      expiryIso,
      nowUtc: nowUtc,
    );
    final dteDays = tYears * 365.0;
    final isZeroDte = dteDays < 0.85;

    final key = '${index.dhanSymbol}|$expiryIso|${atm.strike}';
    _sessionOpenStraddle.putIfAbsent(key, () => straddle);
    final baseStraddle = _sessionOpenStraddle[key]!;
    final decayPct = baseStraddle > 0
        ? ((straddle - baseStraddle) / baseStraddle) * 100.0
        : null;

    final distCallPct = maxCallStrike > 0
        ? ((spot - maxCallStrike).abs() / spot) * 100.0
        : 99.0;
    final distPutPct = maxPutStrike > 0
        ? ((spot - maxPutStrike).abs() / spot) * 100.0
        : 99.0;
    final gammaBlast = dteDays <= 1.2 &&
        (distCallPct <= 0.35 || distPutPct <= 0.35);

    final status = gammaBlast
        ? 'GAMMA BLAST ZONE: Spot near ${distCallPct < distPutPct ? "Call Wall $maxCallStrike" : "Put Wall $maxPutStrike"} on ${isZeroDte ? "0-DTE" : "Expiry"}'
        : (isZeroDte
            ? '0-DTE EXPIRY • Straddle ±${straddle.toStringAsFixed(0)} pts (±${impMovePct.toStringAsFixed(2)}%)'
            : 'Implied Move ±${straddle.toStringAsFixed(0)} pts (±${impMovePct.toStringAsFixed(2)}%)');

    return StraddleGammaSnapshot(
      atmStrike: atm.strike,
      atmStraddlePrice: straddle,
      impliedMovePct: impMovePct,
      decaySinceOpenPct: decayPct,
      dteDays: dteDays,
      isZeroDte: isZeroDte,
      gammaBlastAlert: gammaBlast,
      statusNote: status,
    );
  }

  /// 15-Minute Opening Range (ORB) & Session Liquidity Levels from real today IST spot bars
  static IntradayLevelsSnapshot evaluateOrbAndLevels({
    required List<OneMinEnrichedBar> spotBars,
    required double liveSpot,
    double? breadthUpPct,
  }) {
    if (spotBars.isEmpty || liveSpot <= 0) {
      return IntradayLevelsSnapshot.collecting;
    }
    final sorted = spotBars
        .where((b) => b.close > 0 && b.high >= b.low)
        .toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    if (sorted.isEmpty) return IntradayLevelsSnapshot.collecting;

    final latestIst = DateTime.fromMillisecondsSinceEpoch(
      sorted.last.timestampMs,
      isUtc: true,
    ).add(const Duration(hours: 5, minutes: 30));

    final todayBars = sorted.where((b) {
      final d = DateTime.fromMillisecondsSinceEpoch(b.timestampMs, isUtc: true)
          .add(const Duration(hours: 5, minutes: 30));
      return d.year == latestIst.year &&
          d.month == latestIst.month &&
          d.day == latestIst.day;
    }).toList();

    if (todayBars.isEmpty) return IntradayLevelsSnapshot.collecting;

    double sHigh = todayBars.first.high;
    double sLow = todayBars.first.low;
    double? orbHigh;
    double? orbLow;

    for (final b in todayBars) {
      if (b.high > sHigh) sHigh = b.high;
      if (b.low < sLow) sLow = b.low;
      final d = DateTime.fromMillisecondsSinceEpoch(b.timestampMs, isUtc: true)
          .add(const Duration(hours: 5, minutes: 30));
      final mins = d.hour * 60 + d.minute;
      // First 15 minutes: 09:15 to 09:30 IST
      if (mins >= 555 && mins <= 570) {
        orbHigh = orbHigh == null ? b.high : math.max(orbHigh, b.high);
        orbLow = orbLow == null ? b.low : math.min(orbLow, b.low);
      }
    }

    // Fallback to first 15 recorded session bars if app opened after 09:30
    if (orbHigh == null && todayBars.length >= 5) {
      final slice = todayBars.take(math.min(15, todayBars.length));
      for (final b in slice) {
        orbHigh = orbHigh == null ? b.high : math.max(orbHigh, b.high);
        orbLow = orbLow == null ? b.low : math.min(orbLow, b.low);
      }
    }

    String state = 'INSIDE ORB';
    bool trap = false;
    String note = 'Session Range ${sLow.toStringAsFixed(0)} – ${sHigh.toStringAsFixed(0)}';

    if (orbHigh != null && orbLow != null) {
      if (liveSpot > orbHigh) {
        state = 'ABOVE ORB';
        if (breadthUpPct != null && breadthUpPct < 45.0) {
          trap = true;
          note =
              'BREAKOUT TRAP: Spot above ORB (${orbHigh.toStringAsFixed(0)}) but breadth weak (${breadthUpPct.toStringAsFixed(0)}% up).';
        } else {
          note = 'Breakout above 15m ORB High ${orbHigh.toStringAsFixed(0)}.';
        }
      } else if (liveSpot < orbLow) {
        state = 'BELOW ORB';
        if (breadthUpPct != null && breadthUpPct > 55.0) {
          trap = true;
          note =
              'BREAKDOWN TRAP: Spot below ORB (${orbLow.toStringAsFixed(0)}) while breadth strong (${breadthUpPct.toStringAsFixed(0)}% up).';
        } else {
          note = 'Breakdown below 15m ORB Low ${orbLow.toStringAsFixed(0)}.';
        }
      } else {
        note =
            'Inside ORB [${orbLow.toStringAsFixed(0)} – ${orbHigh.toStringAsFixed(0)}] • H/L ${sHigh.toStringAsFixed(0)}/${sLow.toStringAsFixed(0)}';
      }
    }

    return IntradayLevelsSnapshot(
      orbHigh: orbHigh,
      orbLow: orbLow,
      sessionHigh: sHigh,
      sessionLow: sLow,
      stateLabel: state,
      divergenceTrap: trap,
      note: note,
    );
  }
}
