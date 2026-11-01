import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/totp_auth.dart';
import '../engine/math_greeks.dart';
import 'forever_db.dart';
import 'strike_selector.dart';

class AngelSmartApiEngine {
  static final AngelSmartApiEngine instance = AngelSmartApiEngine._();
  AngelSmartApiEngine._();

  static const _kBrokerChoice = 'selected_broker_v1';
  static const _kAngelApiKey = 'angel_api_key_v1';
  static const _kAngelClientCode = 'angel_client_code_v1';
  static const _kAngelPin = 'angel_pin_v1';
  static const _kAngelTotpSecret = 'angel_totp_secret_v1';
  static const _kAngelJwtToken = 'angel_jwt_token_v1';
  static const _kAngelFeedToken = 'angel_feed_token_v1';

  String apiKey = '';
  String clientCode = '';
  String pin = '';
  String totpSecret = '';
  String jwtToken = '';
  String feedToken = '';
  String lastError = '';

  final Map _nfoTokenCache = {};
  final Set _candlesSeeded = {};

  Future loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey = prefs.getString(_kAngelApiKey) ?? '';
    clientCode = prefs.getString(_kAngelClientCode) ?? '';
    pin = prefs.getString(_kAngelPin) ?? '';
    totpSecret = prefs.getString(_kAngelTotpSecret) ?? '';
    jwtToken = prefs.getString(_kAngelJwtToken) ?? '';
    feedToken = prefs.getString(_kAngelFeedToken) ?? '';
  }

  static Future getSelectedBroker() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBrokerChoice) ?? 'ANGEL';
  }

  static Future setSelectedBroker(String broker) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBrokerChoice, broker);
  }

  bool get isConfigured =>
      apiKey.trim().isNotEmpty &&
      clientCode.trim().isNotEmpty &&
      pin.trim().isNotEmpty &&
      totpSecret.trim().isNotEmpty;

  Map<String, String> _buildHeaders() {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-UserType': 'USER',
      'X-SourceID': 'WEB',
      'X-ClientLocalIP': '192.168.1.1',
      'X-ClientPublicIP': '106.193.147.98',
      'X-MACAddress': '02:00:00:00:00:00',
      'X-PrivateKey': apiKey.trim(),
    };
    if (jwtToken.isNotEmpty) {
      h['Authorization'] = 'Bearer $jwtToken';
    }
    return h;
  }

  Future loginAndSave({
    required String newApiKey,
    required String newClientCode,
    required String newPin,
    required String newTotpSecret,
  }) async {
    apiKey = newApiKey.trim();
    clientCode = newClientCode.trim().toUpperCase();
    pin = newPin.trim();
    totpSecret =
        newTotpSecret.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAngelApiKey, apiKey);
    await prefs.setString(_kAngelClientCode, clientCode);
    await prefs.setString(_kAngelPin, pin);
    await prefs.setString(_kAngelTotpSecret, totpSecret);
    await setSelectedBroker('ANGEL');

    return ensureSession(forceLogin: true);
  }

  Future ensureSession({bool forceLogin = false}) async {
    await loadSavedConfig();
    if (!isConfigured) {
      lastError = 'Angel One credentials not configured.';
      return false;
    }
    if (!forceLogin && jwtToken.isNotEmpty) {
      return true;
    }

    final totp = TotpAuthManager.generateTotpCode(totpSecret);
    try {
      final resp = await http
          .post(
            Uri.parse(
                'https://apiconnect.angelone.in/rest/auth/angelbroking/user/v1/loginByPassword'),
            headers: _buildHeaders(),
            body: jsonEncode({
              'clientcode': clientCode,
              'password': pin,
              'totp': totp,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is Map && body['status'] == true && body['data'] != null) {
          jwtToken = (body['data']['jwtToken'] ?? '').toString();
          feedToken = (body['data']['feedToken'] ?? '').toString();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kAngelJwtToken, jwtToken);
          await prefs.setString(_kAngelFeedToken, feedToken);
          lastError = '';
          return true;
        }
        lastError =
            'Angel One Login Error: ${body['message'] ?? body['errorcode'] ?? resp.body}';
        return false;
      }
      lastError = 'Angel HTTP ${resp.statusCode}: ${resp.body}';
      return false;
    } catch (e) {
      lastError = 'Angel Connection Error: $e';
      return false;
    }
  }

  Future fetchRmsCapital() async {
    try {
      final resp = await http
          .get(
            Uri.parse(
                'https://apiconnect.angelone.in/rest/secure/angelbroking/user/v1/getRMS'),
            headers: _buildHeaders(),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is Map && body['status'] == true && body['data'] != null) {
          final net =
              body['data']['net'] ?? body['data']['availablecash'] ?? '0';
          return double.tryParse(net.toString()) ?? 0.0;
        }
      }
    } catch (_) {}
    return null;
  }

  String _indexTokenForAngel(UnderlyingIndex index) {
    switch (index) {
      case UnderlyingIndex.nifty50:
        return '99926000';
      case UnderlyingIndex.bankNifty:
        return '99926009';
      case UnderlyingIndex.finNifty:
        return '99926037';
    }
  }

  /// Resolves strike tokens via Angel searchScrip with expiry-agnostic fallback & caching
  Future _resolveStrikeTokensViaSearch(
    UnderlyingIndex index,
    String expiryIso,
    int strike,
  ) async {
    final ceKey = '${index.dhanSymbol}_${strike}_CE';
    final peKey = '${index.dhanSymbol}_${strike}_PE';
    if (_nfoTokenCache.containsKey(ceKey) &&
        _nfoTokenCache.containsKey(peKey)) {
      return;
    }

    try {
      final dt = DateFormat('yyyy-MM-dd').parse(expiryIso);
      final ddMmmYy = DateFormat('ddMMMyy').format(dt).toUpperCase();
      final queries = [
        '${index.dhanSymbol}$ddMmmYy$strike',
        '${index.dhanSymbol} $strike',
      ];

      for (final q in queries) {
        final resp = await http
            .post(
              Uri.parse(
                  'https://apiconnect.angelone.in/rest/secure/angelbroking/order/v1/searchScrip'),
              headers: _buildHeaders(),
              body: jsonEncode({
                'exchange': 'NFO',
                'searchscrip': q,
              }),
            )
            .timeout(const Duration(seconds: 4));

        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          final dataList = body['data'] as List? ?? [];
          for (final item in dataList) {
            if (item is Map) {
              final ts = (item['tradingsymbol'] ?? '').toString().toUpperCase();
              final tok = (item['symboltoken'] ?? '').toString();
              if (ts.startsWith(index.dhanSymbol) &&
                  ts.endsWith('${strike}CE') &&
                  tok.isNotEmpty) {
                _nfoTokenCache.putIfAbsent(ceKey, () => tok);
              } else if (ts.startsWith(index.dhanSymbol) &&
                  ts.endsWith('${strike}PE') &&
                  tok.isNotEmpty) {
                _nfoTokenCache.putIfAbsent(peKey, () => tok);
              }
            }
          }
        }
        if (_nfoTokenCache.containsKey(ceKey) &&
            _nfoTokenCache.containsKey(peKey)) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 220));
      }
    } catch (_) {}
  }

  /// Fetches real 1-minute historical OHLCV bars from Angel One getCandleData API
  Future _seedAngelOneMinuteCandles({
    required UnderlyingIndex index,
    required String expiryIso,
    required int atmStrike,
    required String atmCeToken,
    required double spot,
    required StrikeRowSnapshot atmRow,
  }) async {
    if (_candlesSeeded.contains(index.label) || atmCeToken.isEmpty) return;
    try {
      final now = DateTime.now();
      final fromDt = now.subtract(const Duration(days: 3));
      final fmt = DateFormat('yyyy-MM-dd HH:mm');

      final resp = await http
          .post(
            Uri.parse(
                'https://apiconnect.angelone.in/rest/secure/angelbroking/historical/v1/getCandleData'),
            headers: _buildHeaders(),
            body: jsonEncode({
              'exchange': 'NFO',
              'symboltoken': atmCeToken,
              'interval': 'ONE_MINUTE',
              'fromdate': fmt.format(fromDt),
              'todate': fmt.format(now),
            }),
          )
          .timeout(const Duration(seconds: 6));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        final candles = body['data'] as List? ?? [];
        if (candles.isNotEmpty) {
          _candlesSeeded.add(index.label);
          final startIdx = candles.length > 40 ? candles.length - 40 : 0;
          for (int i = startIdx; i < candles.length; i++) {
            final c = candles[i] as List;
            final tsStr = c[0].toString();
            final dt = DateTime.tryParse(tsStr) ?? now;
            final o = (c[1] as num).toDouble();
            final h = (c[2] as num).toDouble();
            final l = (c[3] as num).toDouble();
            final cl = (c[4] as num).toDouble();
            final v = (c[5] as num).toInt();

            await ForeverDatabase.instance.insertOneMinBar(
              OneMinEnrichedBar(
                timestampMs: dt.millisecondsSinceEpoch,
                indexName: index.label,
                expiry: expiryIso,
                strike: atmStrike,
                optionType: 'CE',
                strikeOffset: 0,
                underlyingSpot: spot,
                open: o,
                high: h,
                low: l,
                close: cl,
                intervalVolume: v,
                absoluteOi: atmRow.ceOi,
                oiChange1m: atmRow.ceOiChange5m ~/ 5,
                oiChange5m: atmRow.ceOiChange5m,
                oiChange15m: atmRow.ceOiChange15m,
                oiChange60m: atmRow.ceOiChange60m,
                iv: atmRow.ceIv,
                delta: atmRow.ceDelta,
                gamma: atmRow.ceGamma,
                theta: atmRow.ceTheta,
                vega: atmRow.ceVega,
                spreadPct: 0.20,
                orderBookImbalance: atmRow.ceImbalance,
                next3mReturn: 0.0,
              ),
            );
          }
        }
      }
    } catch (_) {}
  }

  Future fetchLiveSpotAndChain({
    required UnderlyingIndex index,
    required String expiryIso,
  }) async {
    if (jwtToken.isEmpty) {
      final ok = await ensureSession();
      if (!ok) return null;
    }

    double spot = 0.0;
    double changePct = 0.0;
    try {
      final idxToken = _indexTokenForAngel(index);
      final spotResp = await http
          .post(
            Uri.parse(
                'https://apiconnect.angelone.in/rest/secure/angelbroking/market/v1/quote/'),
            headers: _buildHeaders(),
            body: jsonEncode({
              'mode': 'FULL',
              'exchangeTokens': {
                'NSE': [idxToken]
              }
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (spotResp.statusCode == 200) {
        final body = jsonDecode(spotResp.body);
        final fetched = body['data']?['fetched'] as List? ?? [];
        if (fetched.isNotEmpty) {
          final item = fetched.first as Map;
          spot = ((item['ltp'] ?? 0) as num).toDouble();
          changePct = ((item['percentChange'] ?? 0) as num).toDouble();
        }
      }
    } catch (_) {}

    if (spot <= 0) return null;

    final band = StrikeSelectionEngine.getMonitoringStrikeBand(index, spot);
    final atm = StrikeSelectionEngine.computeAtmStrike(index, spot);
    final step = index.strikeStep;
    final dte = StrikeSelectionEngine.computeDaysToExpiry(expiryIso);

    final List nfoTokensToQuery = [];
    final Map tokenToStrikeKey = {};
    for (final strike in band) {
      await _resolveStrikeTokensViaSearch(index, expiryIso, strike);
      for (final opt in ['CE', 'PE']) {
        final k = '${index.dhanSymbol}_${strike}_$opt';
        final tok = _nfoTokenCache[k]?.toString() ?? '';
        if (tok.isNotEmpty) {
          nfoTokensToQuery.add(tok);
          tokenToStrikeKey[tok] = '${strike}_$opt';
        }
      }
    }

    if (nfoTokensToQuery.isEmpty) return null;

    final Map quoteByStrikeOpt = {};
    try {
      final qResp = await http
          .post(
            Uri.parse(
                'https://apiconnect.angelone.in/rest/secure/angelbroking/market/v1/quote/'),
            headers: _buildHeaders(),
            body: jsonEncode({
              'mode': 'FULL',
              'exchangeTokens': {'NFO': nfoTokensToQuery}
            }),
          )
          .timeout(const Duration(seconds: 6));

      if (qResp.statusCode == 200) {
        final qBody = jsonDecode(qResp.body);
        final fetched = qBody['data']?['fetched'] as List? ?? [];
        for (final f in fetched) {
          if (f is Map) {
            final tok = (f['symbolToken'] ?? '').toString();
            final sk = tokenToStrikeKey[tok];
            if (sk != null) {
              quoteByStrikeOpt[sk] = f;
            }
          }
        }
      }
    } catch (_) {}

    if (quoteByStrikeOpt.isEmpty) return null;

    final List rows = [];
    StrikeRowSnapshot? atmRowSnap;
    String atmCeTok = '';

    for (final strike in band) {
      final offset = (strike - atm) ~/ step;
      final ceQ = quoteByStrikeOpt['${strike}_CE'] as Map? ?? {};
      final peQ = quoteByStrikeOpt['${strike}_PE'] as Map? ?? {};

      final ceLtp = ((ceQ['ltp'] ?? 0) as num).toDouble();
      final peLtp = ((peQ['ltp'] ?? 0) as num).toDouble();
      if (ceLtp <= 0 && peLtp <= 0) continue;

      final ceOi = ((ceQ['opnInterest'] ?? 0) as num).toInt();
      final peOi = ((peQ['opnInterest'] ?? 0) as num).toInt();
      final ceVol = ((ceQ['tradeVolume'] ?? 0) as num).toInt();
      final peVol = ((peQ['tradeVolume'] ?? 0) as num).toInt();

      final ceNetChg = ((ceQ['netChange'] ?? 0) as num).toDouble();
      final peNetChg = ((peQ['netChange'] ?? 0) as num).toDouble();

      // Extract real 5-level Order Book Depth from Angel FULL quote
      double ceBidQty = 100.0;
      double ceAskQty = 100.0;
      double ceBestBid = ceLtp;
      double ceBestAsk = ceLtp;
      final ceDepth = ceQ['depth'] as Map?;
      if (ceDepth != null) {
        final buyList = ceDepth['buy'] as List? ?? [];
        final sellList = ceDepth['sell'] as List? ?? [];
        if (buyList.isNotEmpty) {
          ceBestBid = ((buyList.first['price'] ?? ceLtp) as num).toDouble();
          ceBidQty = buyList.fold(
              0.0, (s, e) => s + ((e['quantity'] ?? 0) as num).toDouble());
        }
        if (sellList.isNotEmpty) {
          ceBestAsk = ((sellList.first['price'] ?? ceLtp) as num).toDouble();
          ceAskQty = sellList.fold(
              0.0, (s, e) => s + ((e['quantity'] ?? 0) as num).toDouble());
        }
      }

      double peBidQty = 100.0;
      double peAskQty = 100.0;
      double peBestBid = peLtp;
      double peBestAsk = peLtp;
      final peDepth = peQ['depth'] as Map?;
      if (peDepth != null) {
        final buyList = peDepth['buy'] as List? ?? [];
        final sellList = peDepth['sell'] as List? ?? [];
        if (buyList.isNotEmpty) {
          peBestBid = ((buyList.first['price'] ?? peLtp) as num).toDouble();
          peBidQty = buyList.fold(
              0.0, (s, e) => s + ((e['quantity'] ?? 0) as num).toDouble());
        }
        if (sellList.isNotEmpty) {
          peBestAsk = ((sellList.first['price'] ?? peLtp) as num).toDouble();
          peAskQty = sellList.fold(
              0.0, (s, e) => s + ((e['quantity'] ?? 0) as num).toDouble());
        }
      }

      final ceG = MathGreeksEngine.computeIvAndGreeks(
        spot: spot,
        strike: strike.toDouble(),
        optionLtp: ceLtp,
        daysToExpiry: dte,
        isCall: true,
      );
      final peG = MathGreeksEngine.computeIvAndGreeks(
        spot: spot,
        strike: strike.toDouble(),
        optionLtp: peLtp,
        daysToExpiry: dte,
        isCall: false,
      );

      final ceTok =
          (ceQ['symbolToken'] ?? '${index.dhanSymbol}_${strike}_CE').toString();
      final peTok =
          (peQ['symbolToken'] ?? '${index.dhanSymbol}_${strike}_PE').toString();

      final snap = StrikeRowSnapshot(
        strike: strike,
        offset: offset,
        ceSecurityId: ceTok,
        peSecurityId: peTok,
        ceLtp: ceLtp,
        peLtp: peLtp,
        ceOi: ceOi,
        peOi: peOi,
        ceOiChange5m: (ceNetChg * index.defaultLotSize * 12).round(),
        peOiChange5m: (peNetChg * index.defaultLotSize * 12).round(),
        ceOiChange15m: (ceNetChg * index.defaultLotSize * 35).round(),
        peOiChange15m: (peNetChg * index.defaultLotSize * 35).round(),
        ceOiChange60m: (ceNetChg * index.defaultLotSize * 85).round(),
        peOiChange60m: (peNetChg * index.defaultLotSize * 85).round(),
        ceVolume: ceVol,
        peVolume: peVol,
        ceIv: ceG.ivPct,
        peIv: peG.ivPct,
        ceDelta: ceG.delta,
        peDelta: peG.delta,
        ceGamma: ceG.gamma,
        ceTheta: ceG.theta,
        ceVega: ceG.vega,
        ceBid: ceBestBid,
        ceAsk: ceBestAsk,
        peBid: peBestBid,
        peAsk: peBestAsk,
        ceImbalance: MathGreeksEngine.calculateOrderBookImbalance(
          totalBidQty: ceBidQty,
          totalAskQty: ceAskQty,
        ),
        peImbalance: MathGreeksEngine.calculateOrderBookImbalance(
          totalBidQty: peBidQty,
          totalAskQty: peAskQty,
        ),
        lastUpdatedMs: DateTime.now().millisecondsSinceEpoch,
      );

      if (offset == 0) {
        atmRowSnap = snap;
        atmCeTok = ceTok;
      }
      rows.add(snap);
    }

    if (rows.isEmpty) return null;

    if (atmRowSnap != null && atmCeTok.isNotEmpty) {
      await _seedAngelOneMinuteCandles(
        index: index,
        expiryIso: expiryIso,
        atmStrike: atm,
        atmCeToken: atmCeTok,
        spot: spot,
        atmRow: atmRowSnap,
      );
    }

    return {
      'spot': spot,
      'changePct': changePct,
      'rows': rows,
    };
  }
}
