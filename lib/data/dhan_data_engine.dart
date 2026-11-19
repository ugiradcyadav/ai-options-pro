import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../core/models.dart';
import '../core/totp_auth.dart';
import 'angel_smartapi_engine.dart';
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
    volume = vol;
    oi = currentOi;
  }
}

class DhanDataEngine implements MarketDataProvider {
  static final DhanDataEngine instance = DhanDataEngine._();
  DhanDataEngine._();

  static const int staleQuoteThresholdMs = 5000; // WP-3: > 5s is stale & blocks signals
  static const int disconnectThresholdMs = 10000; // WP-3: > 10s without tick -> DISCONNECTED
  static const Duration highFreqRefreshInterval = Duration(milliseconds: 750);

  DhanCredentials? _credentials;
  Timer? _pollTimer;
  bool _isFetchingTick = false;

  bool isConnected = false;
  int lastSyncTimestampMs = 0;
  double dataDelaySec = 0.0;
  int missingDataCount = 0;
  String activeDataSource = 'NONE';
  double? availableTradingCapital; // WP-2 & WP-6: null when unknown (never fake 48200)
  String connectionStatusText = 'DISCONNECTED — Broker login required';

  UnderlyingIndex activeStreamingIndex = UnderlyingIndex.nifty50;

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

  final Map<String, _LiveBarBuilder> _barBuilders = {};

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
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'access-token': _credentials?.accessToken ?? '',
        'client-id': _credentials?.clientId ?? '',
      };

  /// WP-9: Non-blocking startup — loads local config/master and kicks off 750ms background loop
  @override
  Future<bool> initializeAndStart() async {
    await AngelSmartApiEngine.instance.loadSavedConfig();
    _credentials = await TotpAuthManager.ensureValidSession();

    // Load instrument master in background so UI never blocks
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
        connectionStatusText = 'Angel SmartAPI (750ms Real Feed)';
        await fetchOptionChainSnapshot(activeStreamingIndex);
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
        connectionStatusText = 'Dhan API Connected (750ms)';
        onDataUpdated?.call();
        return;
      }
    }

    isConnected = false;
    activeDataSource = 'NONE';
    connectionStatusText = 'NO DATA — Connect Angel One or Dhan API';
    onDataUpdated?.call();
  }

  Future<bool> fetchFundLimits() async {
    if (_credentials == null || !_credentials!.isConfigured) return false;
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final resp = await http
          .get(Uri.parse('https://api.dhan.co/v2/fundlimit'),
              headers: _dhanHeaders)
          .timeout(const Duration(seconds: 5));
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
      connectionStatusText = 'NO DATA — Broker login required';
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
      connectionStatusText = 'NO DATA — Instrument master expiries unavailable';
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
        connectionStatusText = 'DISCONNECTED — Reconnecting broker feed';
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
    dataDelaySec = ((receivedAtMs - t0) / 1000.0).clamp(0.05, 5.0);
    lastSyncTimestampMs = receivedAtMs;
    isConnected = true;
    activeDataSource = 'ANGEL_SMARTAPI';
    connectionStatusText = 'LIVE • Angel SmartAPI (${(dataDelaySec * 1000).round()}ms)';

    // WP-3: Record real 1-minute bars from live ticks (underlying SPOT + ATM +/- 2 CE & PE contracts)
    await _recordRealTicksToOneMinBars(
      index: index,
      expiryIso: activeExp,
      spot: spot,
      rows: rows,
      tsMs: receivedAtMs,
    );

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

    // 1. Underlying Index SPOT 1m bar (used by WP-7 Garman-Klass/Parkinson realized vol)
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

    // 2. Real per-contract 1m bars for CE & PE in ATM +/- 2 execution band
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

  /// High-frequency 750ms on-device poller for active index + periodic staleness health check
  void _startHighFrequencyStreamer() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(highFreqRefreshInterval, (_) async {
      // Trigger UI health update even if disconnected so stale badge updates within 10s
      if (!AngelSmartApiEngine.instance.isConfigured) {
        onDataUpdated?.call();
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
  }
}
