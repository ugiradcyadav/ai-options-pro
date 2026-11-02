import 'package:flutter/foundation.dart';
import '../core/models.dart';
import '../data/dhan_data_engine.dart';
import '../data/forever_db.dart';
import '../engine/ai_recalibration_engine.dart';
import '../engine/risk_engine.dart';
import '../engine/mtf_strategy_engine.dart';

class AppState extends ChangeNotifier {
  TradingMode tradingMode = TradingMode.paper;
  UnderlyingIndex selectedIndex = UnderlyingIndex.nifty50;
  RiskConfig riskConfig = const RiskConfig();

  bool isInitialized = false;
  List<PositionRecord> openPositions = [];
  List<PositionRecord> closedPositions = [];
  List<TradeOrder> orders = [];
  AiSignal? latestSignal;
  double todayRealizedLoss = 0.0;
  double databaseSizeMb = 0.0;

  Future<void> initializeApp() async {
    if (isInitialized) return;
    await AiRecalibrationEngine.instance.initialize();
    DhanDataEngine.instance.onDataUpdated = () {
      _refreshOperationalState();
      if (latestSignal == null || latestSignal!.strike == 0) {
        _evaluateLiveSignalForIndex(selectedIndex);
      }
      ForeverDatabase.instance.savePersistedRiskConfig(riskConfig);
    notifyListeners();
    };

    DhanDataEngine.instance.onOneMinuteCandleClosed = (index, bars) {
      _evaluateLiveSignalForIndex(index);
    };

    await DhanDataEngine.instance.initializeAndStart();
    await _refreshOperationalState();
      if (latestSignal == null || latestSignal!.strike == 0) {
        _evaluateLiveSignalForIndex(selectedIndex);
      }
    isInitialized = true;
    ForeverDatabase.instance.savePersistedRiskConfig(riskConfig);
    notifyListeners();
  }

  Future<void> switchTradingMode(TradingMode mode) async {
    tradingMode = mode;
    ForeverDatabase.instance.savePersistedRiskConfig(riskConfig);
    notifyListeners();
    await _refreshOperationalState();
      if (latestSignal == null || latestSignal!.strike == 0) {
        _evaluateLiveSignalForIndex(selectedIndex);
      }
  }

  Future<void> setSelectedUnderlying(UnderlyingIndex idx) async {
    selectedIndex = idx;
    ForeverDatabase.instance.savePersistedRiskConfig(riskConfig);
    notifyListeners();
    await DhanDataEngine.instance.fetchOptionChainSnapshot(idx);
    _evaluateLiveSignalForIndex(idx);
  }

  Future<void> toggleKillSwitch() async {
    riskConfig =
        riskConfig.copyWith(killSwitchActive: !riskConfig.killSwitchActive);
    ForeverDatabase.instance.savePersistedRiskConfig(riskConfig);
    notifyListeners();
  }

  Future<void> _refreshOperationalState() async {
    final modeStr = tradingMode == TradingMode.live ? 'LIVE' : 'PAPER';
    openPositions =
        await ForeverDatabase.instance.getPositions(isOpen: true, mode: modeStr);
    closedPositions = await ForeverDatabase.instance.getPositions(
        isOpen: false, mode: modeStr);
    orders = await ForeverDatabase.instance.getOrders(mode: modeStr);
    databaseSizeMb = await ForeverDatabase.instance.getDatabaseSizeMb();
    ForeverDatabase.instance.savePersistedRiskConfig(riskConfig);
    notifyListeners();
  }

  void _evaluateLiveSignalForIndex(UnderlyingIndex idx) {
    final chain = DhanDataEngine.instance.optionChainRows[idx] ?? [];
    ForeverDatabase.instance
        .getRecentBars(indexName: idx.label, limit: 60)
        .then((bars) {
      final expiry =
          DhanDataEngine.instance.selectedExpiry[idx] ?? '2026-04-30';
      final rawSig = MtfStrategyEngine.evaluateOneMinEntry(
        index: idx,
        expiry: expiry,
        chainRows: chain,
        recent1mBars: bars,
        availableCapital: DhanDataEngine.instance.availableTradingCapital,
        riskConfig: riskConfig,
        openPositionsCount: openPositions.length,
        todayRealizedLossInr: todayRealizedLoss,
      );

      latestSignal = RiskEngine.validateAndEnforceRisk(
        rawSignal: rawSig,
        config: riskConfig,
        openPositionsCount: openPositions.length,
        todayRealizedLossInr: todayRealizedLoss,
        availableCapital: DhanDataEngine.instance.availableTradingCapital,
      );

      if (latestSignal!.action != SignalAction.noTrade &&
          latestSignal!.riskWithinLimits) {
        ForeverDatabase.instance.logSignal(latestSignal!);
      }
      ForeverDatabase.instance.savePersistedRiskConfig(riskConfig);
    notifyListeners();
    });
  }

  Future<bool> approveAndExecuteSignal(AiSignal sig) async {
    if (!sig.riskWithinLimits || sig.action == SignalAction.noTrade) {
      return false;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final modeStr = tradingMode == TradingMode.live ? 'LIVE' : 'PAPER';
    final optionType = sig.action == SignalAction.buyCe ? 'CE' : 'PE';
    final securityId = '${sig.index.dhanSymbol}_${sig.strike}_$optionType';
    final entryReason =
        sig.reasons.isNotEmpty ? sig.reasons.first : 'Manual Signal Approval';

    if (tradingMode == TradingMode.live) {
      final order = await DhanDataEngine.instance.placeLiveBrokerOrder(
        securityId: securityId,
        index: sig.index,
        expiry: sig.expiry,
        strike: sig.strike,
        optionType: optionType,
        transactionType: 'BUY',
        quantity: sig.lotSize,
        price: sig.entryPremium,
        reason: entryReason,
      );
      if (order.status != 'Filled') return false;
    } else {
      final paperOrder = TradeOrder(
        orderId: 'PAPER_$nowMs',
        timestampMs: nowMs,
        indexName: sig.index.label,
        expiry: sig.expiry,
        strike: sig.strike,
        optionType: optionType,
        side: 'BUY',
        quantity: sig.lotSize,
        price: sig.entryPremium,
        status: 'Filled',
        mode: 'PAPER',
        reason: entryReason,
      );
      await ForeverDatabase.instance.saveOrder(paperOrder);
    }

    final position = PositionRecord(
      positionId: 'POS_$nowMs',
      securityId: securityId,
      indexName: sig.index.label,
      expiry: sig.expiry,
      strike: sig.strike,
      optionType: optionType,
      quantity: sig.lotSize,
      avgEntryPrice: sig.entryPremium,
      currentLtp: sig.entryPremium,
      stopLossPrice: sig.stopLossPremium,
      targetPrice: sig.targetPremium,
      isOpen: true,
      mode: modeStr,
      openedAtMs: nowMs,
    );

    await ForeverDatabase.instance.upsertPosition(position);
    await _refreshOperationalState();
      if (latestSignal == null || latestSignal!.strike == 0) {
        _evaluateLiveSignalForIndex(selectedIndex);
      }
    return true;
  }

  Future<void> closePosition(PositionRecord pos) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    if (tradingMode == TradingMode.live) {
      await DhanDataEngine.instance.placeLiveBrokerOrder(
        securityId: pos.securityId,
        index: selectedIndex,
        expiry: pos.expiry,
        strike: pos.strike,
        optionType: pos.optionType,
        transactionType: 'SELL',
        quantity: pos.quantity,
        price: pos.currentLtp,
        reason: 'Manual User Exit',
      );
    } else {
      final exitOrder = TradeOrder(
        orderId: 'EXIT_$nowMs',
        timestampMs: nowMs,
        indexName: pos.indexName,
        expiry: pos.expiry,
        strike: pos.strike,
        optionType: pos.optionType,
        side: 'SELL',
        quantity: pos.quantity,
        price: pos.currentLtp,
        status: 'Filled',
        mode: 'PAPER',
        reason: 'Manual User Exit',
      );
      await ForeverDatabase.instance.saveOrder(exitOrder);
    }

    final pnl = (pos.currentLtp - pos.avgEntryPrice) * pos.quantity;
    final closed = pos.copyWith(
      isOpen: false,
      closedAtMs: nowMs,
      realizedPnl: pnl,
    );

    if (pnl < 0) {
      todayRealizedLoss += pnl.abs();
    }

    await ForeverDatabase.instance.upsertPosition(closed);
    await _refreshOperationalState();
      if (latestSignal == null || latestSignal!.strike == 0) {
        _evaluateLiveSignalForIndex(selectedIndex);
      }
  }
}
