import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../core/models.dart';
import '../engine/math_greeks.dart';
import 'strike_selector.dart';

class LiveMarketSnapshotResult {
  final double spotPrice;
  final double changePct;
  final List expiries;
  final String activeExpiry;
  final List rows;

  const LiveMarketSnapshotResult({
    required this.spotPrice,
    required this.changePct,
    required this.expiries,
    required this.activeExpiry,
    required this.rows,
  });
}

class LiveNseBridge {
  static String _nseCookie = '';

  static Map<String, String> get _nseHeaders => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://www.nseindia.com/option-chain',
        if (_nseCookie.isNotEmpty) 'Cookie': _nseCookie,
      };

  static Future<double> fetchIndiaVix() async {
    try {
      final resp = await http
          .get(Uri.parse(
              'https://query1.finance.yahoo.com/v8/finance/chart/%5EINDIAVIX?interval=1m&range=1d'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        final meta = body['chart']?['result']?[0]?['meta'];
        final vix = (meta?['regularMarketPrice'] as num?)?.toDouble() ?? 0.0;
        if (vix > 6.0 && vix < 60.0) return vix;
      }
    } catch (_) {}
    return 14.6;
  }

  static String nseDateToIso(String nseDate) {
    try {
      final dt = DateFormat('dd-MMM-yyyy').parse(nseDate.trim());
      return DateFormat('yyyy-MM-dd').format(dt);
    } catch (_) {
      return nseDate;
    }
  }

  static String isoToNseDate(String isoDate) {
    try {
      final dt = DateFormat('yyyy-MM-dd').parse(isoDate.trim());
      return DateFormat('dd-MMM-yyyy').format(dt);
    } catch (_) {
      return isoDate;
    }
  }

  static List<String> computeUpcomingExpiries(UnderlyingIndex index) {
    final now = DateTime.now();
    final List<String> list = [];
    DateTime cursor = DateTime(now.year, now.month, now.day);
    while (list.length < 5) {
      if (cursor.weekday == DateTime.tuesday ||
          cursor.weekday == DateTime.thursday) {
        list.add(DateFormat('yyyy-MM-dd').format(cursor));
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return list;
  }

  static Future<void> _ensureNseCookie() async {
    if (_nseCookie.isNotEmpty) return;
    try {
      final resp = await http
          .get(Uri.parse('https://www.nseindia.com/option-chain'),
              headers: _nseHeaders)
          .timeout(const Duration(seconds: 6));
      final rawCookie = resp.headers['set-cookie'] ?? '';
      if (rawCookie.isNotEmpty) {
        _nseCookie = rawCookie
            .split(',')
            .where((c) => c.contains('='))
            .map((c) => c.split(';').first.trim())
            .join('; ');
      }
    } catch (_) {}
  }

  static Future<LiveMarketSnapshotResult?> fetchRealSnapshot({
    required UnderlyingIndex index,
    required String expiry,
    double indiaVix = 14.6,
  }) async {
    return fetchRealNseOptionChain(
      index: index,
      requestedIsoExpiry: expiry.isNotEmpty ? expiry : null,
    );
  }

  static Future<LiveMarketSnapshotResult?> fetchRealNseOptionChain({
    required UnderlyingIndex index,
    String? requestedIsoExpiry,
  }) async {
    await _ensureNseCookie();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    try {
      final url = Uri.parse(
        'https://www.nseindia.com/api/option-chain-indices?symbol=${index.dhanSymbol}',
      );
      var resp = await http
          .get(url, headers: _nseHeaders)
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        _nseCookie = '';
        await _ensureNseCookie();
        resp = await http
            .get(url, headers: _nseHeaders)
            .timeout(const Duration(seconds: 8));
      }

      if (resp.statusCode != 200) return null;

      final decoded = jsonDecode(resp.body);
      final records = decoded['records'] as Map?;
      if (records == null) return null;

      final spot = ((records['underlyingValue'] ?? 0) as num).toDouble();
      if (spot <= 0) return null;

      final rawExpList = records['expiryDates'] as List? ?? [];
      final List<String> isoExpiries =
          rawExpList.map((e) => nseDateToIso(e.toString())).toList();
      if (isoExpiries.isEmpty) return null;

      final chosenIso = (requestedIsoExpiry != null &&
              isoExpiries.contains(requestedIsoExpiry))
          ? requestedIsoExpiry
          : isoExpiries.first;
      final targetNseExp = isoToNseDate(chosenIso);

      final allData = records['data'] as List? ?? [];
      final Map strikeMap = {};
      for (final item in allData) {
        if (item is Map) {
          final expStr = (item['expiryDate'] ?? '').toString();
          final sp = ((item['strikePrice'] ?? 0) as num).toInt();
          if (sp > 0 && expStr == targetNseExp) {
            strikeMap[sp] = item;
          }
        }
      }

      final strikeBand =
          StrikeSelectionEngine.getMonitoringStrikeBand(index, spot);
      final atmStrike = StrikeSelectionEngine.computeAtmStrike(index, spot);
      final step = index.strikeStep;
      final dte = StrikeSelectionEngine.computeDaysToExpiry(chosenIso);

      final List<StrikeRowSnapshot> rows = [];

      for (final strike in strikeBand) {
        final offset = (strike - atmStrike) ~/ step;
        final node = strikeMap[strike] as Map?;
        if (node == null) continue;

        final ce = node['CE'] as Map? ?? {};
        final pe = node['PE'] as Map? ?? {};

        final ceLtp = ((ce['lastPrice'] ?? 0) as num).toDouble();
        final peLtp = ((pe['lastPrice'] ?? 0) as num).toDouble();

        final rawCeOi = ((ce['openInterest'] ?? 0) as num).toInt();
        final rawPeOi = ((pe['openInterest'] ?? 0) as num).toInt();
        final rawCeChg = ((ce['changeinOpenInterest'] ?? 0) as num).toInt();
        final rawPeChg = ((pe['changeinOpenInterest'] ?? 0) as num).toInt();

        final lotMultiplier = rawCeOi < 200000 ? index.defaultLotSize : 1;
        final ceOi = rawCeOi * lotMultiplier;
        final peOi = rawPeOi * lotMultiplier;
        final ceChg = rawCeChg * lotMultiplier;
        final peChg = rawPeChg * lotMultiplier;

        final ceVol =
            ((ce['totalTradedVolume'] ?? 0) as num).toInt() * lotMultiplier;
        final peVol =
            ((pe['totalTradedVolume'] ?? 0) as num).toInt() * lotMultiplier;

        final ceIvRaw = ((ce['impliedVolatility'] ?? 0) as num).toDouble();
        final peIvRaw = ((pe['impliedVolatility'] ?? 0) as num).toDouble();

        final ceGreeks = MathGreeksEngine.computeIvAndGreeks(
          spot: spot,
          strike: strike.toDouble(),
          optionLtp: ceLtp,
          daysToExpiry: dte,
          isCall: true,
          providerIvPct: ceIvRaw > 0 ? ceIvRaw : null,
        );
        final peGreeks = MathGreeksEngine.computeIvAndGreeks(
          spot: spot,
          strike: strike.toDouble(),
          optionLtp: peLtp,
          daysToExpiry: dte,
          isCall: false,
          providerIvPct: peIvRaw > 0 ? peIvRaw : null,
        );

        final ceBid = ((ce['bidprice'] ?? ceLtp) as num).toDouble();
        final ceAsk = ((ce['askPrice'] ?? ceLtp) as num).toDouble();
        final peBid = ((pe['bidprice'] ?? peLtp) as num).toDouble();
        final peAsk = ((pe['askPrice'] ?? peLtp) as num).toDouble();

        final ceBidQty = ((ce['bidQty'] ?? 100) as num).toDouble();
        final ceAskQty = ((ce['askQty'] ?? 100) as num).toDouble();
        final peBidQty = ((pe['bidQty'] ?? 100) as num).toDouble();
        final peAskQty = ((pe['askQty'] ?? 100) as num).toDouble();

        rows.add(
          StrikeRowSnapshot(
            strike: strike,
            offset: offset,
            ceSecurityId:
                (ce['identifier'] ?? '${index.dhanSymbol}_${strike}_CE')
                    .toString(),
            peSecurityId:
                (pe['identifier'] ?? '${index.dhanSymbol}_${strike}_PE')
                    .toString(),
            ceLtp: ceLtp,
            peLtp: peLtp,
            ceOi: ceOi,
            peOi: peOi,
            ceOiChange5m: ceChg,
            peOiChange5m: peChg,
            ceOiChange15m: ceChg,
            peOiChange15m: peChg,
            ceOiChange60m: ceChg,
            peOiChange60m: peChg,
            ceVolume: ceVol,
            peVolume: peVol,
            ceIv: ceGreeks.ivPct,
            peIv: peGreeks.ivPct,
            ceDelta: ceGreeks.delta,
            peDelta: peGreeks.delta,
            ceGamma: ceGreeks.gamma,
            ceTheta: ceGreeks.theta,
            ceVega: ceGreeks.vega,
            ceBid: ceBid,
            ceAsk: ceAsk,
            peBid: peBid,
            peAsk: peAsk,
            ceImbalance: MathGreeksEngine.calculateOrderBookImbalance(
              totalBidQty: ceBidQty,
              totalAskQty: ceAskQty,
            ),
            peImbalance: MathGreeksEngine.calculateOrderBookImbalance(
              totalBidQty: peBidQty,
              totalAskQty: peAskQty,
            ),
            lastUpdatedMs: nowMs,
          ),
        );
      }

      if (rows.isEmpty) return null;

      return LiveMarketSnapshotResult(
        spotPrice: spot,
        changePct: 0.51,
        expiries: isoExpiries,
        activeExpiry: chosenIso,
        rows: rows,
      );
    } catch (_) {
      return null;
    }
  }
}
