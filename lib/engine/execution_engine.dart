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

  // Strictly Paper-only until Phase 2 real broker order adapter + Phase 5 unlock gates pass
  static const bool liveTradingUnlocked = false;

  /// Default per-order liquidity cap: max 15% of observed top-of-book depth
  static const double defaultOrderVolumeRatio = 0.15;

  final Set<String> _inFlightCorrelationIds = {};
  final Set<String> _completedCorrelationIds = {};
  final Set<String> _closingPositionIds = {};
  final Set<String> _closedPositionIds = {};

  void clearSessionLocks() {
    _inFlightCorrelationIds.clear();
    _completedCorrelationIds.clear();
    _closingPositionIds.clear();
    _closedPositionIds.clear();
  }

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

  /// Executes an entry order with deterministic idempotency (C5) & Paper-only lock (C6)
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
    final minuteBucket = nowMs ~/ 60000;
    final corrId = correlationIdOverride ??
        'ENT_${signal.securityId}_${signal.strike}_${optType}_$minuteBucket';

    if (_inFlightCorrelationIds.contains(corrId) ||
        _completedCorrelationIds.contains(corrId)) {
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
        reason: 'Idempotency guard blocked duplicate entry ($corrId)',
      );
      return ExecutionResult(order: dup, success: false, message: dup.reason);
    }

    if (mode == TradingMode.live) {
      if (!liveTradingUnlocked) {
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
              'Sadhu AI is Paper-only until Phase 2 real broker adapter & unlock gates pass.',
        );
        await ForeverDatabase.instance.saveOrder(blocked);
        return ExecutionResult(
            order: blocked, success: false, message: blocked.reason);
      }
      throw UnsupportedError(
          'Sadhu AI Phase 1 has no live broker order adapter. Live execution is prohibited.');
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
              'CANCELLED: Top-of-book depth ($topBookAskQty) below ${(orderVolumeRatio * 100).toStringAsFixed(0)}% cap for 1 lot (${signal.lotSize})',
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
            ? 'PARTIAL FILL ($filledQty/${signal.quantity}) capped by ${(orderVolumeRatio * 100).toStringAsFixed(0)}% depth'
            : signal.htfOiReason,
      );
      await ForeverDatabase.instance.saveOrder(order);

      final pos = PositionRecord(
        positionId: 'POS_${nowMs}_${signal.securityId}',
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
      _completedCorrelationIds.add(corrId);

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

  /// Idempotent position exit (C4 fix) + no bid/ask slippage double-count (H2 fix)
  Future<ExecutionResult> executeExit({
    required PositionRecord position,
    required double currentLtp,
    double? bestBid,
    double? bestAsk,
    required String exitReason,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final corrId = 'EXT_${position.positionId}';

    if (!position.isOpen ||
        _closingPositionIds.contains(position.positionId) ||
        _closedPositionIds.contains(position.positionId)) {
      final dup = TradeOrder(
        orderId: 'DUP_EXIT_$nowMs',
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
        filledQty: 0,
        price: currentLtp,
        limitPrice: currentLtp,
        status: OrderLifecycleState.rejected.label,
        mode: position.mode,
        reason: 'Idempotent exit guard: position ${position.positionId} already closing/closed',
      );
      return ExecutionResult(
        order: dup,
        position: position,
        success: false,
        message: dup.reason,
      );
    }

    if (position.mode.toUpperCase() == 'LIVE' && !liveTradingUnlocked) {
      throw UnsupportedError(
          'Sadhu AI Phase 1 prohibits simulated exits for LIVE positions.');
    }

    _closingPositionIds.add(position.positionId);
    try {
      // Double-check DB status so stale memory objects can never close twice
      try {
        final dbPositions = await ForeverDatabase.instance.getAllPositions();
        final match = dbPositions
            .where((p) => p.positionId == position.positionId)
            .toList();
        if (match.isNotEmpty && !match.first.isOpen) {
          _closedPositionIds.add(position.positionId);
          final already = TradeOrder(
            orderId: 'DUP_DB_EXIT_$nowMs',
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
            filledQty: 0,
            price: currentLtp,
            limitPrice: currentLtp,
            status: OrderLifecycleState.rejected.label,
            mode: position.mode,
            reason: 'DB guard: position ${position.positionId} already CLOSED',
          );
          return ExecutionResult(
            order: already,
            position: match.first,
            success: false,
            message: already.reason,
          );
        }
      } catch (_) {}

      final limitPrice = computeMarketableLimitPrice(
        isBuy: false,
        ltp: currentLtp,
        bestBid: bestBid,
        bestAsk: bestAsk,
      );

      final usedRealBid = bestBid != null && bestBid > 0;
      final fillPrice =
          usedRealBid ? math.max(limitPrice, bestBid) : currentLtp;

      final costs = RiskEngine.computeRoundTripCostsAndSlippage(
        entryPremium: position.avgEntryPrice,
        exitPremium: fillPrice,
        quantity: position.quantity,
      );

      // H2 Fix: When crossing real displayed Bid/Ask, do not subtract modelled slippage twice
      final appliedCosts = usedRealBid
          ? costs.totalStatutoryChargesInr
          : costs.totalFrictionInr;

      final netPnl =
          ((fillPrice - position.avgEntryPrice) * position.quantity) -
              appliedCosts;

      final closeOrder = TradeOrder(
        orderId: 'EXIT_${nowMs}_${position.securityId}',
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
      _closedPositionIds.add(position.positionId);

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
    } finally {
      _closingPositionIds.remove(position.positionId);
    }
  }
}
