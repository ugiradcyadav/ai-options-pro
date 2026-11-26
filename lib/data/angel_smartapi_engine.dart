import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/http_safe_client.dart';
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
  static const _kSpApiKey = 'sp_angel_api_key_v1';
  static const _kSpClientCode = 'sp_angel_client_code_v1';
  static const _kSpOptInTotp = 'sp_angel_optin_totp_v1';

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
  bool optInTotpSaved = false;
  String jwtToken = '';
  String feedToken = '';
  String lastError = '';

  String _resolvedLocalIp = '';
  String _resolvedPublicIp = '';
  static const String _androidOsMac = '02:00:00:00:00:00';

  // Strict global 1 req / 1.15s queue for Angel One /market/v1/quote/ (prevents 403/429)
  Future<void> _quoteQueueTail = Future<void>.value();
  int _lastQuoteEndMs = 0;
  static const int _minQuoteGapMs = 1150;

  final Map<UnderlyingIndex, double> _lastSpotByIndex = {};
  final Map<String, int> _lastDbPersistMsByIndex = {};
  final Map<String, Map<String, int?>> _cachedOiDeltas = {};

  String get savedPin => _pin;
  String get savedTotpKey => _totpKey;

  Future<T> _runSerializedQuote<T>(
      Future<T> Function() action) {
    final completer = Completer<T>();
    _quoteQueueTail = _quoteQueueTail.then((_) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final waitMs = _minQuoteGapMs - (now - _lastQuoteEndMs);
      if (waitMs > 0) {
        await Future.delayed(Duration(milliseconds: waitMs));
      }
      try {
        final res = await action();
        _lastQuoteEndMs = DateTime.now().millisecondsSinceEpoch;
        if (!completer.isCompleted) completer.complete(res);
      } catch (e, st) {
        _lastQuoteEndMs = DateTime.now().millisecondsSinceEpoch;
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<String> _safeSecureRead(String key) async {
    try {
      return (await _secure.read(key: key)) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _safeSecureWrite(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: value);
      }
    } catch (_) {}
  }

  static DateTime? parseJwtExpiryUtc(String token) {
    final clean = token.trim();
    if (clean.isEmpty) return null;
    try {
      final parts = clean.split('.');
      if (parts.length != 3) return null;
      final normalized = base64Url.normalize(parts[1]);
      final jsonStr = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(jsonStr);
      if (map is Map && map['exp'] is num) {
        final expSec = (map['exp'] as num).toInt();
        return DateTime.fromMillisecondsSinceEpoch(expSec * 1000, isUtc: true);
      }
    } catch (_) {}
    return null;
  }

  static bool isJwtValid(String token, {DateTime? nowUtc}) {
    final clean = token.trim();
    if (clean.isEmpty) return false;
    final exp = parseJwtExpiryUtc(clean);
    if (exp == null) return true;
    final now = nowUtc ?? DateTime.now().toUtc();
    return now.isBefore(exp.subtract(const Duration(seconds: 60)));
  }

  bool get hasValidJwt => isJwtValid(jwtToken);

  Future<void> loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final secApi = await _safeSecureRead(_kAngelApiKey);
    final secClient = await _safeSecureRead(_kAngelClientCode);

    apiKey = secApi.isNotEmpty ? secApi : (prefs.getString(_kSpApiKey) ?? '');
    clientCode = secClient.isNotEmpty
        ? secClient
        : (prefs.getString(_kSpClientCode) ?? '');
    _pin = await _safeSecureRead(_kAngelPin);
    _totpKey = await _safeSecureRead(_kAngelTotpKey);
    optInTotpSaved =
        _totpKey.isNotEmpty || (prefs.getBool(_kSpOptInTotp) ?? false);
    jwtToken = await _safeSecureRead(_kAngelJwtToken);
    feedToken = await _safeSecureRead(_kAngelFeedToken);
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
      (hasValidJwt || (_pin.isNotEmpty && _totpKey.isNotEmpty) || _pin.isNotEmpty);

  Future<void> _ensureRealNetworkInfo() async {
    if (_resolvedLocalIp.isEmpty || _resolvedLocalIp == '127.0.0.1') {
      try {
        final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        for (final iface in ifaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback && addr.address.isNotEmpty) {
              _resolvedLocalIp = addr.address;
              break;
            }
          }
          if (_resolvedLocalIp.isNotEmpty) break;
        }
      } catch (_) {}
      if (_resolvedLocalIp.isEmpty) _resolvedLocalIp = '192.168.1.1';
    }

    if (_resolvedPublicIp.isEmpty || _resolvedPublicIp == '127.0.0.1') {
      final ipRegex = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
      for (final url in [
        'https://api4.ipify.org',
        'https://checkip.amazonaws.com',
        'https://ifconfig.me/ip',
      ]) {
        try {
          final resp = await http
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 4));
          if (resp.statusCode == 200) {
            final ip = resp.body.trim();
            if (ipRegex.hasMatch(ip)) {
              _resolvedPublicIp = ip;
              break;
            }
          }
        } catch (_) {}
      }
      if (_resolvedPublicIp.isEmpty) _resolvedPublicIp = _resolvedLocalIp;
    }
  }

  Map<String, String> _buildHeaders({bool includeAuth = true}) {
    final localIp =
        _resolvedLocalIp.isNotEmpty ? _resolvedLocalIp : '192.168.1.1';
    final publicIp =
        _resolvedPublicIp.isNotEmpty ? _resolvedPublicIp : localIp;
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      'X-UserType': 'USER',
      'X-SourceID': 'WEB',
      'X-ClientLocalIP': localIp,
      'X-ClientPublicIP': publicIp,
      'X-MACAddress': _androidOsMac,
      'X-PrivateKey': apiKey.trim(),
    };
    if (includeAuth && jwtToken.isNotEmpty) {
      h['Authorization'] = 'Bearer $jwtToken';
    }
    return h;
  }

  String _extractSafeBrokerError(http.Response resp) {
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map) {
        final code = (decoded['errorcode'] ??
                decoded['errorCode'] ??
                decoded['code'] ??
                '')
            .toString()
            .trim();
        final msg = (decoded['message'] ?? decoded['error'] ?? '')
            .toString()
            .trim();
        if (code.isNotEmpty || msg.isNotEmpty) {
          return '[Angel ${code.isNotEmpty ? code : "HTTP ${resp.statusCode}"}] $msg';
        }
      }
    } catch (_) {}
    return '[Angel HTTP ${resp.statusCode}] Quote/Auth rejected.';
  }

  Future<bool> loginAndSave({
    required String newApiKey,
    required String newClientCode,
    required String newPin,
    String newTotpSecret = '',
    String oneTimeOtp = '',
    bool optInStoreTotp = false,
    bool rememberPin = true,
  }) async {
    apiKey = newApiKey.trim();
    clientCode = newClientCode.trim().toUpperCase();
    final trimmedPin = newPin.trim();
    final cleanTotpKey =
        newTotpSecret.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSpApiKey, apiKey);
    await prefs.setString(_kSpClientCode, clientCode);
    await prefs.setBool(_kSpOptInTotp, optInStoreTotp && cleanTotpKey.isNotEmpty);

    await _safeSecureWrite(_kAngelApiKey, apiKey);
    await _safeSecureWrite(_kAngelClientCode, clientCode);

    if (rememberPin && trimmedPin.isNotEmpty) {
      _pin = trimmedPin;
      await _safeSecureWrite(_kAngelPin, _pin);
    } else if (!rememberPin) {
      _pin = '';
      await _safeSecureWrite(_kAngelPin, '');
    }

    if (optInStoreTotp && cleanTotpKey.isNotEmpty) {
      _totpKey = cleanTotpKey;
      optInTotpSaved = true;
      await _safeSecureWrite(_kAngelTotpKey, _totpKey);
    } else {
      _totpKey = '';
      optInTotpSaved = false;
      await _safeSecureWrite(_kAngelTotpKey, '');
    }

    await setSelectedBroker('ANGEL');
    final otpToUse = oneTimeOtp.trim().isNotEmpty
        ? oneTimeOtp.trim()
        : (cleanTotpKey.isNotEmpty
            ? TotpAuthManager.generateTotpCode(cleanTotpKey)
            : '');
    return ensureSession(
      forceLogin: true,
      ephemeralPin: trimmedPin,
      ephemeralOtp: otpToUse,
    );
  }

  Future<bool> ensureSession({
    bool forceLogin = false,
    String ephemeralPin = '',
    String ephemeralOtp = '',
  }) async {
    await loadSavedConfig();
    await _ensureRealNetworkInfo();

    if (!forceLogin && jwtToken.isNotEmpty && isJwtValid(jwtToken)) {
      return true;
    }

    final usePin = ephemeralPin.isNotEmpty ? ephemeralPin : _pin;
    final useOtp = ephemeralOtp.isNotEmpty
        ? ephemeralOtp
        : (_totpKey.isNotEmpty
            ? TotpAuthManager.generateTotpCode(_totpKey)
            : '');

    if (apiKey.isEmpty ||
        clientCode.isEmpty ||
        usePin.isEmpty ||
        useOtp.isEmpty) {
      lastError =
          '[Sadhu AI] Session expired — enter 6-digit OTP (or enable Auto-TOTP secret).';
      return false;
    }

    try {
      final resp = await SafeBrokerHttp.post(
        Uri.parse(
            'https://apiconnect.angelone.in/rest/auth/angelbroking/user/v1/loginByPassword'),
        headers: _buildHeaders(includeAuth: false),
        body: jsonEncode({
          'clientcode': clientCode,
          'password': usePin,
          'totp': useOtp,
          'state': 'live',
        }),
        timeout: const Duration(seconds: 10),
      );

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is Map && body['status'] == true && body['data'] != null) {
          jwtToken = (body['data']['jwtToken'] ?? '').toString();
          feedToken = (body['data']['feedToken'] ?? '').toString();
          await _safeSecureWrite(_kAngelJwtToken, jwtToken);
          await _safeSecureWrite(_kAngelFeedToken, feedToken);
          lastError = '';
          return true;
        }
        lastError = _extractSafeBrokerError(resp);
        return false;
      }
      lastError = _extractSafeBrokerError(resp);
      return false;
    } catch (_) {
      lastError = '[Sadhu AI] Network timeout connecting to Angel One.';
      return false;
    }
  }

  /// Serialized multi-exchange quote fetcher (strictly <= 50 tokens total per call, 1.15s rate limit)
  Future<List<Map<String, dynamic>>> fetchMultiExchangeQuotes(
    Map<String, List<String>> exchangeTokens,
  ) async {
    final cleaned = <String, List<String>{};
    int totalCount = 0;
    exchangeTokens.forEach((exch, toks) {
      final list = toks.where((t) => t.trim().isNotEmpty).toSet().toList();
      if (list.isNotEmpty) {
        cleaned[exch] = list;
        totalCount += list.length;
      }
    });
    if (totalCount == 0) return const [];

    await _ensureRealNetworkInfo();
    if (!hasValidJwt) {
      final ok = await ensureSession();
      if (!ok) return const [];
    }

    return _runSerializedQuote(() async {
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final resp = await SafeBrokerHttp.post(
            Uri.parse(
                'https://apiconnect.angelone.in/rest/secure/angelbroking/market/v1/quote/'),
            headers: _buildHeaders(),
            body: jsonEncode({
              'mode': 'FULL',
              'exchangeTokens': cleaned,
            }),
            timeout: const Duration(seconds: 7),
          );

          if (resp.statusCode == 200) {
            final body = jsonDecode(resp.body);
            if (body is Map && body['status'] == true) {
              final fetched = body['data']?['fetched'] as List? ?? [];
              lastError = '';
              return fetched
                  .whereType<Map>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .toList();
            }
            final errCode = (body is Map
                    ? (body['errorcode'] ?? body['errorCode'] ?? '')
                    : '')
                .toString()
                .toUpperCase();
            lastError = _extractSafeBrokerError(resp);
            if ((errCode == 'AB1010' || errCode == 'AG8001') && attempt == 0) {
              final relogged = await ensureSession(forceLogin: true);
              if (relogged) continue;
            }
            if (attempt == 0) {
              await Future.delayed(const Duration(milliseconds: 1400));
              continue;
            }
            return const <Map<String, dynamic>>[];
          }

          lastError = _extractSafeBrokerError(resp);
          if ((resp.statusCode == 403 || resp.statusCode == 429) &&
              attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 1500));
            continue;
          }
          return const <Map<String, dynamic>>[];
        } catch (e) {
          lastError = 'Angel quote error: $e';
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 1200));
            continue;
          }
          return const <Map<String, dynamic>>[];
        }
      }
      return const <Map<String, dynamic>>[];
    });
  }

  /// Serialized single-exchange batch quote fetcher (chunks of 50 tokens)
  Future<List<Map<String, dynamic>>> fetchBatchMarketQuotes({
    required String exchange,
    required List<String> tokens,
  }) async {
    if (tokens.isEmpty) return const [];
    final results = <Map<String, dynamic>>[];
    for (int start = 0; start < tokens.length; start += 50) {
      final end = (start + 50 > tokens.length) ? tokens.length : start + 50;
      final chunk = tokens.sublist(start, end);
      final batch = await fetchMultiExchangeQuotes({exchange: chunk});
      results.addAll(batch);
    }
    return results;
  }

  Future<double?> fetchRmsCapital() async {
    if (!hasValidJwt) return null;
    await _ensureRealNetworkInfo();
    try {
      final resp = await SafeBrokerHttp.get(
        Uri.parse(
            'https://apiconnect.angelone.in/rest/secure/angelbroking/user/v1/getRMS'),
        headers: _buildHeaders(),
        timeout: const Duration(seconds: 6),
      );
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

  static String spotTokenForIndex(UnderlyingIndex index) {
    switch (index) {
      case UnderlyingIndex.nifty50:
        return '99926000';
      case UnderlyingIndex.bankNifty:
        return '99926009';
      case UnderlyingIndex.finNifty:
        return '99926037';
      case UnderlyingIndex.sensex:
        return '99919000';
    }
  }

  static int normalizeAngelOiToLots(int rawOiQty, int lotSize) {
    if (rawOiQty <= 0 || lotSize <= 0) return 0;
    return (rawOiQty / lotSize).round();
  }

  Future<Map<String, dynamic>?> fetchLiveSpotAndChain({
    required UnderlyingIndex index,
    required String expiryIso,
  }) async {
    await _ensureRealNetworkInfo();
    if (!hasValidJwt) {
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

    final idxToken = spotTokenForIndex(index);
    final spotExch = index.spotExchange;
    final foExch = index.foExchange;
    double spot = _lastSpotByIndex[index] ?? 0.0;
    double changePct = 0.0;
    final exchangeTsMs = DateTime.now().millisecondsSinceEpoch;

    // First-ever poll for this index: resolve spot once so ATM strike band can be built
    if (spot <= 0) {
      final spotFetched =
          await fetchBatchMarketQuotes(exchange: spotExch, tokens: [idxToken]);
      if (spotFetched.isNotEmpty) {
        final item = spotFetched.first;
        spot = ((item['ltp'] ?? 0) as num).toDouble();
        changePct = ((item['percentChange'] ?? 0) as num).toDouble();
        if (spot > 0) _lastSpotByIndex[index] = spot;
      } else {
        if (lastError.isEmpty) {
          lastError = 'Spot quote unavailable for ${index.label}.';
        }
        return null;
      }
    }
    if (spot <= 0) return null;

    // ATM ± 10 strikes = 21 strikes x 2 = 42 option tokens + 1 spot = 43 tokens in ONE single call!
    final band =
        StrikeSelectionEngine.getMonitoringStrikeBand(index, spot, radius: 10);
    final atm = StrikeSelectionEngine.computeAtmStrike(index, spot);
    final step = index.strikeStep;
    final tYears =
        StrikeSelectionEngine.computeFractionalYearsToExpiryIst(expiryIso);

    final List<String> foTokens = [];
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
        foTokens.add(ceC.securityId);
        ceContracts[strike] = ceC;
      }
      if (peC != null) {
        foTokens.add(peC.securityId);
        peContracts[strike] = peC;
      }
    }

    if (foTokens.isEmpty) {
      lastError =
          'No contracts resolved in master for ${index.dhanSymbol} $expiryIso ($foExch).';
      return null;
    }

    // Combine Spot + Options into ONE single rate-limited REST request
    final multiPayload = <String, List<String>{
      spotExch: [idxToken],
      foExch: foTokens,
    };
    final combinedFetched = await fetchMultiExchangeQuotes(multiPayload);
    final Map<String, Map> quoteByToken = {};
    for (final f in combinedFetched) {
      final tok = (f['symbolToken'] ?? '').toString();
      if (tok.isNotEmpty) quoteByToken[tok] = f;
    }

    final liveSpotMap = quoteByToken[idxToken];
    if (liveSpotMap != null) {
      final s = ((liveSpotMap['ltp'] ?? 0) as num).toDouble();
      if (s > 0) {
        spot = s;
        _lastSpotByIndex[index] = s;
      }
      changePct = ((liveSpotMap['percentChange'] ?? changePct) as num).toDouble();
    }

    if (quoteByToken.length <= 1) return null;

    final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
    final db = ForeverDatabase.instance;
    final shouldPersistDb =
        receivedAtMs - (_lastDbPersistMsByIndex[index.label] ?? 0) >= 30000;
    if (shouldPersistDb) {
      _lastDbPersistMsByIndex[index.label] = receivedAtMs;
    }

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

      final ceDepthInfo = _extractRealDepth(ceQ['depth'] as Map?);
      final peDepthInfo = _extractRealDepth(peQ['depth'] as Map?);

      int? ceChg5, peChg5, ceChg15, peChg15, ceChg60, peChg60;
      if (shouldPersistDb || !_cachedOiDeltas.containsKey(ceC.securityId)) {
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

        ceChg5 = await db.computeRealOiChange(
            contractId: ceC.securityId,
            currentOiLots: ceOiLots,
            nowMs: receivedAtMs,
            minutesAgo: 5);
        peChg5 = await db.computeRealOiChange(
            contractId: peC.securityId,
            currentOiLots: peOiLots,
            nowMs: receivedAtMs,
            minutesAgo: 5);
        ceChg15 = await db.computeRealOiChange(
            contractId: ceC.securityId,
            currentOiLots: ceOiLots,
            nowMs: receivedAtMs,
            minutesAgo: 15);
        peChg15 = await db.computeRealOiChange(
            contractId: peC.securityId,
            currentOiLots: peOiLots,
            nowMs: receivedAtMs,
            minutesAgo: 15);
        ceChg60 = await db.computeRealOiChange(
            contractId: ceC.securityId,
            currentOiLots: ceOiLots,
            nowMs: receivedAtMs,
            minutesAgo: 60);
        peChg60 = await db.computeRealOiChange(
            contractId: peC.securityId,
            currentOiLots: peOiLots,
            nowMs: receivedAtMs,
            minutesAgo: 60);

        _cachedOiDeltas[ceC.securityId] = {
          '5': ceChg5,
          '15': ceChg15,
          '60': ceChg60,
        };
        _cachedOiDeltas[peC.securityId] = {
          '5': peChg5,
          '15': peChg15,
          '60': peChg60,
        };
      } else {
        final cMap = _cachedOiDeltas[ceC.securityId];
        final pMap = _cachedOiDeltas[peC.securityId];
        ceChg5 = cMap?['5'];
        ceChg15 = cMap?['15'];
        ceChg60 = cMap?['60'];
        peChg5 = pMap?['5'];
        peChg15 = pMap?['15'];
        peChg60 = pMap?['60'];
      }

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
