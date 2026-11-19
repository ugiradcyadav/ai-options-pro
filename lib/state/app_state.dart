import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/models.dart';
import '../data/dhan_data_engine.dart';
import '../data/forever_db.dart';
import '../engine/ai_recalibration_engine.dart';
import '../engine/backtest_engine.dart';
import '../engine/execution_engine.dart';
import '../engine/exit_manager.dart';
import '../engine/mtf_strategy_engine.dart';

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

  bool get isLiveMode =>
      tradingMode == TradingMode.live && ExecutionEngine.liveTradingUnlocked;
  AiSignal? get activeSignal => currentSignal;
  BacktestReport? get lastBacktestReport => latestBacktest;
  DataHealthStatus get dataHealth => DhanDataEngine.instance.dataHealth;

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

  Future<void> initialize() async {
    await initAppState();
  }

  /// WP-9: Non-blocking startup — loads local DB fast, connects broker in background
  Future<void> initAppState() async {
    try {
      riskConfig = await ForeverDatabase.instance.loadPersistedRiskConfig();
      await _reloadSavedRecords();
      await AiRecalibrationEngine.instance.initialize();
    } catch (_) {}

    DhanDataEngine.instance.activeStreamingIndex = selectedIndex;
    DhanDataEngine.instance.onDataUpdated = () {
      _onMarketTick();
    };

    // Start broker feed in background without blocking UI shell
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

  Future<void> _runExitManagerAndSignalEval() async {
    final engine = DhanDataEngine.instance;

    // Build securityId -> StrikeRowSnapshot map across loaded indices for ExitManager
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
    DhanDataEngine.instance.activeStreamingIndex = index;
    unawaited(DhanDataEngine.instance.fetchOptionChainSnapshot(index));
    unawaited(_evaluateCurrentIndexSignal());
    notifyListeners();
  }

  bool toggleTradingMode(bool enableLive) {
    // WP-2 & WP-6: LIVE mode stays strictly locked until WP-1..WP-6 + 15-day paper run complete
    if (enableLive && !ExecutionEngine.liveTradingUnlocked) {
      tradingMode = TradingMode.paper;
      notifyListeners();
      return false;
    }
    tradingMode = enableLive ? TradingMode.live : TradingMode.paper;
    ForeverDatabase.instance.logAuditEvent(
      category: 'MODE_CHANGE',
      message: 'Trading mode set to ${tradingMode.label}',
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

  /// WP-6: Kill switch blocks entries and optionally flattens all open positions
  Future<void> activateKillSwitch({bool flattenAll = false}) async {
    updateRiskConfig(riskConfig.copyWith(killSwitchActive: true));
    await ForeverDatabase.instance.logAuditEvent(
      category: 'KILL_SWITCH',
      message: 'Kill switch ACTIVATED (flattenAll=$flattenAll)',
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
          if (r.ceSecurityId == p.securityId || r.peSecurityId == p.securityId) {
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

  Future<ExecutionResult?> executeActiveSignal() async {
    final sig = currentSignal;
    if (sig == null || !sig.riskWithinLimits || !sig.strategyPassed) {
      return null;
    }

    // Lookup live bid/ask for quote-driven paper fill & marketable limit cap
    double? bid;
    double? ask;
    final rows = DhanDataEngine.instance.optionChainRows[sig.index] ?? const [];
    for (final r in rows) {
      if (r.ceSecurityId == sig.securityId) {
        bid = r.ceBid;
        ask = r.ceAsk;
        break;
      } else if (r.peSecurityId == sig.securityId) {
        bid = r.peBid;
        ask = r.peAsk;
        break;
      }
    }

    final res = await ExecutionEngine.instance.executeEntry(
      signal: sig,
      mode: tradingMode,
      bestBid: bid,
      bestAsk: ask,
    );
    await _reloadSavedRecords();
    notifyListeners();
    return res;
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

  Future<void> runBacktestForSelectedIndex() async {
    latestBacktest = await BacktestEngine.runBacktest(
      index: selectedIndex,
      riskConfig: riskConfig,
      availableCapital: DhanDataEngine.instance.availableTradingCapital,
    );
    notifyListeners();
  }
}
