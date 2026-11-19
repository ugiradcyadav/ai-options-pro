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

  // LIVE mode stays locked until 15 real-data paper trading days & static-IP rules are verified
  static const bool liveTradingUnlocked = false;

  /// Default per-order liquidity cap: max 15% of observed top-of-book depth
  static const double defaultOrderVolumeRatio = 0.15;

  final Set<String> _inFlightCorrelationIds = {};

  /// Computes marketable limit price with protection cap (never raw MARKET orders)
  static double computeMarketableLimitPrice({
    required bool isBuy,
    required double ltp,
    double? bestBid,
    double? bestAsk,
  }) {
    final ref = isBuy
        ? ((bestAsk != null && bestAsk > 0) ? bestAsk : ltp)
        : ((bestBid != null && bestBid > 0) ? bestBid : ltp);
    final spread =
        (bestBid != null && bestAsk != null && bestAsk >= bestBid)
            ? (bestAsk - bestBid)
            : (ref * 0.004);
    final buffer = math.min(ref * 0.015, math.max(0.10, 2.0 * spread));
    final raw = isBuy ? (ref + buffer) : math.max(0.05, ref - buffer);
    return (raw * 20.0).round() / 20.0;
  }

  /// Calculates realistic filled quantity under [orderVolumeRatio] depth cap (snapped to lotSize)
  static int computeVolumeCappedFillQty({
    required int requestedQty,
    required int lotSize,
    int? topBookQty,
    double orderVolumeRatio = defaultOrderVolumeRatio,
  }) {
    if (requestedQty <= 0 || lotSize <= 0) return 0;
    if (topBookQty == null || topBookQty <= 0) return requestedQty;
    final maxAllowedRaw = (topBookQty * orderVolumeRatio).floor();
    final maxAllowedLots = (maxAllowedRaw ~/ lotSize) * lotSize;
    return math.min(requestedQty, maxAllowedLots);
  }

  /// Executes an entry order through: NEW -> SENT -> ACKED -> PARTIAL/FILLED / REJECTED / CANCELLED
  Future<ExecutionResult> executeEntry({
    required AiSignal signal,
    required TradingMode mode,
    double? bestBid,
    double? bestAsk,
    int? topBookAskQty,
    double orderVolumeRatio = defaultOrderVolumeRatio,
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
      return ExecutionResult(order: dup, success: false, message: dup.reason);
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
            'LIVE mode locked until 15 real-data paper trading days & static-IP rules are verified.',
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

      // Apply order_volume_ratio depth cap for realistic paper partial fills
      final filledQty = computeVolumeCappedFillQty(
        requestedQty: signal.quantity,
        lotSize: signal.lotSize,
        topBookQty: topBookAskQty,
        orderVolumeRatio: orderVolumeRatio,
      );

      if (filledQty <= 0) {
        order = order.copyWith(
          status: OrderLifecycleState.cancelled.label,
          filledQty: 0,
          reason:
              'CANCELLED: Top-of-book depth ($topBookAskQty) below ${(orderVolumeRatio * 100).toStringAsFixed(0)}% volume cap for 1 lot (${signal.lotSize})',
        );
        await ForeverDatabase.instance.saveOrder(order);
        return ExecutionResult(
            order: order, success: false, message: order.reason);
      }

      final fillPrice = (bestAsk != null && bestAsk > 0)
          ? math.min(limitPrice, bestAsk)
          : signal.entryPremium;

      final isPartial = filledQty < signal.quantity;
      order = order.copyWith(
        status: isPartial
            ? OrderLifecycleState.partial.label
            : OrderLifecycleState.filled.label,
        filledQty: filledQty,
        price: fillPrice,
        reason: isPartial
            ? 'PARTIAL FILL ($filledQty/${signal.quantity} qty capped by ${(orderVolumeRatio * 100).toStringAsFixed(0)}% depth ratio; remainder cancelled)'
            : signal.htfOiReason,
      );
      await ForeverDatabase.instance.saveOrder(order);

      final pos = PositionRecord(
        positionId: 'POS_$nowMs',
        securityId: signal.securityId,
        tradingSymbol: signal.tradingSymbol,
        indexName: signal.index.label,
        expiry: signal.expiry,
        strike: signal.strike,
        optionType: optType,
        quantity: filledQty,
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
        category: isPartial ? 'ORDER_PARTIAL' : 'ORDER_FILLED',
        message:
            'BUY ${pos.tradingSymbol} filled $filledQty/${signal.quantity} @ ₹${fillPrice.toStringAsFixed(2)} (Limit ₹${limitPrice.toStringAsFixed(2)})',
      );

      return ExecutionResult(
        order: order,
        position: pos,
        success: true,
        message: isPartial
            ? 'Partial Fill: $filledQty/${signal.quantity} qty @ ₹${fillPrice.toStringAsFixed(2)}'
            : 'Filled $filledQty qty @ ₹${fillPrice.toStringAsFixed(2)}',
      );
    } finally {
      _inFlightCorrelationIds.remove(corrId);
    }
  }

  /// Closes an open position with marketable limit SELL, preserving openedAtMs & persisting net P&L
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
