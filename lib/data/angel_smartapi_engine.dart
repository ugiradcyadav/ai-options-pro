import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/totp_auth.dart';
import '../engine/math_greeks.dart';
import 'forever_db.dart';
import 'scrip_master_engine.dart';
import 'strike_selector.dart';

class AngelSmartApiEngine {
  static final AngelSmartApiEngine instance = AngelSmartApiEngine._();
  AngelSmartApiEngine._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kBrokerChoice = 'selected_broker_v1';
  static const _kAngelApiKey = 'sec_angel_api_key';
  static const _kAngelClientCode = 'sec_angel_client_code';
  static const _kAngelPin = 'sec_angel_pin';
  static const _kAngelTotpKey = 'sec_angel_totp_key';
  static const _kAngelJwtToken = 'sec_angel_jwt_token';
  static const _kAngelFeedToken = 'sec_angel_feed_token';

  String apiKey = '';
  String clientCode = '';
  String _pin = '';
  String _totpKey = '';
  String jwtToken = '';
  String feedToken = '';
  String lastError = '';

  Future<void> loadSavedConfig() async {
    apiKey = await _secure.read(key: _kAngelApiKey) ?? '';
    clientCode = await _secure.read(key: _kAngelClientCode) ?? '';
    _pin = await _secure.read(key: _kAngelPin) ?? '';
    _totpKey = await _secure.read(key: _kAngelTotpKey) ?? '';
    jwtToken = await _secure.read(key: _kAngelJwtToken) ?? '';
    feedToken = await _secure.read(key: _kAngelFeedToken) ?? '';
  }

  static Future<String> getSelectedBroker() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBrokerChoice) ?? 'ANGEL';
  }

  static Future<void> setSelectedBroker(String broker) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBrokerChoice, broker);
  }

  bool get isConfigured =>
      apiKey.trim().isNotEmpty &&
      clientCode.trim().isNotEmpty &&
      (jwtToken.isNotEmpty || _pin.isNotEmpty || _totpKey.isNotEmpty);

  /// WP-1: Clean headers without fake hardcoded public IP or MAC address
  Map<String, String> _buildHeaders() {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Cache-Control': 'no-cache',
      'X-UserType': 'USER',
      'X-SourceID': 'WEB',
      'X-PrivateKey': apiKey.trim(),
    };
    if (jwtToken.isNotEmpty) {
      h['Authorization'] = 'Bearer $jwtToken';
    }
    return h;
  }

  /// WP-1: Never store PIN and TOTP key together. Only store TOTP key if user explicitly opts in.
  Future<bool> loginAndSave({
    required String newApiKey,
    required String newClientCode,
    required String newPin,
    String newTotpSecret = '',
    String oneTimeOtp = '',
    bool optInStoreTotp = false,
  }) async {
    apiKey = newApiKey.trim();
    clientCode = newClientCode.trim().toUpperCase();
    final cleanTotpKey =
        newTotpSecret.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');

    await _secure.write(key: _kAngelApiKey, value: apiKey);
    await _secure.write(key: _kAngelClientCode, value: clientCode);

    if (optInStoreTotp && cleanTotpKey.isNotEmpty) {
      _totpKey = cleanTotpKey;
      _pin = '';
      await _secure.write(key: _kAngelTotpKey, value: cleanTotpKey);
      await _secure.delete(key: _kAngelPin);
    } else {
      _totpKey = '';
      _pin = newPin.trim();
      await _secure.delete(key: _kAngelTotpKey);
      if (_pin.isNotEmpty) {
        await _secure.write(key: _kAngelPin, value: _pin);
      }
    }

    await setSelectedBroker('ANGEL');
    final otpToUse = oneTimeOtp.trim().isNotEmpty
        ? oneTimeOtp.trim()
        : (cleanTotpKey.isNotEmpty
            ? TotpAuthManager.generateTotpCode(cleanTotpKey)
            : '');
    return ensureSession(
      forceLogin: true,
      ephemeralPin: newPin.trim(),
      ephemeralOtp: otpToUse,
    );
  }

  Future<bool> ensureSession({
    bool forceLogin = false,
    String ephemeralPin = '',
    String ephemeralOtp = '',
  }) async {
    await loadSavedConfig();
    if (!forceLogin && jwtToken.isNotEmpty) {
      return true;
    }

    final usePin = ephemeralPin.isNotEmpty ? ephemeralPin : _pin;
    final useOtp = ephemeralOtp.isNotEmpty
        ? ephemeralOtp
        : (_totpKey.isNotEmpty
            ? TotpAuthManager.generateTotpCode(_totpKey)
            : '');

    if (apiKey.isEmpty || clientCode.isEmpty || usePin.isEmpty || useOtp.isEmpty) {
      lastError = 'Broker login requires active session or interactive OTP/PIN.';
      return false;
    }

    try {
      final resp = await http
          .post(
            Uri.parse(
                'https://apiconnect.angelone.in/rest/auth/angelbroking/user/v1/loginByPassword'),
            headers: _buildHeaders(),
            body: jsonEncode({
              'clientcode': clientCode,
              'password': usePin,
              'totp': useOtp,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is Map && body['status'] == true && body['data'] != null) {
          jwtToken = (body['data']['jwtToken'] ?? '').toString();
          feedToken = (body['data']['feedToken'] ?? '').toString();
          await _secure.write(key: _kAngelJwtToken, value: jwtToken);
          await _secure.write(key: _kAngelFeedToken, value: feedToken);
          lastError = '';
          return true;
        }
        // WP-1: Never place raw resp.body into error strings
        lastError = 'Angel One login rejected by broker.';
        return false;
      }
      lastError = 'Angel One login failed (HTTP ${resp.statusCode}).';
      return false;
    } catch (_) {
      lastError = 'Network error connecting to Angel One.';
      return false;
    }
  }

  Future<double?> fetchRmsCapital() async {
    if (jwtToken.isEmpty) return null;
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
          return double.tryParse(net.toString());
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

  /// WP-3: Normalize Angel One NFO openInterest (reported in shares/qty) into contracts (lots) using master lotSize
  static int normalizeAngelOiToLots(int rawOiQty, int lotSize) {
    if (rawOiQty <= 0 || lotSize <= 0) return 0;
    return (rawOiQty / lotSize).round();
  }

  /// WP-3 & WP-4: Fetches live NSE index spot + ATM +/- 12 NFO option chain resolved strictly from ScripMasterEngine
  Future<Map<String, dynamic>?> fetchLiveSpotAndChain({
    required UnderlyingIndex index,
    required String expiryIso,
  }) async {
    if (jwtToken.isEmpty) {
      final ok = await ensureSession();
      if (!ok) return null;
    }

    final master = ScripMasterEngine.instance;
    if (!master.isLoaded) {
      final loaded = await master.loadOrRefreshMaster();
      if (!loaded) {
        lastError = 'Instrument master unavailable: ${master.lastLoadError}';
        return null;
      }
    }

    final idxToken = _indexTokenForAngel(index);
    double spot = 0.0;
    double changePct = 0.0;
    int exchangeTsMs = DateTime.now().millisecondsSinceEpoch;

    try {
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
          .timeout(const Duration(seconds: 4));

      if (spotResp.statusCode == 200) {
        final body = jsonDecode(spotResp.body);
        final fetched = body['data']?['fetched'] as List? ?? [];
        if (fetched.isNotEmpty) {
          final item = fetched.first as Map;
          spot = ((item['ltp'] ?? 0) as num).toDouble();
          changePct = ((item['percentChange'] ?? 0) as num).toDouble();
        }
      } else {
        lastError = 'Spot quote failed (HTTP ${spotResp.statusCode}).';
        return null;
      }
    } catch (_) {
      lastError = 'Spot quote network timeout.';
      return null;
    }

    if (spot <= 0) return null;

    // Resolve ATM +/- 12 strikes strictly from ScripMasterEngine for the chosen expiryIso
    final band =
        StrikeSelectionEngine.getMonitoringStrikeBand(index, spot, radius: 12);
    final atm = StrikeSelectionEngine.computeAtmStrike(index, spot);
    final step = index.strikeStep;
    final tYears =
        StrikeSelectionEngine.computeFractionalYearsToExpiryIst(expiryIso);

    final List<String> nfoTokens = [];
    final Map<String, ResolvedContract> contractByToken = {};
    final Map<int, ResolvedContract> ceContracts = {};
    final Map<int, ResolvedContract> peContracts = {};

    for (final strike in band) {
      final ceC = master.resolveOptionContract(
        index: index,
        expiryIso: expiryIso,
        strike: strike,
        optionType: OptionType.ce,
      );
      final peC = master.resolveOptionContract(
        index: index,
        expiryIso: expiryIso,
        strike: strike,
        optionType: OptionType.pe,
      );
      if (ceC != null) {
        nfoTokens.add(ceC.securityId);
        contractByToken[ceC.securityId] = ceC;
        ceContracts[strike] = ceC;
      }
      if (peC != null) {
        nfoTokens.add(peC.securityId);
        contractByToken[peC.securityId] = peC;
        peContracts[strike] = peC;
      }
    }

    if (nfoTokens.isEmpty) {
      lastError = 'No contracts resolved in master for ${index.dhanSymbol} $expiryIso.';
      return null;
    }

    // Angel SmartAPI allows up to 50 tokens per batched FULL quote request
    final Map<String, Map> quoteByToken = {};
    for (int start = 0; start < nfoTokens.length; start += 50) {
      final end = (start + 50 > nfoTokens.length)
          ? nfoTokens.length
          : start + 50;
      final chunk = nfoTokens.sublist(start, end);
      try {
        final qResp = await http
            .post(
              Uri.parse(
                  'https://apiconnect.angelone.in/rest/secure/angelbroking/market/v1/quote/'),
              headers: _buildHeaders(),
              body: jsonEncode({
                'mode': 'FULL',
                'exchangeTokens': {'NFO': chunk}
              }),
            )
            .timeout(const Duration(seconds: 4));

        if (qResp.statusCode == 200) {
          final qBody = jsonDecode(qResp.body);
          final fetched = qBody['data']?['fetched'] as List? ?? [];
          for (final f in fetched) {
            if (f is Map) {
              final tok = (f['symbolToken'] ?? '').toString();
              if (tok.isNotEmpty) quoteByToken[tok] = f;
            }
          }
        }
      } catch (_) {}
    }

    if (quoteByToken.isEmpty) return null;

    final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
    final db = ForeverDatabase.instance;

    // Derive forward from put-call parity at ATM if both CE & PE real mid prices are present
    double? parityForward;
    final atmCeC = ceContracts[atm];
    final atmPeC = peContracts[atm];
    if (atmCeC != null && atmPeC != null) {
      final ceQ = quoteByToken[atmCeC.securityId];
      final peQ = quoteByToken[atmPeC.securityId];
      if (ceQ != null && peQ != null) {
        final cLtp = ((ceQ['ltp'] ?? 0) as num).toDouble();
        final pLtp = ((peQ['ltp'] ?? 0) as num).toDouble();
        if (cLtp > 0 && pLtp > 0 && tYears > 0) {
          parityForward = MathGreeksEngine.deriveForwardFromParity(
            spot: spot,
            atmStrike: atm.toDouble(),
            atmCallMid: cLtp,
            atmPutMid: pLtp,
            timeYears: tYears,
          );
        }
      }
    }

    final rows = <StrikeRowSnapshot>[];
    for (final strike in band) {
      final ceC = ceContracts[strike];
      final peC = peContracts[strike];
      if (ceC == null || peC == null) continue;

      final ceQ = quoteByToken[ceC.securityId];
      final peQ = quoteByToken[peC.securityId];
      if (ceQ == null || peQ == null) continue;

      final ceLtp = ((ceQ['ltp'] ?? 0) as num).toDouble();
      final peLtp = ((peQ['ltp'] ?? 0) as num).toDouble();
      if (ceLtp <= 0 && peLtp <= 0) continue;

      final lotSize = ceC.lotSize;
      final ceOiLots = normalizeAngelOiToLots(
          ((ceQ['opnInterest'] ?? 0) as num).toInt(), lotSize);
      final peOiLots = normalizeAngelOiToLots(
          ((peQ['opnInterest'] ?? 0) as num).toInt(), lotSize);
      final ceVol = ((ceQ['tradeVolume'] ?? 0) as num).toInt();
      final peVol = ((peQ['tradeVolume'] ?? 0) as num).toInt();

      // WP-2: Extract real depth bid/ask/qty only; keep null when absent (never default to LTP or 100.0)
      final ceDepthInfo = _extractRealDepth(ceQ['depth'] as Map?);
      final peDepthInfo = _extractRealDepth(peQ['depth'] as Map?);

      // WP-3: Persist raw 1-minute snapshots & compute real OI diffs (null until history exists)
      await db.insertChainSnapshot(
        contractId: ceC.securityId,
        indexName: index.label,
        expiry: expiryIso,
        strike: strike,
        optionType: 'CE',
        timestampMs: receivedAtMs,
        ltp: ceLtp,
        bid: ceDepthInfo['bid'] as double?,
        ask: ceDepthInfo['ask'] as double?,
        volume: ceVol,
        oiLots: ceOiLots,
        source: 'ANGEL_SMARTAPI',
      );
      await db.insertChainSnapshot(
        contractId: peC.securityId,
        indexName: index.label,
        expiry: expiryIso,
        strike: strike,
        optionType: 'PE',
        timestampMs: receivedAtMs,
        ltp: peLtp,
        bid: peDepthInfo['bid'] as double?,
        ask: peDepthInfo['ask'] as double?,
        volume: peVol,
        oiLots: peOiLots,
        source: 'ANGEL_SMARTAPI',
      );

      final ceChg5 = await db.computeRealOiChange(
          contractId: ceC.securityId,
          currentOiLots: ceOiLots,
          nowMs: receivedAtMs,
          minutesAgo: 5);
      final peChg5 = await db.computeRealOiChange(
          contractId: peC.securityId,
          currentOiLots: peOiLots,
          nowMs: receivedAtMs,
          minutesAgo: 5);
      final ceChg15 = await db.computeRealOiChange(
          contractId: ceC.securityId,
          currentOiLots: ceOiLots,
          nowMs: receivedAtMs,
          minutesAgo: 15);
      final peChg15 = await db.computeRealOiChange(
          contractId: peC.securityId,
          currentOiLots: peOiLots,
          nowMs: receivedAtMs,
          minutesAgo: 15);
      final ceChg60 = await db.computeRealOiChange(
          contractId: ceC.securityId,
          currentOiLots: ceOiLots,
          nowMs: receivedAtMs,
          minutesAgo: 60);
      final peChg60 = await db.computeRealOiChange(
          contractId: peC.securityId,
          currentOiLots: peOiLots,
          nowMs: receivedAtMs,
          minutesAgo: 60);

      final dteDays = tYears * 365.0;
      final ceG = MathGreeksEngine.computeIvAndGreeks(
        spot: spot,
        strike: strike.toDouble(),
        optionLtp: ceLtp,
        daysToExpiry: dteDays,
        isCall: true,
        bidPrice: ceDepthInfo['bid'] as double?,
        askPrice: ceDepthInfo['ask'] as double?,
        forwardPriceOverride: parityForward,
      );
      final peG = MathGreeksEngine.computeIvAndGreeks(
        spot: spot,
        strike: strike.toDouble(),
        optionLtp: peLtp,
        daysToExpiry: dteDays,
        isCall: false,
        bidPrice: peDepthInfo['bid'] as double?,
        askPrice: peDepthInfo['ask'] as double?,
        forwardPriceOverride: parityForward,
      );

      final ceBidQty = ceDepthInfo['bidQty'] as int;
      final ceAskQty = ceDepthInfo['askQty'] as int;
      final peBidQty = peDepthInfo['bidQty'] as int;
      final peAskQty = peDepthInfo['askQty'] as int;

      final offset = (strike - atm) ~/ step;
      rows.add(
        StrikeRowSnapshot(
          strike: strike,
          offset: offset,
          ceSecurityId: ceC.securityId,
          peSecurityId: peC.securityId,
          ceTradingSymbol: ceC.tradingSymbol,
          peTradingSymbol: peC.tradingSymbol,
          lotSize: lotSize,
          ceLtp: ceLtp,
          peLtp: peLtp,
          ceOi: ceOiLots,
          peOi: peOiLots,
          ceOiChange5m: ceChg5,
          peOiChange5m: peChg5,
          ceOiChange15m: ceChg15,
          peOiChange15m: peChg15,
          ceOiChange60m: ceChg60,
          peOiChange60m: peChg60,
          ceVolume: ceVol,
          peVolume: peVol,
          ceIv: ceG.rawSolvedIv != null ? ceG.ivPct : null,
          peIv: peG.rawSolvedIv != null ? peG.ivPct : null,
          ceDelta: ceG.delta,
          peDelta: peG.delta,
          ceGamma: ceG.gamma,
          peGamma: peG.gamma,
          ceTheta: ceG.theta,
          peTheta: peG.theta,
          ceVega: ceG.vega,
          peVega: peG.vega,
          ceBid: ceDepthInfo['bid'] as double?,
          ceAsk: ceDepthInfo['ask'] as double?,
          peBid: peDepthInfo['bid'] as double?,
          peAsk: peDepthInfo['ask'] as double?,
          ceBidQty: ceBidQty,
          ceAskQty: ceAskQty,
          peBidQty: peBidQty,
          peAskQty: peAskQty,
          ceImbalance: (ceBidQty + ceAskQty) > 0
              ? MathGreeksEngine.calculateOrderBookImbalance(
                  totalBidQty: ceBidQty.toDouble(),
                  totalAskQty: ceAskQty.toDouble(),
                )
              : null,
          peImbalance: (peBidQty + peAskQty) > 0
              ? MathGreeksEngine.calculateOrderBookImbalance(
                  totalBidQty: peBidQty.toDouble(),
                  totalAskQty: peAskQty.toDouble(),
                )
              : null,
          source: 'ANGEL_SMARTAPI',
          exchangeTimestampMs: exchangeTsMs,
          receivedAtMs: receivedAtMs,
        ),
      );
    }

    return {
      'spot': spot,
      'changePct': changePct,
      'rows': rows,
      'receivedAtMs': receivedAtMs,
      'source': 'ANGEL_SMARTAPI',
    };
  }

  static Map<String, dynamic> _extractRealDepth(Map? depth) {
    if (depth == null) {
      return {'bid': null, 'ask': null, 'bidQty': 0, 'askQty': 0};
    }
    final buyList = depth['buy'] as List? ?? const [];
    final sellList = depth['sell'] as List? ?? const [];

    double? bestBid;
    int totalBidQty = 0;
    if (buyList.isNotEmpty && buyList.first is Map) {
      final p = ((buyList.first['price'] ?? 0) as num).toDouble();
      if (p > 0) bestBid = p;
      for (final e in buyList) {
        if (e is Map) totalBidQty += ((e['quantity'] ?? 0) as num).toInt();
      }
    }

    double? bestAsk;
    int totalAskQty = 0;
    if (sellList.isNotEmpty && sellList.first is Map) {
      final p = ((sellList.first['price'] ?? 0) as num).toDouble();
      if (p > 0) bestAsk = p;
      for (final e in sellList) {
        if (e is Map) totalAskQty += ((e['quantity'] ?? 0) as num).toInt();
      }
    }

    return {
      'bid': bestBid,
      'ask': bestAsk,
      'bidQty': totalBidQty,
      'askQty': totalAskQty,
    };
  }
}
