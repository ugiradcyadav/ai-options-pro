import 'dart:math' as math;
import '../core/models.dart';
import '../data/forever_db.dart';
import 'risk_engine.dart';

class ExecutionResult {
  final TradeOrder order;
  final PositionRecord? position;
  final bool success;
  final String message;

  const ExecutionResult({
    required this.order,
    this.position,
    required this.success,
    required this.message,
  });
}

class ExecutionEngine {
  static final ExecutionEngine instance = ExecutionEngine._();
  ExecutionEngine._();

  // WP-6 Non-Negotiable Rule: LIVE mode stays disabled until WP-1..WP-6 & 15 trading days paper run complete
  static const bool liveTradingUnlocked = false;

  final Set<String> _inFlightCorrelationIds = {};

  /// WP-6: Computes marketable limit price with protection cap (never raw MARKET orders)
  static double computeMarketableLimitPrice({
    required bool isBuy,
    required double ltp,
    double? bestBid,
    double? bestAsk,
  }) {
    final ref = isBuy
        ? ((bestAsk != null && bestAsk > 0) ? bestAsk : ltp)
        : ((bestBid != null && bestBid > 0) ? bestBid : ltp);
    final spread = (bestBid != null && bestAsk != null && bestAsk >= bestBid)
        ? (bestAsk - bestBid)
        : (ref * 0.004);
    final buffer = math.min(ref * 0.015, math.max(0.10, 2.0 * spread));
    final raw = isBuy ? (ref + buffer) : math.max(0.05, ref - buffer);
    // Round to NSE 0.05 tick size
    return (raw * 20.0).round() / 20.0;
  }

  /// Executes an entry order through strict state machine: NEW -> SENT -> ACKED -> FILLED / REJECTED
  Future<ExecutionResult> executeEntry({
    required AiSignal signal,
    required TradingMode mode,
    double? bestBid,
    double? bestAsk,
    String? correlationIdOverride,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final optType = signal.action == SignalAction.buyCe ? 'CE' : 'PE';
    final corrId = correlationIdOverride ??
        'ENT_${signal.securityId}_${signal.strike}_$nowMs';

    if (_inFlightCorrelationIds.contains(corrId)) {
      final dup = TradeOrder(
        orderId: 'DUP_$nowMs',
        clientCorrelationId: corrId,
        timestampMs: nowMs,
        securityId: signal.securityId,
        tradingSymbol: signal.tradingSymbol,
        indexName: signal.index.label,
        expiry: signal.expiry,
        strike: signal.strike,
        optionType: optType,
        side: 'BUY',
        quantity: signal.quantity,
        filledQty: 0,
        price: signal.entryPremium,
        limitPrice: signal.entryPremium,
        status: OrderLifecycleState.rejected.label,
        mode: mode.label,
        reason: 'Idempotency guard blocked duplicate correlation ID',
      );
      return ExecutionResult(
          order: dup, success: false, message: dup.reason);
    }

    if (mode == TradingMode.live && !liveTradingUnlocked) {
      final blocked = TradeOrder(
        orderId: 'BLK_$nowMs',
        clientCorrelationId: corrId,
        timestampMs: nowMs,
        securityId: signal.securityId,
        tradingSymbol: signal.tradingSymbol,
        indexName: signal.index.label,
        expiry: signal.expiry,
        strike: signal.strike,
        optionType: optType,
        side: 'BUY',
        quantity: signal.quantity,
        filledQty: 0,
        price: signal.entryPremium,
        limitPrice: signal.entryPremium,
        status: OrderLifecycleState.rejected.label,
        mode: mode.label,
        reason:
            'LIVE mode locked until 15 real-data paper trading days & static-IP requirement are verified.',
      );
      await ForeverDatabase.instance.saveOrder(blocked);
      return ExecutionResult(
          order: blocked, success: false, message: blocked.reason);
    }

    if (!signal.riskWithinLimits ||
        !signal.strategyPassed ||
        signal.quantity <= 0 ||
        signal.securityId.isEmpty) {
      final rej = TradeOrder(
        orderId: 'REJ_$nowMs',
        clientCorrelationId: corrId,
        timestampMs: nowMs,
        securityId: signal.securityId,
        tradingSymbol: signal.tradingSymbol,
        indexName: signal.index.label,
        expiry: signal.expiry,
        strike: signal.strike,
        optionType: optType,
        side: 'BUY',
        quantity: signal.quantity,
        filledQty: 0,
        price: signal.entryPremium,
        limitPrice: signal.entryPremium,
        status: OrderLifecycleState.rejected.label,
        mode: mode.label,
        reason: signal.riskNote,
      );
      await ForeverDatabase.instance.saveOrder(rej);
      return ExecutionResult(order: rej, success: false, message: rej.reason);
    }

    _inFlightCorrelationIds.add(corrId);
    try {
      final limitPrice = computeMarketableLimitPrice(
        isBuy: true,
        ltp: signal.entryPremium,
        bestBid: bestBid,
        bestAsk: bestAsk,
      );

      // State 1: NEW -> SENT
      var order = TradeOrder(
        orderId: 'ORD_$nowMs',
        clientCorrelationId: corrId,
        timestampMs: nowMs,
        securityId: signal.securityId,
        tradingSymbol: signal.tradingSymbol,
        indexName: signal.index.label,
        expiry: signal.expiry,
        strike: signal.strike,
        optionType: optType,
        side: 'BUY',
        quantity: signal.quantity,
        filledQty: 0,
        price: signal.entryPremium,
        limitPrice: limitPrice,
        status: OrderLifecycleState.sent.label,
        mode: mode.label,
        reason: signal.htfOiReason,
      );
      await ForeverDatabase.instance.saveOrder(order);

      // Quote-driven realistic Paper Fill: fills at live Ask (never better than ask), capped by limitPrice
      final fillPrice = (bestAsk != null && bestAsk > 0)
          ? math.min(limitPrice, bestAsk)
          : signal.entryPremium;

      order = order.copyWith(
        status: OrderLifecycleState.filled.label,
        filledQty: signal.quantity,
        price: fillPrice,
      );
      await ForeverDatabase.instance.saveOrder(order);

      // WP-6: Construct typed PositionRecord directly (never hand-made Map)
      final pos = PositionRecord(
        positionId: 'POS_$nowMs',
        securityId: signal.securityId,
        tradingSymbol: signal.tradingSymbol,
        indexName: signal.index.label,
        expiry: signal.expiry,
        strike: signal.strike,
        optionType: optType,
        quantity: signal.quantity,
        avgEntryPrice: fillPrice,
        currentLtp: fillPrice,
        stopLossPrice: signal.stopLossPremium,
        targetPrice: signal.targetPremium,
        openedAtMs: nowMs,
        status: 'OPEN',
        mode: mode.label,
        realizedPnl: 0.0,
      );
      await ForeverDatabase.instance.upsertPosition(pos);
      await ForeverDatabase.instance.logAuditEvent(
        category: 'ORDER_FILLED',
        message:
            'BUY ${pos.tradingSymbol} qty=${pos.quantity} @ ₹${fillPrice.toStringAsFixed(2)} (Limit ₹${limitPrice.toStringAsFixed(2)})',
      );

      return ExecutionResult(
        order: order,
        position: pos,
        success: true,
        message: 'Filled ${pos.quantity} qty @ ₹${fillPrice.toStringAsFixed(2)}',
      );
    } finally {
      _inFlightCorrelationIds.remove(corrId);
    }
  }

  /// WP-6: Closes an open position with marketable limit SELL, preserving openedAtMs & persisting net P&L
  Future<ExecutionResult> executeExit({
    required PositionRecord position,
    required double currentLtp,
    double? bestBid,
    double? bestAsk,
    required String exitReason,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final corrId = 'EXT_${position.positionId}_$nowMs';
    final limitPrice = computeMarketableLimitPrice(
      isBuy: false,
      ltp: currentLtp,
      bestBid: bestBid,
      bestAsk: bestAsk,
    );

    // Quote-driven Paper Exit fills at live Bid
    final fillPrice = (bestBid != null && bestBid > 0)
        ? math.max(limitPrice, bestBid)
        : currentLtp;

    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: position.avgEntryPrice,
      exitPremium: fillPrice,
      quantity: position.quantity,
    );
    final netPnl =
        ((fillPrice - position.avgEntryPrice) * position.quantity) -
            costs.totalFrictionInr;

    final closeOrder = TradeOrder(
      orderId: 'EXIT_$nowMs',
      clientCorrelationId: corrId,
      timestampMs: nowMs,
      securityId: position.securityId,
      tradingSymbol: position.tradingSymbol,
      indexName: position.indexName,
      expiry: position.expiry,
      strike: position.strike,
      optionType: position.optionType,
      side: 'SELL',
      quantity: position.quantity,
      filledQty: position.quantity,
      price: fillPrice,
      limitPrice: limitPrice,
      status: OrderLifecycleState.filled.label,
      mode: position.mode,
      reason: '$exitReason (Net ₹${netPnl.toStringAsFixed(2)})',
    );
    await ForeverDatabase.instance.saveOrder(closeOrder);

    final closedPos = position.copyWith(
      status: 'CLOSED',
      currentLtp: fillPrice,
      closedAtMs: nowMs,
      realizedPnl: netPnl,
    );
    await ForeverDatabase.instance.upsertPosition(closedPos);
    await ForeverDatabase.instance.logAuditEvent(
      category: 'POSITION_CLOSED',
      message:
          'SELL ${position.tradingSymbol} qty=${position.quantity} @ ₹${fillPrice.toStringAsFixed(2)} | Reason: $exitReason | Net ₹${netPnl.toStringAsFixed(2)}',
    );

    return ExecutionResult(
      order: closeOrder,
      position: closedPos,
      success: true,
      message: '$exitReason • Net ₹${netPnl.toStringAsFixed(2)}',
    );
  }
}
