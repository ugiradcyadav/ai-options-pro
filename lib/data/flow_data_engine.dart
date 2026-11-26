import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../core/models.dart';
import 'angel_smartapi_engine.dart';
import 'dhan_data_engine.dart';

class SectorFlowSnapshot {
  final String name;
  final String token;
  final double ltp;
  final double changePct;
  final double netChange;
  final double open;
  final double high;
  final double low;

  const SectorFlowSnapshot({
    required this.name,
    required this.token,
    required this.ltp,
    required this.changePct,
    required this.netChange,
    required this.open,
    required this.high,
    required this.low,
  });

  bool get isInflow => changePct >= 0;

  /// Intraday range position (0..1) used as institutional buy/sell pressure proxy
  double get rangePressure {
    final rng = high - low;
    if (rng <= 0) return 0.5;
    return ((ltp - low) / rng).clamp(0.0, 1.0);
  }
}

class StrikeMoneyInjection {
  final int strike;
  final String optionType; // 'CE' or 'PE'
  final double ltp;
  final int volume;
  final int oiLots;
  final int? oiChange15m;
  final double turnoverCr; // Volume * LTP in Crores
  final double? netInjectedCr; // ΔOI_lots * lotSize * LTP in Crores (null until 15m history exists)
  final int bidQty;
  final int askQty;

  const StrikeMoneyInjection({
    required this.strike,
    required this.optionType,
    required this.ltp,
    required this.volume,
    required this.oiLots,
    required this.oiChange15m,
    required this.turnoverCr,
    required this.netInjectedCr,
    required this.bidQty,
    required this.askQty,
  });
}

class RadarSignalAxes {
  final double? oiScore; // 0..100 (50 = neutral)
  final double? optionsScore;
  final double? vwapScore;
  final double? volProfileScore;
  final double? rsiScore;
  final double? priceActionScore;
  final double? vixCalmScore;
  final double? srRoomScore;

  const RadarSignalAxes({
    this.oiScore,
    this.optionsScore,
    this.vwapScore,
    this.volProfileScore,
    this.rsiScore,
    this.priceActionScore,
    this.vixCalmScore,
    this.srRoomScore,
  });

  String get overallBias {
    final vals = [
      oiScore,
      optionsScore,
      vwapScore,
      volProfileScore,
      rsiScore,
      priceActionScore,
      vixCalmScore,
      srRoomScore,
    ].whereType<double>().toList();
    if (vals.isEmpty) return 'NO DATA';
    final avg = vals.reduce((a, b) => a + b) / vals.length;
    if (avg >= 58) return 'bullish';
    if (avg <= 42) return 'bearish';
    return 'neutral';
  }
}

class FlowDataEngine {
  static final FlowDataEngine instance = FlowDataEngine._();
  FlowDataEngine._();

  // Official Angel One SmartAPI NSE index tokens
  static const Map<String, String> sectorTokens = {
    'BANK': '99926009',
    'AUTO': '99926029',
    'IT': '99926008',
    'FMCG': '99926021',
    'PHARMA': '99926023',
    'METAL': '99926030',
    'PSU BANK': '99926025',
    'ENERGY': '99926020',
    'REALTY': '99926018',
    'CONSUMER': '99926036',
  };
  static const String indiaVixToken = '99926017';

  double? indiaVix;
  double? indiaVixChangePct;
  List<SectorFlowSnapshot> sectors = [];
  int lastSectorFetchMs = 0;

  bool get hasSectorData => sectors.isNotEmpty;

  int get buyPressureCount => sectors.where((s) => s.changePct >= 0).length;
  int get sellPressureCount => sectors.where((s) => s.changePct < 0).length;

  /// Mood score (0..100) computed strictly from real advancing sectors + VIX calmness
  int? get marketMoodScore {
    if (sectors.isEmpty) return null;
    final breadthRatio = buyPressureCount / sectors.length;
    final avgChg =
        sectors.map((s) => s.changePct).reduce((a, b) => a + b) /
            sectors.length;
    final chgBoost = (avgChg * 12.0).clamp(-20.0, 20.0);
    final vixPenalty = indiaVix != null && indiaVix! > 16.0
        ? ((indiaVix! - 16.0) * 1.8).clamp(0.0, 20.0)
        : 0.0;
    return ((breadthRatio * 75.0) + 12.5 + chgBoost - vixPenalty)
        .round()
        .clamp(0, 100);
  }

  /// Fetches India VIX + all 10 NSE Sectoral Indices in a single batched Angel One FULL quote call
  Future<bool> refreshSectoralFlow() async {
    final angel = AngelSmartApiEngine.instance;
    if (!angel.isConfigured || angel.jwtToken.isEmpty) return false;

    final allTokens = [indiaVixToken, ...sectorTokens.values];
    try {
      final fetched = await angel.fetchBatchMarketQuotes(
        exchange: 'NSE',
        tokens: allTokens,
      );
      if (fetched.isEmpty) return false;

      final byToken = <String, Map>{};
      for (final item in fetched) {
        if (item is Map) {
          final tok = (item['symbolToken'] ?? '').toString();
          if (tok.isNotEmpty) byToken[tok] = item;
        }
      }

      final vixMap = byToken[indiaVixToken];
      if (vixMap != null) {
        final v = ((vixMap['ltp'] ?? 0) as num).toDouble();
        if (v > 0) {
          indiaVix = v;
          indiaVixChangePct =
              ((vixMap['percentChange'] ?? 0) as num).toDouble();
        }
      }

      final nextSectors = <SectorFlowSnapshot>[];
      sectorTokens.forEach((name, tok) {
        final m = byToken[tok];
        if (m == null) return;
        final ltp = ((m['ltp'] ?? 0) as num).toDouble();
        if (ltp <= 0) return;
        nextSectors.add(
          SectorFlowSnapshot(
            name: name,
            token: tok,
            ltp: ltp,
            changePct: ((m['percentChange'] ?? 0) as num).toDouble(),
            netChange: ((m['netChange'] ?? 0) as num).toDouble(),
            open: ((m['open'] ?? ltp) as num).toDouble(),
            high: ((m['high'] ?? ltp) as num).toDouble(),
            low: ((m['low'] ?? ltp) as num).toDouble(),
          ),
        );
      });

      if (nextSectors.isNotEmpty) {
        nextSectors.sort((a, b) => b.changePct.compareTo(a.changePct));
        sectors = nextSectors;
        lastSectorFetchMs = DateTime.now().millisecondsSinceEpoch;
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Computes real Option Capital Injection (CE vs PE turnover & 15m ΔOI capital injected)
  List<StrikeMoneyInjection> computeOptionCapitalInjection(
      UnderlyingIndex index) {
    final rows = DhanDataEngine.instance.optionChainRows[index] ?? const [];
    final out = <StrikeMoneyInjection>[];
    for (final r in rows) {
      if (r.offset.abs() > 4) continue;
      if (r.ceLtp > 0) {
        final turnCr = (r.ceVolume * r.ceLtp) / 1e7;
        final injCr = r.ceOiChange15m != null
            ? (r.ceOiChange15m! * r.lotSize * r.ceLtp) / 1e7
            : null;
        out.add(StrikeMoneyInjection(
          strike: r.strike,
          optionType: 'CE',
          ltp: r.ceLtp,
          volume: r.ceVolume,
          oiLots: r.ceOi,
          oiChange15m: r.ceOiChange15m,
          turnoverCr: turnCr,
          netInjectedCr: injCr,
          bidQty: r.ceBidQty,
          askQty: r.ceAskQty,
        ));
      }
      if (r.peLtp > 0) {
        final turnCr = (r.peVolume * r.peLtp) / 1e7;
        final injCr = r.peOiChange15m != null
            ? (r.peOiChange15m! * r.lotSize * r.peLtp) / 1e7
            : null;
        out.add(StrikeMoneyInjection(
          strike: r.strike,
          optionType: 'PE',
          ltp: r.peLtp,
          volume: r.peVolume,
          oiLots: r.peOi,
          oiChange15m: r.peOiChange15m,
          turnoverCr: turnCr,
          netInjectedCr: injCr,
          bidQty: r.peBidQty,
          askQty: r.peAskQty,
        ));
      }
    }
    out.sort((a, b) => b.turnoverCr.compareTo(a.turnoverCr));
    return out;
  }

  /// Computes real 8-Signal Radar axes from live chain & recorded bars (returns null per axis when unavailable)
  RadarSignalAxes computeRadarAxes({
    required UnderlyingIndex index,
    required List<OneMinEnrichedBar> recentBars,
  }) {
    final engine = DhanDataEngine.instance;
    final rows = engine.optionChainRows[index] ?? const [];
    final spot = engine.spotPrices[index] ?? 0.0;
    if (rows.isEmpty || spot <= 0) {
      return const RadarSignalAxes();
    }

    int totalCeOi = 0, totalPeOi = 0;
    int? netOiChg;
    int totalBid = 0, totalAsk = 0;
    StrikeRowSnapshot? atmRow;
    int callWall = 0, maxCe = -1;
    int putWall = 0, maxPe = -1;

    for (final r in rows) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      if (r.ceOi > maxCe) {
        maxCe = r.ceOi;
        callWall = r.strike;
      }
      if (r.peOi > maxPe) {
        maxPe = r.peOi;
        putWall = r.strike;
      }
      if (r.ceOiChange15m != null && r.peOiChange15m != null) {
        netOiChg = (netOiChg ?? 0) + (r.peOiChange15m! - r.ceOiChange15m!);
      }
      if (r.offset.abs() <= 2) {
        totalBid += r.ceBidQty + r.peBidQty;
        totalAsk += r.ceAskQty + r.peAskQty;
      }
      if (r.offset == 0) atmRow = r;
    }

    final pcr = totalCeOi > 0 ? totalPeOi / totalCeOi.toDouble() : null;
    final double? oiScore = netOiChg != null && (totalCeOi + totalPeOi) > 0
        ? (50.0 + (netOiChg / (totalCeOi + totalPeOi)) * 400.0).clamp(5.0, 95.0)
        : null;
    final double? optionsScore =
        pcr != null ? (50.0 + (pcr - 1.0) * 90.0).clamp(5.0, 95.0) : null;
    final double? volProfScore = (totalBid + totalAsk) > 0
        ? ((totalBid / (totalBid + totalAsk)) * 100.0).clamp(5.0, 95.0)
        : null;

    double? vixCalmScore;
    final vixRef = indiaVix ?? atmRow?.ceIv;
    if (vixRef != null && vixRef > 0) {
      vixCalmScore = (100.0 - ((vixRef - 10.0) * 3.5)).clamp(10.0, 95.0);
    }

    double? srRoomScore;
    if (callWall > putWall && spot > 0) {
      final roomUp = (callWall - spot) / math.max(1.0, (callWall - putWall).toDouble());
      srRoomScore = (roomUp * 100.0).clamp(5.0, 95.0);
    }

    double? rsiScore;
    double? vwapScore;
    double? priceActionScore;
    final optBars = recentBars.where((b) => b.close > 0).toList();
    if (optBars.length >= 5) {
      double gain = 0, loss = 0, pv = 0, v = 0;
      for (int i = 1; i < optBars.length; i++) {
        final d = optBars[i].close - optBars[i - 1].close;
        if (d > 0) {
          gain += d;
        } else {
          loss += d.abs();
        }
        pv += optBars[i].close * optBars[i].intervalVolume;
        v += optBars[i].intervalVolume;
      }
      if (loss > 1e-6) {
        rsiScore = (100.0 - (100.0 / (1.0 + gain / loss))).clamp(5.0, 95.0);
      }
      if (v > 0) {
        final vwap = pv / v;
        final diffPct = ((optBars.last.close - vwap) / vwap) * 100.0;
        vwapScore = (50.0 + diffPct * 12.0).clamp(5.0, 95.0);
      }
      final chg = engine.spotChangePct[index] ?? 0.0;
      priceActionScore = (50.0 + chg * 25.0).clamp(5.0, 95.0);
    }

    return RadarSignalAxes(
      oiScore: oiScore,
      optionsScore: optionsScore,
      vwapScore: vwapScore,
      volProfileScore: volProfScore,
      rsiScore: rsiScore,
      priceActionScore: priceActionScore,
      vixCalmScore: vixCalmScore,
      srRoomScore: srRoomScore,
    );
  }
}
