import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/models.dart';
import '../core/totp_auth.dart';
import '../engine/math_greeks.dart';
import 'forever_db.dart';
import 'strike_selector.dart';

class _MinuteAccumulator {
  final int minuteBucketMs;
  double open;
  double high;
  double low;
  double close;
  int startCumulativeVol;
  int latestCumulativeVol;
  int latestOi;
  double latestSpot;
  double iv;
  double delta;
  double gamma;
  double theta;
  double vega;
  double spreadPct;
  double obImbalance;

  _MinuteAccumulator({
    required this.minuteBucketMs,
    required double initialPrice,
    required int initialVol,
    required int initialOi,
    required this.latestSpot,
    required this.iv,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    required this.spreadPct,
    required this.obImbalance,
  })  : open = initialPrice,
        high = initialPrice,
        low = initialPrice,
        close = initialPrice,
        startCumulativeVol = initialVol,
        latestCumulativeVol = initialVol,
        latestOi = initialOi;

  void update({
    required double price,
    required int cumulativeVol,
    required int oi,
    required double spot,
    required double newIv,
    required double newDelta,
    required double newGamma,
    required double newTheta,
    required double newVega,
    required double newSpreadPct,
    required double newImbalance,
  }) {
    if (price > high) high = price;
    if (price < low && price > 0) low = price;
    if (price > 0) close = price;
    if (cumulativeVol >= latestCumulativeVol) {
      latestCumulativeVol = cumulativeVol;
    }
    if (oi > 0) latestOi = oi;
    if (spot > 0) latestSpot = spot;
    iv = newIv;
    delta = newDelta;
    gamma = newGamma;
    theta = newTheta;
    vega = newVega;
    spreadPct = newSpreadPct;
    obImbalance = newImbalance;
  }
}

class DhanDataEngine {
  static final DhanDataEngine instance = DhanDataEngine._();
  DhanDataEngine._();

  DhanCredentials? _credentials;
  WebSocketChannel? _wsChannel;
  Timer? _pollTimer;
  Timer? _reconnectTimer;

  bool isConnected = false;
  int lastSyncTimestampMs = 0;
  double dataDelaySec = 0.0;
  int missingDataCount = 0;
  double availableTradingCapital = 0.0;
  String connectionStatusText = 'Disconnected';

  final Map<UnderlyingIndex, double> spotPrices = {
    UnderlyingIndex.nifty50: 0.0,
    UnderlyingIndex.bankNifty: 0.0,
    UnderlyingIndex.finNifty: 0.0,
  };

  final Map<UnderlyingIndex, double> spotChangePct = {
    UnderlyingIndex.nifty50: 0.0,
    UnderlyingIndex.bankNifty: 0.0,
    UnderlyingIndex.finNifty: 0.0,
  };

  final Map<UnderlyingIndex, List<String>> availableExpiries = {
    UnderlyingIndex.nifty50: [],
    UnderlyingIndex.bankNifty: [],
    UnderlyingIndex.finNifty: [],
  };

  final Map<UnderlyingIndex, String> selectedExpiry = {
    UnderlyingIndex.nifty50: '',
    UnderlyingIndex.bankNifty: '',
    UnderlyingIndex.finNifty: '',
  };

  final Map<UnderlyingIndex, List<StrikeRowSnapshot>> optionChainRows = {
    UnderlyingIndex.nifty50: [],
    UnderlyingIndex.bankNifty: [],
    UnderlyingIndex.finNifty: [],
  };

  /// O(1) Sliding Window of last 65 minutes of OI per contract key ('INDEX_STRIKE_TYPE')
  final Map<String, ListQueue<MapEntry<int, int>>> _oiSlidingWindow = {};

  /// Active 1-minute candle accumulators per contract key
  final Map<String, _MinuteAccumulator> _activeMinuteBars = {};

  /// Callback triggered whenever new market data arrives or 1m bar closes
  void Function()? onDataUpdated;
  void Function(UnderlyingIndex index, List<OneMinEnrichedBar> closedBars)?
      onOneMinuteCandleClosed;

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'access-token': _credentials?.accessToken ?? '',
        'client-id': _credentials?.clientId ?? '',
      };

  /// Connects to Dhan API, validates session, fetches expiries, and starts live feed
  Future<bool> initializeAndStart() async {
    _credentials = await TotpAuthManager.ensureValidSession();
    if (_credentials == null || !_credentials!.isConfigured) {
      isConnected = false;
      connectionStatusText = 'API Credentials Required';
      onDataUpdated?.call();
      return false;
    }

    final valid = await fetchFundLimits();
    if (!valid) {
      isConnected = false;
      connectionStatusText = TotpAuthManager.lastServerMessage.isNotEmpty ? TotpAuthManager.lastServerMessage : 'Auth Failed: Verify Token or TOTP+PIN';
      onDataUpdated?.call();
      return false;
    }

    isConnected = true;
    connectionStatusText = 'Dhan Connected';
    lastSyncTimestampMs = DateTime.now().millisecondsSinceEpoch;

    for (final idx in UnderlyingIndex.values) {
      await fetchExpiriesForIndex(idx);
      await fetchOptionChainSnapshot(idx);
    }

    _startWebSocketFeed();
    _startSynchronizedChainPoller();
    onDataUpdated?.call();
    return true;
  }

  /// Verifies token and gets real Available Capital from Dhan `/v2/fundlimit`
  Future<bool> fetchFundLimits() async {
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final resp = await http
          .get(Uri.parse('https://api.dhan.co/v2/fundlimit'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      final t1 = DateTime.now().millisecondsSinceEpoch;
      dataDelaySec = ((t1 - t0) / 1000.0).clamp(0.05, 9.9);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        availableTradingCapital =
            ((data['availabelBalance'] ?? data['availableBalance'] ?? 0) as num)
                .toDouble();
        lastSyncTimestampMs = t1;
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Fetches real active expiries for NIFTY, BANKNIFTY, FINNIFTY
  Future<void> fetchExpiriesForIndex(UnderlyingIndex index) async {
    try {
      final resp = await http
          .post(
            Uri.parse('https://api.dhan.co/v2/optionchain/expirylist'),
            headers: _headers,
            body: jsonEncode({
              'UnderlyingScrip': index.securityId,
              'UnderlyingSeg': 'IDX_I',
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        final list = (decoded['data'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [];
        if (list.isNotEmpty) {
          availableExpiries[index] = list;
          if ((selectedExpiry[index] ?? '').isEmpty ||
              !list.contains(selectedExpiry[index])) {
            selectedExpiry[index] = list.first;
          }
        }
      }
    } catch (_) {
      missingDataCount++;
    }
  }

  /// Fetches Option Chain Snapshot for selected index & expiry, filters to ATM±2 band,
  /// updates O(1) OI sliding window, and commits 1-minute Forever bars on minute boundary.
  Future<void> fetchOptionChainSnapshot(UnderlyingIndex index) async {
    final expiry = selectedExpiry[index] ?? '';
    if (expiry.isEmpty) return;

    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final resp = await http
          .post(
            Uri.parse('https://api.dhan.co/v2/optionchain'),
            headers: _headers,
            body: jsonEncode({
              'UnderlyingScrip': index.securityId,
              'UnderlyingSeg': 'IDX_I',
              'Expiry': expiry,
            }),
          )
          .timeout(const Duration(seconds: 8));

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      dataDelaySec = ((nowMs - t0) / 1000.0).clamp(0.05, 9.9);

      if (resp.statusCode != 200) {
        missingDataCount++;
        return;
      }

      final body = jsonDecode(resp.body);
      final dataNode = body['data'] ?? body;
      final lastPrice =
          ((dataNode['last_price'] ?? dataNode['underlyingLtp'] ?? 0) as num)
              .toDouble();
      if (lastPrice <= 0) return;

      final prevSpot = spotPrices[index] ?? lastPrice;
      spotPrices[index] = lastPrice;
      if (prevSpot > 0) {
        spotChangePct[index] = ((lastPrice - prevSpot) / prevSpot) * 100.0;
      }

      final ocMap = dataNode['oc'] as Map<String, dynamic>? ?? {};
      final strikeBand =
          StrikeSelectionEngine.getMonitoringStrikeBand(index, lastPrice);
      final atmStrike =
          StrikeSelectionEngine.computeAtmStrike(index, lastPrice);
      final step = index.strikeStep;
      final dte = StrikeSelectionEngine.computeDaysToExpiry(expiry);

      final updatedRows = <StrikeRowSnapshot>[];
      final closedBarsThisMinute = <OneMinEnrichedBar>[];

      for (final strike in strikeBand) {
        final offset = (strike - atmStrike) ~/ step;
        final strikeKey =
            ocMap.containsKey(strike.toStringAsFixed(6))
                ? strike.toStringAsFixed(6)
                : (ocMap.containsKey('$strike.000000')
                    ? '$strike.000000'
                    : strike.toString());

        final strikeNode = ocMap[strikeKey] as Map<String, dynamic>? ?? {};
        final ceNode = strikeNode['ce'] as Map<String, dynamic>? ?? {};
        final peNode = strikeNode['pe'] as Map<String, dynamic>? ?? {};

        final ceLtp = ((ceNode['last_price'] ?? 0) as num).toDouble();
        final peLtp = ((peNode['last_price'] ?? 0) as num).toDouble();
        final ceOi = ((ceNode['oi'] ?? 0) as num).toInt();
        final peOi = ((peNode['oi'] ?? 0) as num).toInt();
        final ceVol = ((ceNode['volume'] ?? 0) as num).toInt();
        final peVol = ((peNode['volume'] ?? 0) as num).toInt();

        final ceBid = ((ceNode['top_bid_price'] ?? ceLtp) as num).toDouble();
        final ceAsk = ((ceNode['top_ask_price'] ?? ceLtp) as num).toDouble();
        final peBid = ((peNode['top_bid_price'] ?? peLtp) as num).toDouble();
        final peAsk = ((peNode['top_ask_price'] ?? peLtp) as num).toDouble();

        final ceBidQty =
            ((ceNode['top_bid_quantity'] ?? 100) as num).toDouble();
        final ceAskQty =
            ((ceNode['top_ask_quantity'] ?? 100) as num).toDouble();
        final peBidQty =
            ((peNode['top_bid_quantity'] ?? 100) as num).toDouble();
        final peAskQty =
            ((peNode['top_ask_quantity'] ?? 100) as num).toDouble();

        final ceGreeksNode =
            ceNode['greeks'] as Map<String, dynamic>? ?? const {};
        final peGreeksNode =
            peNode['greeks'] as Map<String, dynamic>? ?? const {};

        final ceGreeks = MathGreeksEngine.computeIvAndGreeks(
          spot: lastPrice,
          strike: strike.toDouble(),
          optionLtp: ceLtp,
          daysToExpiry: dte,
          isCall: true,
          providerIvPct: (ceNode['implied_volatility'] as num?)?.toDouble(),
          providerDelta: (ceGreeksNode['delta'] as num?)?.toDouble(),
          providerGamma: (ceGreeksNode['gamma'] as num?)?.toDouble(),
          providerTheta: (ceGreeksNode['theta'] as num?)?.toDouble(),
          providerVega: (ceGreeksNode['vega'] as num?)?.toDouble(),
        );

        final peGreeks = MathGreeksEngine.computeIvAndGreeks(
          spot: lastPrice,
          strike: strike.toDouble(),
          optionLtp: peLtp,
          daysToExpiry: dte,
          isCall: false,
          providerIvPct: (peNode['implied_volatility'] as num?)?.toDouble(),
          providerDelta: (peGreeksNode['delta'] as num?)?.toDouble(),
          providerGamma: (peGreeksNode['gamma'] as num?)?.toDouble(),
          providerTheta: (peGreeksNode['theta'] as num?)?.toDouble(),
          providerVega: (peGreeksNode['vega'] as num?)?.toDouble(),
        );

        final ceImb = MathGreeksEngine.calculateOrderBookImbalance(
          totalBidQty: ceBidQty,
          totalAskQty: ceAskQty,
        );
        final peImb = MathGreeksEngine.calculateOrderBookImbalance(
          totalBidQty: peBidQty,
          totalAskQty: peAskQty,
        );

        final ceKey = '${index.label}_${strike}_CE';
        final peKey = '${index.label}_${strike}_PE';

        _recordOiObservation(ceKey, nowMs, ceOi);
        _recordOiObservation(peKey, nowMs, peOi);

        final ceOi1m = _computeOiDelta(ceKey, nowMs, 1);
        final ceOi5m = _computeOiDelta(ceKey, nowMs, 5);
        final ceOi15m = _computeOiDelta(ceKey, nowMs, 15);
        final ceOi60m = _computeOiDelta(ceKey, nowMs, 60);

        final peOi1m = _computeOiDelta(peKey, nowMs, 1);
        final peOi5m = _computeOiDelta(peKey, nowMs, 5);
        final peOi15m = _computeOiDelta(peKey, nowMs, 15);
        final peOi60m = _computeOiDelta(peKey, nowMs, 60);

        updatedRows.add(
          StrikeRowSnapshot(
            strike: strike,
            offset: offset,
            ceSecurityId: (ceNode['security_id'] ?? '${index.dhanSymbol}_${strike}_CE').toString(),
            peSecurityId: (peNode['security_id'] ?? '${index.dhanSymbol}_${strike}_PE').toString(),
            ceLtp: ceLtp,
            peLtp: peLtp,
            ceOi: ceOi,
            peOi: peOi,
            ceOiChange5m: ceOi5m,
            peOiChange5m: peOi5m,
            ceOiChange15m: ceOi15m,
            peOiChange15m: peOi15m,
            ceOiChange60m: ceOi60m,
            peOiChange60m: peOi60m,
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
            ceImbalance: ceImb,
            peImbalance: peImb,
            lastUpdatedMs: nowMs,
          ),
        );

        // Process 1-minute candle accumulation for active buyer contracts
        if (StrikeSelectionEngine.isInActiveBuyerSignalBand(
          strikeOffset: offset,
          optionType: OptionType.ce,
        )) {
          final closedCe = await _updateMinuteAccumulator(
            key: ceKey,
            nowMs: nowMs,
            indexName: index.label,
            expiry: expiry,
            strike: strike,
            optionType: 'CE',
            offset: offset,
            spot: lastPrice,
            ltp: ceLtp,
            cumulativeVol: ceVol,
            oi: ceOi,
            oi1m: ceOi1m,
            oi5m: ceOi5m,
            oi15m: ceOi15m,
            oi60m: ceOi60m,
            greeks: ceGreeks,
            spreadPct: MathGreeksEngine.calculateSpreadPct(
              bid: ceBid,
              ask: ceAsk,
              ltp: ceLtp,
            ),
            imbalance: ceImb,
          );
          if (closedCe != null) closedBarsThisMinute.add(closedCe);
        }

        if (StrikeSelectionEngine.isInActiveBuyerSignalBand(
          strikeOffset: offset,
          optionType: OptionType.pe,
        )) {
          final closedPe = await _updateMinuteAccumulator(
            key: peKey,
            nowMs: nowMs,
            indexName: index.label,
            expiry: expiry,
            strike: strike,
            optionType: 'PE',
            offset: offset,
            spot: lastPrice,
            ltp: peLtp,
            cumulativeVol: peVol,
            oi: peOi,
            oi1m: peOi1m,
            oi5m: peOi5m,
            oi15m: peOi15m,
            oi60m: peOi60m,
            greeks: peGreeks,
            spreadPct: MathGreeksEngine.calculateSpreadPct(
              bid: peBid,
              ask: peAsk,
              ltp: peLtp,
            ),
            imbalance: peImb,
          );
          if (closedPe != null) closedBarsThisMinute.add(closedPe);
        }
      }

      optionChainRows[index] = updatedRows;
      lastSyncTimestampMs = nowMs;
      isConnected = true;
      connectionStatusText = 'Dhan Connected';
      onDataUpdated?.call();

      if (closedBarsThisMinute.isNotEmpty) {
        onOneMinuteCandleClosed?.call(index, closedBarsThisMinute);
      }
    } catch (_) {
      missingDataCount++;
    }
  }

  void _recordOiObservation(String key, int timestampMs, int oi) {
    if (oi <= 0) return;
    final q = _oiSlidingWindow.putIfAbsent(key, () => ListQueue());
    q.addLast(MapEntry(timestampMs, oi));
    final cutoff = timestampMs - (65 * 60 * 1000);
    while (q.length > 2 && q.first.key < cutoff) {
      q.removeFirst();
    }
  }

  int _computeOiDelta(String key, int nowMs, int lookbackMinutes) {
    final q = _oiSlidingWindow[key];
    if (q == null || q.isEmpty) return 0;
    final currentOi = q.last.value;
    final targetTime = nowMs - (lookbackMinutes * 60 * 1000);

    int referenceOi = q.first.value;
    for (final entry in q) {
      if (entry.key <= targetTime) {
        referenceOi = entry.value;
      } else {
        break;
      }
    }
    return currentOi - referenceOi;
  }

  Future<OneMinEnrichedBar?> _updateMinuteAccumulator({
    required String key,
    required int nowMs,
    required String indexName,
    required String expiry,
    required int strike,
    required String optionType,
    required int offset,
    required double spot,
    required double ltp,
    required int cumulativeVol,
    required int oi,
    required int oi1m,
    required int oi5m,
    required int oi15m,
    required int oi60m,
    required OptionGreeksResult greeks,
    required double spreadPct,
    required double imbalance,
  }) async {
    if (ltp <= 0) return null;
    final bucketMs = (nowMs ~/ 60000) * 60000;
    final existing = _activeMinuteBars[key];

    if (existing == null) {
      _activeMinuteBars[key] = _MinuteAccumulator(
        minuteBucketMs: bucketMs,
        initialPrice: ltp,
        initialVol: cumulativeVol,
        initialOi: oi,
        latestSpot: spot,
        iv: greeks.ivPct,
        delta: greeks.delta,
        gamma: greeks.gamma,
        theta: greeks.theta,
        vega: greeks.vega,
        spreadPct: spreadPct,
        obImbalance: imbalance,
      );
      return null;
    }

    if (existing.minuteBucketMs == bucketMs) {
      existing.update(
        price: ltp,
        cumulativeVol: cumulativeVol,
        oi: oi,
        spot: spot,
        newIv: greeks.ivPct,
        newDelta: greeks.delta,
        newGamma: greeks.gamma,
        newTheta: greeks.theta,
        newVega: greeks.vega,
        newSpreadPct: spreadPct,
        newImbalance: imbalance,
      );
      return null;
    }

    // Minute boundary crossed -> finalize previous 1m bar and store in Foreverite DB
    final intervalVol =
        (existing.latestCumulativeVol - existing.startCumulativeVol)
            .clamp(0, 100000000);
    final closedBar = OneMinEnrichedBar(
      timestampMs: existing.minuteBucketMs,
      indexName: indexName,
      expiry: expiry,
      strike: strike,
      optionType: optionType,
      strikeOffset: offset,
      underlyingSpot: existing.latestSpot,
      open: existing.open,
      high: existing.high,
      low: existing.low,
      close: existing.close,
      intervalVolume: intervalVol,
      absoluteOi: existing.latestOi,
      oiChange1m: oi1m,
      oiChange5m: oi5m,
      oiChange15m: oi15m,
      oiChange60m: oi60m,
      iv: existing.iv,
      delta: existing.delta,
      gamma: existing.gamma,
      theta: existing.theta,
      vega: existing.vega,
      spreadPct: existing.spreadPct,
      orderBookImbalance: existing.obImbalance,
    );

    await ForeverDatabase.instance.insertOneMinBar(closedBar);

    _activeMinuteBars[key] = _MinuteAccumulator(
      minuteBucketMs: bucketMs,
      initialPrice: ltp,
      initialVol: cumulativeVol,
      initialOi: oi,
      latestSpot: spot,
      iv: greeks.ivPct,
      delta: greeks.delta,
      gamma: greeks.gamma,
      theta: greeks.theta,
      vega: greeks.vega,
      spreadPct: spreadPct,
      obImbalance: imbalance,
    );

    return closedBar;
  }

  /// Connects to Dhan v2 Binary WebSocket for sub-second index spot ticks
  void _startWebSocketFeed() {
    _wsChannel?.sink.close();
    if (_credentials == null || !_credentials!.isConfigured) return;

    try {
      final wsUrl = Uri.parse(
        'wss://api-feed.dhan.co?version=2&token=${Uri.encodeComponent(_credentials!.accessToken)}&clientId=${Uri.encodeComponent(_credentials!.clientId)}&authType=2',
      );
      _wsChannel = WebSocketChannel.connect(wsUrl);

      final subPayload = {
        'RequestCode': 15,
        'InstrumentCount': 3,
        'InstrumentList': [
          {'ExchangeSegment': 'IDX_I', 'SecurityId': '13'},
          {'ExchangeSegment': 'IDX_I', 'SecurityId': '25'},
          {'ExchangeSegment': 'IDX_I', 'SecurityId': '27'},
        ],
      };
      _wsChannel!.sink.add(jsonEncode(subPayload));

      _wsChannel!.stream.listen(
        (event) {
          if (event is List<int> && event.length >= 16) {
            final bd = ByteData.sublistView(Uint8List.fromList(event));
            final packetCode = bd.getUint8(0);
            final secId = bd.getInt32(4, Endian.little);
            if (packetCode == 2 || packetCode == 4 || packetCode == 8) {
              final ltp = bd.getFloat32(8, Endian.little).toDouble();
              if (ltp > 0) {
                for (final idx in UnderlyingIndex.values) {
                  if (idx.securityId == secId) {
                    spotPrices[idx] = ltp;
                    lastSyncTimestampMs = DateTime.now().millisecondsSinceEpoch;
                    onDataUpdated?.call();
                  }
                }
              }
            }
          }
        },
        onError: (_) => _scheduleReconnect(),
        onDone: () => _scheduleReconnect(),
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (isConnected) _startWebSocketFeed();
    });
  }

  /// Cycles through NIFTY 50, BANK NIFTY, FINNIFTY respecting Dhan's 3-second rate limit
  void _startSynchronizedChainPoller() {
    _pollTimer?.cancel();
    int cycleIdx = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      final index = UnderlyingIndex.values[cycleIdx % UnderlyingIndex.values.length];
      cycleIdx++;
      await fetchOptionChainSnapshot(index);
    });
  }

  /// Submits a real BUY CE / BUY PE entry or long-exit SELL order to Dhan `/v2/orders`
  Future<TradeOrder> placeLiveBrokerOrder({
    required String securityId,
    required UnderlyingIndex index,
    required String expiry,
    required int strike,
    required String optionType,
    required String transactionType, // 'BUY' or 'SELL' (only for closing existing long)
    required int quantity,
    required double price,
    required String reason,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    try {
      final payload = {
        'dhanClientId': _credentials?.clientId ?? '',
        'transactionType': transactionType,
        'exchangeSegment': 'NSE_FNO',
        'productType': 'INTRADAY',
        'orderType': 'MARKET',
        'validity': 'DAY',
        'securityId': securityId,
        'quantity': quantity,
        'price': 0,
      };

      final resp = await http
          .post(
            Uri.parse('https://api.dhan.co/v2/orders'),
            headers: _headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final orderId = (data['orderId'] ?? 'DHAN_$nowMs').toString();
        final status = (data['orderStatus'] ?? 'Filled').toString();
        final order = TradeOrder(
          orderId: orderId,
          timestampMs: nowMs,
          indexName: index.label,
          expiry: expiry,
          strike: strike,
          optionType: optionType,
          side: transactionType,
          quantity: quantity,
          price: price,
          status: status == 'TRANSIT' || status == 'TRADED' ? 'Filled' : status,
          mode: 'LIVE',
          reason: reason,
        );
        await ForeverDatabase.instance.saveOrder(order);
        await fetchFundLimits();
        return order;
      } else {
        final rejected = TradeOrder(
          orderId: 'REJ_$nowMs',
          timestampMs: nowMs,
          indexName: index.label,
          expiry: expiry,
          strike: strike,
          optionType: optionType,
          side: transactionType,
          quantity: quantity,
          price: price,
          status: 'Rejected',
          mode: 'LIVE',
          reason: 'Broker HTTP ${resp.statusCode}',
        );
        await ForeverDatabase.instance.saveOrder(rejected);
        return rejected;
      }
    } catch (e) {
      final errOrder = TradeOrder(
        orderId: 'ERR_$nowMs',
        timestampMs: nowMs,
        indexName: index.label,
        expiry: expiry,
        strike: strike,
        optionType: optionType,
        side: transactionType,
        quantity: quantity,
        price: price,
        status: 'Rejected',
        mode: 'LIVE',
        reason: 'Network error during order submission',
      );
      await ForeverDatabase.instance.saveOrder(errOrder);
      return errOrder;
    }
  }

  void disposeEngine() {
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _wsChannel?.sink.close();
  }
}
