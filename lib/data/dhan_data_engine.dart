import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import '../core/http_safe_client.dart';
import '../core/models.dart';
import '../core/totp_auth.dart';
import '../engine/math_greeks.dart';
import '../engine/microstructure_engine.dart';
import 'angel_smartapi_engine.dart';
import 'angel_ws_streamer.dart';
import 'forever_db.dart';
import 'scrip_master_engine.dart';

abstract class MarketDataProvider {
  DataHealthStatus get dataHealth;
  bool get isQuoteFresh;
  Future<bool> initializeAndStart();
  Future<void> fetchOptionChainSnapshot(UnderlyingIndex index);
  void disposeEngine();
}

class _LiveBarBuilder {
  final int minuteBucketMs;
  final double open;
  double high;
  double low;
  double close;
  int volume;
  int oi;

  _LiveBarBuilder({
    required this.minuteBucketMs,
    required this.open,
    required this.volume,
    required this.oi,
  })  : high = open,
        low = open,
        close = open;

  void update(double price, int vol, int currentOi) {
    if (price > high) high = price;
    if (price < low) low = price;
    close = price;
    if (vol > volume) volume = vol;
    if (currentOi > 0) oi = currentOi;
  }
}

class _OptionTokenTarget {
  final UnderlyingIndex index;
  final int rowIndex;
  final bool isCall;

  const _OptionTokenTarget({
    required this.index,
    required this.rowIndex,
    required this.isCall,
  });
}

class DhanDataEngine implements MarketDataProvider {
  static final DhanDataEngine instance = DhanDataEngine._();
  DhanDataEngine._();

  static const int staleQuoteThresholdMs = 5000;
  static const int disconnectThresholdMs = 10000;
  // REST reconciliation timer (WS drives real-time sub-second ticks; REST refreshes Greeks/OI every 6s)
  static const Duration highFreqRefreshInterval = Duration(seconds: 2);

  DhanCredentials? _credentials;
  Timer? _pollTimer;
  Timer? _uiNotifyTimer;
  bool _uiDirty = false;
  bool _isFetchingTick = false;
  int _lastRestSnapshotMs = 0;
  int _lastBarFlushMs = 0;

  bool isConnected = false;
  int lastSyncTimestampMs = 0;
  double dataDelaySec = 0.0;
  int missingDataCount = 0;
  String activeDataSource = 'NONE';
  double? availableTradingCapital;
  String connectionStatusText = 'DISCONNECTED - Broker login required';

  UnderlyingIndex activeStreamingIndex = UnderlyingIndex.nifty50;

  final Map<UnderlyingIndex, double> spotPrices = {
    for (final u in UnderlyingIndex.values) u: 0.0,
  };
  final Map<UnderlyingIndex, double> spotChangePct = {
    for (final u in UnderlyingIndex.values) u: 0.0,
  };
  final Map<UnderlyingIndex, List<String>> availableExpiries = {
    for (final u in UnderlyingIndex.values) u: <String>[],
  };
  final Map<UnderlyingIndex, String> selectedExpiry = {
    for (final u in UnderlyingIndex.values) u: '',
  };
  final Map<UnderlyingIndex, List<StrikeRowSnapshot>>
      optionChainRows = {
    for (final u in UnderlyingIndex.values) u: <StrikeRowSnapshot>[],
  };

  final Map<String, _LiveBarBuilder> _barBuilders = {};
  final Map<String, UnderlyingIndex> _spotTokenToIndex = {
    for (final u in UnderlyingIndex.values)
      AngelSmartApiEngine.spotTokenForIndex(u): u,
  };
  final Map<String, _OptionTokenTarget> _optionTokenMap = {};
  String _lastSubscribedSignature = '';

  void Function()? onDataUpdated;

  @override
  DataHealthStatus get dataHealth {
    if (!isConnected || lastSyncTimestampMs <= 0) {
      return DataHealthStatus.disconnected;
    }
    final ageMs = DateTime.now().millisecondsSinceEpoch - lastSyncTimestampMs;
    if (ageMs > disconnectThresholdMs) return DataHealthStatus.disconnected;
    if (ageMs > staleQuoteThresholdMs) return DataHealthStatus.delayed;
    return DataHealthStatus.live;
  }

  @override
  bool get isQuoteFresh => dataHealth == DataHealthStatus.live;

  Map<String, String> get _dhanHeaders => {
        'Content-Type': 'application/json',
        'access-token': _credentials?.accessToken ?? '',
        'client-id': _credentials?.clientId ?? '',
      };

  void switchActiveIndex(UnderlyingIndex index) {
    activeStreamingIndex = index;
    _lastSubscribedSignature = '';
    unawaited(fetchOptionChainSnapshot(index));
  }

  @override
  Future<bool> initializeAndStart() async {
    await AngelSmartApiEngine.instance.loadSavedConfig();
    _credentials = await TotpAuthManager.ensureValidSession();

    unawaited(_bootstrapMasterAndFeed());
    _startHighFrequencyStreamer();
    return true;
  }

  Future<void> _bootstrapMasterAndFeed() async {
    final masterLoaded = await ScripMasterEngine.instance.loadOrRefreshMaster();
    if (masterLoaded) {
      for (final idx in UnderlyingIndex.values) {
        final exps = ScripMasterEngine.instance.getExpiriesForIndex(idx);
        availableExpiries[idx] = exps;
        if (exps.isNotEmpty && (selectedExpiry[idx] ?? '').isEmpty) {
          selectedExpiry[idx] = exps.first;
        }
      }
    }

    if (AngelSmartApiEngine.instance.isConfigured) {
      final ok = await AngelSmartApiEngine.instance.ensureSession();
      if (ok) {
        availableTradingCapital =
            await AngelSmartApiEngine.instance.fetchRmsCapital();
        activeDataSource = 'ANGEL_SMARTAPI';
        isConnected = true;
        connectionStatusText = 'Connecting SmartStream WebSocket v2...';

        await fetchOptionChainSnapshot(activeStreamingIndex);
        await _connectAngelWebSocket();
        onDataUpdated?.call();
        return;
      }
      isConnected = false;
      connectionStatusText = AngelSmartApiEngine.instance.lastError.isNotEmpty
          ? AngelSmartApiEngine.instance.lastError
          : 'Angel One session inactive';
      onDataUpdated?.call();
      return;
    }

    if (_credentials != null && _credentials!.isConfigured) {
      final ok = await fetchFundLimits();
      if (ok) {
        activeDataSource = 'DHAN_API';
        isConnected = true;
        connectionStatusText = 'Dhan API Connected';
        onDataUpdated?.call();
        return;
      }
    }

    isConnected = false;
    activeDataSource = 'NONE';
    connectionStatusText = 'NO DATA - Connect Angel One or Dhan API';
    onDataUpdated?.call();
  }

  Future<void> _connectAngelWebSocket() async {
    final angel = AngelSmartApiEngine.instance;
    if (angel.jwtToken.isEmpty || angel.feedToken.isEmpty) return;

    final ws = AngelWsStreamer.instance;
    ws.onTick = _handleWsTick;
    ws.onConnectionChanged = (connected) {
      if (connected) {
        connectionStatusText = 'LIVE WS • Angel SmartStream v2';
        _syncWsSubscriptions(activeStreamingIndex);
      } else if (isConnected) {
        connectionStatusText = 'WS Reconnecting • REST Fallback';
      }
      _scheduleUiNotify();
    };

    final ok = await ws.connect(
      jwtToken: angel.jwtToken,
      apiKey: angel.apiKey,
      clientCode: angel.clientCode,
      feedToken: angel.feedToken,
    );
    if (ok) {
      _syncWsSubscriptions(activeStreamingIndex);
    }
  }

  void _syncWsSubscriptions(UnderlyingIndex index) {
    final ws = AngelWsStreamer.instance;
    if (!ws.isConnected) return;

    final rows = optionChainRows[index] ?? const <StrikeRowSnapshot>[];
    _optionTokenMap.clear();

    final nseSpotTokens = <String>[
      AngelSmartApiEngine.spotTokenForIndex(UnderlyingIndex.nifty50),
      AngelSmartApiEngine.spotTokenForIndex(UnderlyingIndex.bankNifty),
      AngelSmartApiEngine.spotTokenForIndex(UnderlyingIndex.finNifty),
    ];
    final bseSpotTokens = <String>[
      AngelSmartApiEngine.spotTokenForIndex(UnderlyingIndex.sensex),
    ];

    final foTokens = <String>[];
    for (int i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.offset.abs() > 8) continue;
      if (r.ceSecurityId.isNotEmpty) {
        foTokens.add(r.ceSecurityId);
        _optionTokenMap[r.ceSecurityId] =
            _OptionTokenTarget(index: index, rowIndex: i, isCall: true);
      }
      if (r.peSecurityId.isNotEmpty) {
        foTokens.add(r.peSecurityId);
        _optionTokenMap[r.peSecurityId] =
            _OptionTokenTarget(index: index, rowIndex: i, isCall: false);
      }
    }

    final sig = '${index.label}|${selectedExpiry[index]}|${foTokens.join(",")}';
    if (sig == _lastSubscribedSignature) return;
    _lastSubscribedSignature = sig;

    final subMap = <int, List<String>>{
      AngelWsStreamer.exchNseCm: nseSpotTokens,
      AngelWsStreamer.exchBseCm: bseSpotTokens,
    };
    if (foTokens.isNotEmpty) {
      subMap[index.wsFoExchType] = foTokens;
    }
    ws.subscribeTokens(subMap);
  }

  void _handleWsTick(LiveWsTick tick) {
    MicrostructureEngine.instance.ingestTick(tick);

    final nowMs = tick.receivedAtMs;
    lastSyncTimestampMs = nowMs;
    isConnected = true;
    activeDataSource = 'ANGEL_WS_V2';
    dataDelaySec = ((nowMs - tick.exchangeTimestampMs).abs() / 1000.0)
        .clamp(0.02, 2.0);
    connectionStatusText =
        'LIVE WS • ${AngelWsStreamer.instance.totalTicksReceived} ticks';

    // 1. Live Index Spot Tick (NSE or BSE Sensex)
    final spotIdx = _spotTokenToIndex[tick.token];
    if (spotIdx != null) {
      spotPrices[spotIdx] = tick.ltp;
      if (tick.changePct != null) {
        spotChangePct[spotIdx] = tick.changePct!;
      }
      _scheduleUiNotify();
      return;
    }

    // 2. Live Option Contract Tick (NFO or BFO Sensex)
    final target = _optionTokenMap[tick.token];
    if (target != null) {
      final rows = optionChainRows[target.index];
      if (rows != null &&
          target.rowIndex >= 0 &&
          target.rowIndex < rows.length) {
        final cur = rows[target.rowIndex];
        final oiLots = tick.openInterestRaw != null
            ? AngelSmartApiEngine.normalizeAngelOiToLots(
                tick.openInterestRaw!, cur.lotSize)
            : null;
        final double? imb = (tick.best5BidQty + tick.best5AskQty) > 0
            ? MathGreeksEngine.calculateOrderBookImbalance(
                totalBidQty: tick.best5BidQty.toDouble(),
                totalAskQty: tick.best5AskQty.toDouble(),
              )
            : null;

        rows[target.rowIndex] = target.isCall
            ? cur.copyWith(
                ceLtp: tick.ltp,
                ceOi: oiLots,
                ceVolume: tick.volume,
                ceBid: tick.bestBid,
                ceAsk: tick.bestAsk,
                ceBidQty: tick.best5BidQty > 0 ? tick.best5BidQty : null,
                ceAskQty: tick.best5AskQty > 0 ? tick.best5AskQty : null,
                ceImbalance: imb,
                receivedAtMs: nowMs,
                exchangeTimestampMs: tick.exchangeTimestampMs,
              )
            : cur.copyWith(
                peLtp: tick.ltp,
                peOi: oiLots,
                peVolume: tick.volume,
                peBid: tick.bestBid,
                peAsk: tick.bestAsk,
                peBidQty: tick.best5BidQty > 0 ? tick.best5BidQty : null,
                peAskQty: tick.best5AskQty > 0 ? tick.best5AskQty : null,
                peImbalance: imb,
                receivedAtMs: nowMs,
                exchangeTimestampMs: tick.exchangeTimestampMs,
              );

        // Throttled non-blocking 1m bar persistence (at most once every 10s)
        if (nowMs - _lastBarFlushMs >= 10000) {
          _lastBarFlushMs = nowMs;
          final exp = selectedExpiry[target.index] ?? '';
          final sp = spotPrices[target.index] ?? 0.0;
          if (exp.isNotEmpty && sp > 0) {
            unawaited(_recordRealTicksToOneMinBars(
              index: target.index,
              expiryIso: exp,
              spot: sp,
              rows: rows,
              tsMs: nowMs,
            ));
          }
        }
        _scheduleUiNotify();
      }
    }
  }

  /// Coalesces sub-second WS ticks into smooth 5 FPS UI repaints (like broker terminals)
  void _scheduleUiNotify() {
    _uiDirty = true;
    _uiNotifyTimer ??= Timer(const Duration(milliseconds: 200), () {
      _uiNotifyTimer = null;
      if (_uiDirty) {
        _uiDirty = false;
        onDataUpdated?.call();
      }
    });
  }

  Future<bool> fetchFundLimits() async {
    if (_credentials == null || !_credentials!.isConfigured) return false;
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final resp = await SafeBrokerHttp.get(
        Uri.parse('https://api.dhan.co/v2/fundlimit'),
        headers: _dhanHeaders,
        timeout: const Duration(seconds: 5),
      );
      final t1 = DateTime.now().millisecondsSinceEpoch;
      dataDelaySec = ((t1 - t0) / 1000.0).clamp(0.05, 5.0);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final raw = data['availabelBalance'] ?? data['availableBalance'];
        if (raw is num) {
          availableTradingCapital = raw.toDouble();
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> fetchOptionChainSnapshot(UnderlyingIndex index) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;

    if (!AngelSmartApiEngine.instance.isConfigured) {
      isConnected = false;
      connectionStatusText = 'NO DATA - Broker login required';
      onDataUpdated?.call();
      return;
    }

    final exps = ScripMasterEngine.instance.getExpiriesForIndex(index);
    if (exps.isNotEmpty) {
      availableExpiries[index] = exps;
      if ((selectedExpiry[index] ?? '').isEmpty ||
          !exps.contains(selectedExpiry[index])) {
        selectedExpiry[index] = exps.first;
      }
    }

    final activeExp = selectedExpiry[index] ?? '';
    if (activeExp.isEmpty) {
      missingDataCount++;
      connectionStatusText = 'NO DATA - Instrument master expiries unavailable';
      onDataUpdated?.call();
      return;
    }

    final angelData = await AngelSmartApiEngine.instance.fetchLiveSpotAndChain(
      index: index,
      expiryIso: activeExp,
    );

    if (angelData == null) {
      missingDataCount++;
      if (dataHealth == DataHealthStatus.disconnected) {
        isConnected = false;
        connectionStatusText = 'DISCONNECTED - Reconnecting broker feed';
      }
      onDataUpdated?.call();
      return;
    }

    final spot = ((angelData['spot'] ?? 0) as num).toDouble();
    final chg = ((angelData['changePct'] ?? 0) as num).toDouble();
    final rows = (angelData['rows'] as List)
        .map((e) => e as StrikeRowSnapshot)
        .toList();
    final receivedAtMs = ((angelData['receivedAtMs'] ??
            DateTime.now().millisecondsSinceEpoch) as num)
        .toInt();

    if (spot <= 0 || rows.isEmpty) {
      missingDataCount++;
      onDataUpdated?.call();
      return;
    }

    spotPrices[index] = spot;
    spotChangePct[index] = chg;
    optionChainRows[index] = rows;
    _lastRestSnapshotMs = receivedAtMs;
    dataDelaySec = ((receivedAtMs - t0) / 1000.0).clamp(0.05, 5.0);
    lastSyncTimestampMs = receivedAtMs;
    isConnected = true;

    if (AngelWsStreamer.instance.isConnected) {
      activeDataSource = 'ANGEL_WS_V2';
      _syncWsSubscriptions(index);
    } else {
      activeDataSource = 'ANGEL_SMARTAPI';
      connectionStatusText =
          'LIVE REST • ${(dataDelaySec * 1000).round()}ms';
      unawaited(_connectAngelWebSocket());
    }

    unawaited(_recordRealTicksToOneMinBars(
      index: index,
      expiryIso: activeExp,
      spot: spot,
      rows: rows,
      tsMs: receivedAtMs,
    ));

    onDataUpdated?.call();
  }

  Future<void> _recordRealTicksToOneMinBars({
    required UnderlyingIndex index,
    required String expiryIso,
    required double spot,
    required List<StrikeRowSnapshot> rows,
    required int tsMs,
  }) async {
    final minuteBucket = (tsMs ~/ 60000) * 60000;
    final db = ForeverDatabase.instance;

    final spotKey = 'SPOT_${index.dhanSymbol}';
    final spotBuilder = _barBuilders[spotKey];
    if (spotBuilder == null || spotBuilder.minuteBucketMs != minuteBucket) {
      _barBuilders[spotKey] = _LiveBarBuilder(
        minuteBucketMs: minuteBucket,
        open: spot,
        volume: 0,
        oi: 0,
      );
    } else {
      spotBuilder.update(spot, 0, 0);
    }
    final sb = _barBuilders[spotKey]!;
    await db.insertOneMinBar(
      OneMinEnrichedBar(
        timestampMs: minuteBucket,
        contractId: spotKey,
        indexName: index.label,
        expiry: expiryIso,
        strike: 0,
        optionType: 'SPOT',
        strikeOffset: 0,
        underlyingSpot: spot,
        open: sb.open,
        high: sb.high,
        low: sb.low,
        close: sb.close,
        intervalVolume: 0,
        absoluteOi: 0,
        delta: 1.0,
        gamma: 0.0,
        theta: 0.0,
        vega: 0.0,
      ),
    );

    for (final r in rows) {
      if (r.offset.abs() > 2) continue;
      for (final isCall in [true, false]) {
        final cid = isCall ? r.ceSecurityId : r.peSecurityId;
        final ltp = isCall ? r.ceLtp : r.peLtp;
        final vol = isCall ? r.ceVolume : r.peVolume;
        final oi = isCall ? r.ceOi : r.peOi;
        if (ltp <= 0 || cid.isEmpty) continue;

        final existing = _barBuilders[cid];
        if (existing == null || existing.minuteBucketMs != minuteBucket) {
          _barBuilders[cid] = _LiveBarBuilder(
            minuteBucketMs: minuteBucket,
            open: ltp,
            volume: vol,
            oi: oi,
          );
        } else {
          existing.update(ltp, vol, oi);
        }
        final b = _barBuilders[cid]!;
        final bid = isCall ? r.ceBid : r.peBid;
        final ask = isCall ? r.ceAsk : r.peAsk;
        double? spreadPct;
        if (bid != null && ask != null && bid > 0 && ask >= bid) {
          final mid = 0.5 * (bid + ask);
          if (mid > 0) spreadPct = ((ask - bid) / mid) * 100.0;
        }

        await db.insertOneMinBar(
          OneMinEnrichedBar(
            timestampMs: minuteBucket,
            contractId: cid,
            indexName: index.label,
            expiry: expiryIso,
            strike: r.strike,
            optionType: isCall ? 'CE' : 'PE',
            strikeOffset: r.offset,
            underlyingSpot: spot,
            open: b.open,
            high: b.high,
            low: b.low,
            close: b.close,
            intervalVolume: math.max(0, vol),
            absoluteOi: oi,
            oiChange5m: isCall ? r.ceOiChange5m : r.peOiChange5m,
            oiChange15m: isCall ? r.ceOiChange15m : r.peOiChange15m,
            oiChange60m: isCall ? r.ceOiChange60m : r.peOiChange60m,
            iv: isCall ? r.ceIv : r.peIv,
            delta: isCall ? r.ceDelta : r.peDelta,
            gamma: isCall ? r.ceGamma : r.peGamma,
            theta: isCall ? r.ceTheta : r.peTheta,
            vega: isCall ? r.ceVega : r.peVega,
            spreadPct: spreadPct,
            orderBookImbalance: isCall ? r.ceImbalance : r.peImbalance,
          ),
        );
      }
    }
  }

  /// Rate-limit-safe reconciliation loop: 6s when WebSocket v2 is active, 2s fallback if WS drops
  void _startHighFrequencyStreamer() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(highFreqRefreshInterval, (_) async {
      if (!AngelSmartApiEngine.instance.isConfigured) {
        onDataUpdated?.call();
        return;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final wsLive = AngelWsStreamer.instance.isConnected;
      final minRestGapMs = wsLive ? 6000 : 2000;
      if (nowMs - _lastRestSnapshotMs < minRestGapMs) {
        if (!wsLive) onDataUpdated?.call();
        return;
      }
      if (_isFetchingTick) return;
      _isFetchingTick = true;
      try {
        await fetchOptionChainSnapshot(activeStreamingIndex);
      } catch (_) {
      } finally {
        _isFetchingTick = false;
      }
    });
  }

  @override
  void disposeEngine() {
    _pollTimer?.cancel();
    _uiNotifyTimer?.cancel();
    unawaited(AngelWsStreamer.instance.disconnect());
  }
}
