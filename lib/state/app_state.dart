import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/models.dart';
import '../data/dhan_data_engine.dart';
import '../data/forever_db.dart';
import '../engine/ai_recalibration_engine.dart';
import '../engine/backtest_engine.dart';
import '../engine/mtf_strategy_engine.dart';
import '../engine/risk_engine.dart';

class AppState extends ChangeNotifier {
  TradingMode tradingMode = TradingMode.paper;
  UnderlyingIndex selectedIndex = UnderlyingIndex.nifty50;
  RiskConfig riskConfig = const RiskConfig();

  List<TradeOrder> orders = [];
  List<PositionRecord> openPositions = [];
  List<Map<String, dynamic>> auditLogs = [];

  AiSignal? currentSignal;
  BacktestReport? latestBacktest;
  bool isBusy = false;
  Timer? _uiRefreshTimer;

  // Unified Getters for Institutional 8-Screen UI
  bool get isLiveMode => tradingMode == TradingMode.live;
  AiSignal? get activeSignal => currentSignal;
  BacktestReport? get lastBacktestReport => latestBacktest;

  double get todayRealizedLossInr {
    double loss = 0.0;
    for (final p in openPositions) {
      if (!p.isOpen && p.realizedPnl < 0) {
        loss += p.realizedPnl.abs();
      }
      if (p.isOpen) {
        final ltp = p.currentLtp > 0 ? p.currentLtp : p.avgEntryPrice;
        final curPnl = (ltp - p.avgEntryPrice) * p.quantity;
        if (curPnl < 0) {
          loss += curPnl.abs();
        }
      }
    }
    return loss;
  }

  Future<void> initialize() async {
    await initAppState();
  }

  Future<void> initAppState() async {
    isBusy = true;
    notifyListeners();

    try {
      riskConfig = await ForeverDatabase.instance.loadPersistedRiskConfig();
    } catch (_) {}

    await AiRecalibrationEngine.instance.initialize();
    await DhanDataEngine.instance.initializeAndStart();

    DhanDataEngine.instance.onDataUpdated = () {
      _updateOpenPositionsLtp();
      _evaluateCurrentIndexSignal();
      notifyListeners();
    };

    await _reloadSavedRecords();
    await _evaluateCurrentIndexSignal();

    _uiRefreshTimer?.cancel();
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _updateOpenPositionsLtp();
      _evaluateCurrentIndexSignal();
      notifyListeners();
    });

    isBusy = false;
    notifyListeners();
  }

  void refreshFromEngine() {
    _updateOpenPositionsLtp();
    _evaluateCurrentIndexSignal();
    notifyListeners();
  }

  Future<void> _reloadSavedRecords() async {
    try {
      orders = (await ForeverDatabase.instance.getRecentOrders())
          .map((e) => e as TradeOrder)
          .toList();
      openPositions = (await ForeverDatabase.instance.getAllPositions())
          .map((e) => e as PositionRecord)
          .toList();
      auditLogs = (await ForeverDatabase.instance.getAuditLogs())
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {}
  }

  void setSelectedUnderlying(UnderlyingIndex index) {
    selectedIndex = index;
    DhanDataEngine.instance.fetchOptionChainSnapshot(index);
    _evaluateCurrentIndexSignal();
    notifyListeners();
  }

  void selectIndex(UnderlyingIndex index) {
    setSelectedUnderlying(index);
  }

  void toggleTradingMode(bool enableLive) {
    tradingMode = enableLive ? TradingMode.live : TradingMode.paper;
    ForeverDatabase.instance.logAuditEvent(
      category: 'MODE_CHANGE',
      message: 'Switched trading mode to ${tradingMode.label}',
    );
    notifyListeners();
  }

  void setTradingMode(TradingMode mode) {
    tradingMode = mode;
    notifyListeners();
  }

  void updateRiskConfig(RiskConfig nextConfig) {
    riskConfig = nextConfig;
    ForeverDatabase.instance.savePersistedRiskConfig(nextConfig);
    _evaluateCurrentIndexSignal();
    notifyListeners();
  }

  void toggleKillSwitch(bool active) {
    updateRiskConfig(riskConfig.copyWith(killSwitchActive: active));
  }

  Future<void> _evaluateCurrentIndexSignal() async {
    final engine = DhanDataEngine.instance;
    final rows = engine.optionChainRows[selectedIndex] ?? [];
    final exp = engine.selectedExpiry[selectedIndex] ?? '2026-11-12';
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: selectedIndex.label,
      limit: 30,
    );

    final rawSig = MtfStrategyEngine.evaluateOneMinEntry(
      index: selectedIndex,
      expiry: exp,
      chainRows: rows,
      recent1mBars: bars,
      availableCapital: engine.availableTradingCapital > 0
          ? engine.availableTradingCapital
          : 48200.0,
      riskConfig: riskConfig,
      openPositionsCount: openPositions.where((p) => p.isOpen).length,
      todayRealizedLossInr: todayRealizedLossInr,
    );

    currentSignal = rawSig;
  }

  void _updateOpenPositionsLtp() {
    final engine = DhanDataEngine.instance;
    bool changed = false;
    for (int i = 0; i < openPositions.length; i++) {
      final p = openPositions[i];
      if (!p.isOpen) continue;
      UnderlyingIndex idx = UnderlyingIndex.nifty50;
      for (final u in UnderlyingIndex.values) {
        if (u.label == p.indexName) idx = u;
      }
      final rows = engine.optionChainRows[idx] ?? [];
      for (final r in rows) {
        if (r.strike == p.strike) {
          final liveLtp =
              p.optionType.toUpperCase() == 'CE' ? r.ceLtp : r.peLtp;
          if (liveLtp > 0 && liveLtp != p.currentLtp) {
            openPositions[i] = p.copyWith(currentLtp: liveLtp);
            changed = true;
          }
          break;
        }
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  Future<void> executeActiveSignal() async {
    final sig = currentSignal;
    if (sig == null ||
        sig.action == SignalAction.noTrade ||
        sig.strike == 0 ||
        sig.entryPremium <= 0) {
      return;
    }

    final validated = RiskEngine.validateAndEnforceRisk(
      rawSignal: sig,
      config: riskConfig,
      openPositionsCount: openPositions.where((p) => p.isOpen).length,
      todayRealizedLossInr: todayRealizedLossInr,
      availableCapital: DhanDataEngine.instance.availableTradingCapital > 0
          ? DhanDataEngine.instance.availableTradingCapital
          : 48200.0,
    );

    if (!validated.riskWithinLimits) {
      currentSignal = validated;
      notifyListeners();
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final optType = sig.action == SignalAction.buyCe ? 'CE' : 'PE';
    final modeStr = isLiveMode ? 'LIVE' : 'PAPER';

    if (isLiveMode) {
      final ord = await DhanDataEngine.instance.placeLiveBrokerOrder(
        securityId: '${sig.index.dhanSymbol}_${sig.strike}_$optType',
        index: sig.index,
        expiry: sig.expiry,
        strike: sig.strike,
        optionType: optType,
        transactionType: 'BUY',
        quantity: sig.lotSize,
        price: sig.entryPremium,
        reason: sig.htfOiReason,
      );
      orders.insert(0, ord);
      if (ord.status != 'Filled') {
        notifyListeners();
        return;
      }
    } else {
      final paperOrd = TradeOrder(
        orderId: 'PAPER_$nowMs',
        timestampMs: nowMs,
        indexName: sig.index.label,
        expiry: sig.expiry,
        strike: sig.strike,
        optionType: optType,
        side: 'BUY',
        quantity: sig.lotSize,
        price: sig.entryPremium,
        status: 'Filled',
        mode: modeStr,
        reason: sig.htfOiReason,
      );
      orders.insert(0, paperOrd);
      await ForeverDatabase.instance.saveOrder(paperOrd);
    }

    final pos = PositionRecord(
      positionId: 'POS_$nowMs',
      securityId: '${sig.index.dhanSymbol}_${sig.strike}_$optType',
      indexName: sig.index.label,
      expiry: sig.expiry,
      strike: sig.strike,
      optionType: optType,
      quantity: sig.lotSize,
      avgEntryPrice: sig.entryPremium,
      currentLtp: sig.entryPremium,
      stopLossPremium: sig.stopLossPremium,
      targetPremium: sig.targetPremium,
      openTimestampMs: nowMs,
      status: 'OPEN',
      mode: modeStr,
      realizedPnl: 0.0,
    );
    openPositions.insert(0, pos);
    await ForeverDatabase.instance.savePosition(pos);
    notifyListeners();
  }

  Future<void> closePosition(String positionId) async {
    final idx = openPositions.indexWhere((p) => p.positionId == positionId);
    if (idx == -1) return;
    final p = openPositions[idx];
    if (!p.isOpen) return;

    final exitLtp = p.currentLtp > 0 ? p.currentLtp : p.avgEntryPrice;
    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: p.avgEntryPrice,
      exitPremium: exitLtp,
      quantity: p.quantity,
    );
    final netPnl =
        ((exitLtp - p.avgEntryPrice) * p.quantity) - costs.totalFrictionInr;

    final closed = p.copyWith(
      status: 'CLOSED',
      currentLtp: exitLtp,
      realizedPnl: double.parse(netPnl.toStringAsFixed(2)),
    );
    openPositions[idx] = closed;
    await ForeverDatabase.instance.savePosition(closed);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final closeOrder = TradeOrder(
      orderId: 'EXIT_$nowMs',
      timestampMs: nowMs,
      indexName: p.indexName,
      expiry: p.expiry,
      strike: p.strike,
      optionType: p.optionType,
      side: 'SELL',
      quantity: p.quantity,
      price: exitLtp,
      status: 'Filled',
      mode: p.mode,
      reason: 'Manual Square-Off (Net P&L ₹${netPnl.toStringAsFixed(1)})',
    );
    orders.insert(0, closeOrder);
    await ForeverDatabase.instance.saveOrder(closeOrder);
    notifyListeners();
  }

  Future<void> runBacktestForSelectedIndex() async {
    final rep = await BacktestEngine.runBacktest(
      index: selectedIndex,
      riskConfig: riskConfig,
    );
    latestBacktest = rep as BacktestReport;
    notifyListeners();
  }
}
