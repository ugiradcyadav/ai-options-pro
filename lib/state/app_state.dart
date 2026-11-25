import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../core/models.dart';
import '../data/constituent_flow_engine.dart';
import '../data/dhan_data_engine.dart';
import '../data/flow_data_engine.dart';
import '../data/forever_db.dart';
import '../engine/ai_recalibration_engine.dart';
import '../engine/backtest_engine.dart';
import '../engine/execution_engine.dart';
import '../engine/exit_manager.dart';
import '../engine/journal_coach_engine.dart';
import '../engine/mtf_strategy_engine.dart';
import '../engine/regime_engine.dart';
import '../engine/sadhu_ml_engine.dart';

class AppState extends ChangeNotifier {
  TradingMode tradingMode = TradingMode.paper;
  UnderlyingIndex selectedIndex = UnderlyingIndex.nifty50;
  RiskConfig riskConfig = const RiskConfig();

  List<TradeOrder> orders = [];
  List<PositionRecord> openPositions = [];
  List<Map<String, dynamic>> auditLogs = [];

  AiSignal? currentSignal;
  BacktestReport? latestBacktest;
  double todayNetRealizedPnlIst = 0.0;
  bool isBusy = false;
  Timer? _supervisorTimer;

  // C4 & C5 Concurrency Locks
  bool _evalExitLock = false;
  bool _isExecutingOrder = false;

  // Per-index real measured regime (replaces stuck global HMM constants)
  final Map<UnderlyingIndex, MeasuredRegimeSnapshot> measuredRegimes = {};
  SadhuMlTrainingReport sadhuMlReport = SadhuMlTrainingReport.untrained;

  bool get isLiveMode =>
      tradingMode == TradingMode.live && ExecutionEngine.liveTradingUnlocked;
  AiSignal? get activeSignal => currentSignal;
  BacktestReport? get lastBacktestReport => latestBacktest;
  DataHealthStatus get dataHealth => DhanDataEngine.instance.dataHealth;

  MeasuredRegimeSnapshot get activeRegime =>
      measuredRegimes[selectedIndex] ??
      MeasuredRegimeSnapshot.collecting(selectedIndex.label, 0);

  JournalCoachSummary get journalSummary =>
      JournalCoachEngine.analyze(openPositions);

  double get todayRealizedLossInr =>
      todayNetRealizedPnlIst < 0 ? todayNetRealizedPnlIst.abs() : 0.0;

  double get openPositionsRiskInr {
    double risk = 0.0;
    for (final p in openPositions) {
      if (!p.isOpen) continue;
      risk += (p.avgEntryPrice - p.stopLossPrice).abs() * p.quantity;
    }
    return risk;
  }

  /// H4: Block fresh entries from 15:10 IST onward (5m buffer before 15:15 forced exit)
  static bool isAtOrPastEntryCutoffIst({DateTime? nowUtc}) {
    final ist = (nowUtc ?? DateTime.now().toUtc())
        .add(const Duration(hours: 5, minutes: 30));
    final mins = ist.hour * 60 + ist.minute;
    return mins >= (15 * 60 + 10);
  }

  Future<void> initialize() async {
    await initAppState();
  }

  Future<void> initAppState() async {
    try {
      riskConfig = await ForeverDatabase.instance.loadPersistedRiskConfig();
      await _reloadSavedRecords();
      await AiRecalibrationEngine.instance.initialize();
      final loadedMl = await SadhuMlEngine.instance.loadModelFromDisk();
      if (loadedMl) {
        sadhuMlReport = SadhuMlEngine.instance.lastReport;
      }
    } catch (_) {
      // Fail-closed: if persisted risk config cannot be loaded, keep strict defaults
      riskConfig = const RiskConfig();
    }

    DhanDataEngine.instance.activeStreamingIndex = selectedIndex;
    DhanDataEngine.instance.onDataUpdated = () {
      _onMarketTick();
    };

    unawaited(DhanDataEngine.instance.initializeAndStart());

    _supervisorTimer?.cancel();
    _supervisorTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onMarketTick();
    });

    notifyListeners();
  }

  void _onMarketTick() {
    _updateOpenPositionsLtp();
    unawaited(_runExitManagerAndSignalEval());
    notifyListeners();
  }

  /// C4 Fix: Strict single-flight lock prevents overlapping timer/tick exit races
  Future<void> _runExitManagerAndSignalEval() async {
    if (_evalExitLock) return;
    _evalExitLock = true;
    try {
      final engine = DhanDataEngine.instance;
      final quoteMap = <String, StrikeRowSnapshot>{};
      for (final idx in UnderlyingIndex.values) {
        for (final r in (engine.optionChainRows[idx] ?? const [])) {
          if (r.ceSecurityId.isNotEmpty) quoteMap[r.ceSecurityId] = r;
          if (r.peSecurityId.isNotEmpty) quoteMap[r.peSecurityId] = r;
        }
      }

      final activeOpens = openPositions.where((p) => p.isOpen).toList();
      if (activeOpens.isNotEmpty) {
        final exits = await ExitManager.instance.evaluateAndExecuteExits(
          openPositions: activeOpens,
          quoteBySecurityId: quoteMap,
        );
        if (exits.isNotEmpty) {
          await _reloadSavedRecords();
        }
      }

      await _evaluateCurrentIndexSignal();
      notifyListeners();
    } finally {
      _evalExitLock = false;
    }
  }

  Future<void> _reloadSavedRecords() async {
    try {
      orders = await ForeverDatabase.instance.getRecentOrders();
      openPositions = await ForeverDatabase.instance.getAllPositions();
      auditLogs = await ForeverDatabase.instance.getAuditLogs();
      todayNetRealizedPnlIst =
          await ForeverDatabase.instance.computeTodayNetRealizedPnlIst();
    } catch (_) {}
  }

  void setSelectedUnderlying(UnderlyingIndex index) {
    selectedIndex = index;
    DhanDataEngine.instance.switchActiveIndex(index);
    unawaited(ConstituentFlowEngine.instance.refreshForIndex(index));
    unawaited(_evaluateCurrentIndexSignal());
    notifyListeners();
  }

  bool toggleTradingMode(bool enableLive) {
    // Strictly Paper-only until Phase 2 real broker order layer + unlock gates pass
    if (enableLive && !ExecutionEngine.liveTradingUnlocked) {
      tradingMode = TradingMode.paper;
      notifyListeners();
      return false;
    }
    tradingMode = enableLive ? TradingMode.live : TradingMode.paper;
    ForeverDatabase.instance.logAuditEvent(
      category: 'MODE_CHANGE',
      message: 'Sadhu AI trading mode set to ${tradingMode.label}',
    );
    notifyListeners();
    return true;
  }

  void updateRiskConfig(RiskConfig nextConfig) {
    riskConfig = nextConfig;
    ForeverDatabase.instance.savePersistedRiskConfig(nextConfig);
    unawaited(_evaluateCurrentIndexSignal());
    notifyListeners();
  }

  Future<void> activateKillSwitch({bool flattenAll = false}) async {
    updateRiskConfig(riskConfig.copyWith(killSwitchActive: true));
    await ForeverDatabase.instance.logAuditEvent(
      category: 'KILL_SWITCH',
      message: 'Sadhu AI Kill switch ACTIVATED (flattenAll=$flattenAll)',
    );
    if (flattenAll) {
      for (final p in openPositions.where((e) => e.isOpen).toList()) {
        await closePosition(p.positionId, reason: 'KILL_SWITCH_FLATTEN');
      }
    }
  }

  Future<void> _evaluateCurrentIndexSignal() async {
    final engine = DhanDataEngine.instance;
    final rows = engine.optionChainRows[selectedIndex] ?? const [];
    final exp = engine.selectedExpiry[selectedIndex] ?? '';
    final spot = engine.spotPrices[selectedIndex] ?? 0.0;
    final spotBars = await ForeverDatabase.instance.getRecentBars(
      indexName: selectedIndex.label,
      optionType: 'SPOT',
      limit: 60,
    );

    // Real per-index measured market regime (zero hardcoded HMM constants)
    measuredRegimes[selectedIndex] = RegimeEngine.evaluate(
      indexLabel: selectedIndex.label,
      spotBars: spotBars,
      liveSpot: spot > 0 ? spot : null,
      indiaVix: FlowDataEngine.instance.indiaVix,
    );

    currentSignal = MtfStrategyEngine.evaluateEntry(
      index: selectedIndex,
      expiry: exp,
      spot: spot,
      dataHealth: engine.dataHealth,
      chainRows: rows,
      recentSpotBars: spotBars,
      availableCapital: engine.availableTradingCapital,
      riskConfig: riskConfig,
      openPositionsCount: openPositions.where((p) => p.isOpen).length,
      todayNetRealizedPnlIst: todayNetRealizedPnlIst,
      openPositionsRiskInr: openPositionsRiskInr,
    );
  }

  void _updateOpenPositionsLtp() {
    final engine = DhanDataEngine.instance;
    for (int i = 0; i < openPositions.length; i++) {
      final p = openPositions[i];
      if (!p.isOpen) continue;
      for (final idx in UnderlyingIndex.values) {
        if (idx.label != p.indexName) continue;
        for (final r in (engine.optionChainRows[idx] ?? const [])) {
          if (r.ceSecurityId == p.securityId ||
              r.peSecurityId == p.securityId) {
            final liveLtp =
                p.optionType.toUpperCase() == 'CE' ? r.ceLtp : r.peLtp;
            if (liveLtp > 0 && liveLtp != p.currentLtp) {
              openPositions[i] = p.copyWith(currentLtp: liveLtp);
            }
          }
        }
      }
    }
  }

  /// C5 + H4 Fix: Single-flight lock, 15:10 IST cut-off, fresh risk re-check & deterministic ID
  Future<ExecutionResult?> executeActiveSignal() async {
    if (_isExecutingOrder) return null;
    if (isAtOrPastEntryCutoffIst()) {
      await ForeverDatabase.instance.logAuditEvent(
        category: 'ENTRY_CUTOFF_BLOCKED',
        message: 'Blocked entry after 15:10 IST cut-off (before 15:15 forced square-off).',
      );
      return null;
    }

    _isExecutingOrder = true;
    try {
      await _reloadSavedRecords();
      await _evaluateCurrentIndexSignal();

      final sig = currentSignal;
      if (sig == null || !sig.riskWithinLimits || !sig.strategyPassed) {
        notifyListeners();
        return null;
      }

      // Per-contract freshness check (H3)
      double? bid;
      double? ask;
      int? askQty;
      int quoteAgeMs = 999999;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final rows = DhanDataEngine.instance.optionChainRows[sig.index] ?? const [];
      for (final r in rows) {
        if (r.ceSecurityId == sig.securityId) {
          bid = r.ceBid;
          ask = r.ceAsk;
          askQty = r.ceAskQty;
          quoteAgeMs = (nowMs - r.receivedAtMs).abs();
          break;
        } else if (r.peSecurityId == sig.securityId) {
          bid = r.peBid;
          ask = r.peAsk;
          askQty = r.peAskQty;
          quoteAgeMs = (nowMs - r.receivedAtMs).abs();
          break;
        }
      }

      if (quoteAgeMs > DhanDataEngine.staleQuoteThresholdMs) {
        await ForeverDatabase.instance.logAuditEvent(
          category: 'STALE_CONTRACT_BLOCKED',
          message:
              'Blocked ${sig.tradingSymbol}: contract quote age ${quoteAgeMs}ms > 5000ms.',
        );
        return null;
      }

      final minuteBucket = nowMs ~/ 60000;
      final detCorrId =
          'SADHU_${sig.securityId}_${sig.strike}_${sig.action.name}_$minuteBucket';

      final res = await ExecutionEngine.instance.executeEntry(
        signal: sig,
        mode: tradingMode,
        bestBid: bid,
        bestAsk: ask,
        topBookAskQty: askQty,
        correlationIdOverride: detCorrId,
      );
      await _reloadSavedRecords();
      notifyListeners();
      return res;
    } finally {
      _isExecutingOrder = false;
    }
  }

  Future<void> closePosition(String positionId,
      {String reason = 'MANUAL_SQUARE_OFF'}) async {
    final idx = openPositions.indexWhere((p) => p.positionId == positionId);
    if (idx == -1) return;
    final p = openPositions[idx];
    if (!p.isOpen) return;

    double? bid;
    double? ask;
    double liveLtp = p.currentLtp > 0 ? p.currentLtp : p.avgEntryPrice;
    for (final u in UnderlyingIndex.values) {
      if (u.label != p.indexName) continue;
      for (final r in (DhanDataEngine.instance.optionChainRows[u] ?? const [])) {
        if (r.ceSecurityId == p.securityId) {
          liveLtp = r.ceLtp > 0 ? r.ceLtp : liveLtp;
          bid = r.ceBid;
          ask = r.ceAsk;
          break;
        } else if (r.peSecurityId == p.securityId) {
          liveLtp = r.peLtp > 0 ? r.peLtp : liveLtp;
          bid = r.peBid;
          ask = r.peAsk;
          break;
        }
      }
    }

    await ExecutionEngine.instance.executeExit(
      position: p,
      currentLtp: liveLtp,
      bestBid: bid,
      bestAsk: ask,
      exitReason: reason,
    );
    await _reloadSavedRecords();
    notifyListeners();
  }

  /// Trains Sadhu AI ML Engine on strictly per-contract, non-overlapping real recorded bars
  Future<SadhuMlTrainingReport> trainSadhuMlFromRealBars() async {
    final raw = await ForeverDatabase.instance.getRecentBars(
      indexName: selectedIndex.label,
      limit: 1200,
    );
    final byContract = <String, List<OneMinEnrichedBar>>{};
    for (final b in raw) {
      if (b.optionType.toUpperCase() == 'SPOT') continue;
      byContract.putIfAbsent(b.contractId, () => []).add(b);
    }

    final features = <List<double>>[];
    final labels = <int>[];
    const horizon = 5;

    for (final list in byContract.values) {
      list.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      if (list.length < 10) continue;

      // Step by `horizon` so training samples never overlap (eliminates autocorrelation leak)
      for (int i = 3; i + horizon < list.length; i += horizon) {
        final cur = list[i];
        final prev = list[i - 3];
        if (cur.close <= 0 || prev.close <= 0 || prev.underlyingSpot <= 0) {
          continue;
        }

        final optRet = (cur.close - prev.close) / prev.close;
        final spotRet =
            (cur.underlyingSpot - prev.underlyingSpot) / prev.underlyingSpot;
        final obi = cur.orderBookImbalance ?? 0.0;
        final oiChgRatio =
            (cur.oiChange15m ?? 0) / math.max(1, cur.absoluteOi).toDouble();
        final ivNorm = (cur.iv ?? 15.0) / 100.0;
        final absDelta = cur.delta.abs();
        final spreadNorm = (cur.spreadPct ?? 0.30) / 100.0;

        // Triple-barrier label on the SAME contract timeline
        final targetPx = cur.close * 1.06;
        final stopPx = cur.close * 0.96;
        int label = 0;
        for (int k = 1; k <= horizon; k++) {
          final fut = list[i + k];
          if (fut.low <= stopPx) {
            label = 0;
            break;
          }
          if (fut.high >= targetPx) {
            label = 1;
            break;
          }
        }

        features.add([
          optRet,
          spotRet,
          obi,
          oiChgRatio,
          ivNorm,
          absDelta,
          spreadNorm,
        ]);
        labels.add(label);
      }
    }

    sadhuMlReport = SadhuMlEngine.instance.trainOnRealDataset(
      features: features,
      labels: labels,
    );
    if (sadhuMlReport.trained) {
      await SadhuMlEngine.instance.saveModelToDisk();
    }
    notifyListeners();
    return sadhuMlReport;
  }

  Future<void> runBacktestForSelectedIndex() async {
    latestBacktest = await BacktestEngine.runBacktest(
      index: selectedIndex,
      riskConfig: riskConfig,
      availableCapital: DhanDataEngine.instance.availableTradingCapital,
    );
    notifyListeners();
  }
}
