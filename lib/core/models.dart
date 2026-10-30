enum UnderlyingIndex { nifty50, bankNifty, finNifty }

extension UnderlyingIndexExt on UnderlyingIndex {
  String get label {
    switch (this) {
      case UnderlyingIndex.nifty50:
        return 'NIFTY 50';
      case UnderlyingIndex.bankNifty:
        return 'BANK NIFTY';
      case UnderlyingIndex.finNifty:
        return 'FINNIFTY';
    }
  }

  String get dhanSymbol {
    switch (this) {
      case UnderlyingIndex.nifty50:
        return 'NIFTY';
      case UnderlyingIndex.bankNifty:
        return 'BANKNIFTY';
      case UnderlyingIndex.finNifty:
        return 'FINNIFTY';
    }
  }

  int get securityId {
    switch (this) {
      case UnderlyingIndex.nifty50:
        return 13;
      case UnderlyingIndex.bankNifty:
        return 25;
      case UnderlyingIndex.finNifty:
        return 27;
    }
  }

  int get strikeStep {
    switch (this) {
      case UnderlyingIndex.nifty50:
        return 50;
      case UnderlyingIndex.bankNifty:
        return 100;
      case UnderlyingIndex.finNifty:
        return 50;
    }
  }

  int get fallbackLotSize {
    switch (this) {
      case UnderlyingIndex.nifty50:
        return 75;
      case UnderlyingIndex.bankNifty:
        return 30;
      case UnderlyingIndex.finNifty:
        return 65;
    }
  }
}

enum OptionType { ce, pe }

enum SignalAction { buyCe, buyPe, noTrade }

extension SignalActionExt on SignalAction {
  String get label {
    switch (this) {
      case SignalAction.buyCe:
        return 'BUY CE';
      case SignalAction.buyPe:
        return 'BUY PE';
      case SignalAction.noTrade:
        return 'NO TRADE';
    }
  }
}

enum TradingMode { paper, live }

/// T1: Explicit Order Lifecycle State Machine
enum OrderLifecycleState {
  submitted,
  pending,
  partiallyFilled,
  filled,
  rejected,
  cancelled,
  unknown,
}

extension OrderLifecycleStateExt on OrderLifecycleState {
  String get label {
    switch (this) {
      case OrderLifecycleState.submitted:
        return 'SUBMITTED';
      case OrderLifecycleState.pending:
        return 'PENDING';
      case OrderLifecycleState.partiallyFilled:
        return 'PARTIALLY_FILLED';
      case OrderLifecycleState.filled:
        return 'FILLED';
      case OrderLifecycleState.rejected:
        return 'REJECTED';
      case OrderLifecycleState.cancelled:
        return 'CANCELLED';
      case OrderLifecycleState.unknown:
        return 'UNKNOWN';
    }
  }

  bool get isTerminal =>
      this == OrderLifecycleState.filled ||
      this == OrderLifecycleState.rejected ||
      this == OrderLifecycleState.cancelled;
}

/// T1: Single unit-tested mapping table for Dhan broker order statuses.
/// Unmapped or missing status strictly maps to UNKNOWN, never FILLED.
OrderLifecycleState mapBrokerOrderStatus(String? rawStatus) {
  if (rawStatus == null) return OrderLifecycleState.unknown;
  switch (rawStatus.trim().toUpperCase()) {
    case 'TRADED':
    case 'FILLED':
    case 'COMPLETE':
      return OrderLifecycleState.filled;
    case 'PARTIALLY_TRADED':
    case 'PARTIALLY_FILLED':
    case 'PARTIAL':
      return OrderLifecycleState.partiallyFilled;
    case 'PENDING':
    case 'TRANSIT':
    case 'OPEN':
    case 'TRIGGER_PENDING':
    case 'AMO_REQ_RECEIVED':
      return OrderLifecycleState.pending;
    case 'REJECTED':
    case 'OMS_REJECTED':
    case 'RMS_REJECTED':
      return OrderLifecycleState.rejected;
    case 'CANCELLED':
    case 'EXPIRED':
      return OrderLifecycleState.cancelled;
    case 'SUBMITTED':
      return OrderLifecycleState.submitted;
    default:
      return OrderLifecycleState.unknown;
  }
}

enum MarketRegimeState {
  bullishAccumulation,
  bearishDistribution,
  choppyHighThetaTrap,
}

extension MarketRegimeStateExt on MarketRegimeState {
  String get label {
    switch (this) {
      case MarketRegimeState.bullishAccumulation:
        return 'Bullish';
      case MarketRegimeState.bearishDistribution:
        return 'Bearish';
      case MarketRegimeState.choppyHighThetaTrap:
        return 'Neutral (Choppy/Theta Trap)';
    }
  }
}

/// T3: Resolved Contract Metadata from Dhan Scrip Master
class ResolvedContract {
  final String numericSecurityId;
  final String tradingSymbol;
  final UnderlyingIndex index;
  final String expiryIso;
  final int strike;
  final OptionType optionType;
  final int lotSize;

  const ResolvedContract({
    required this.numericSecurityId,
    required this.tradingSymbol,
    required this.index,
    required this.expiryIso,
    required this.strike,
    required this.optionType,
    required this.lotSize,
  });
}

class OneMinEnrichedBar {
  final int timestampMs;
  final String indexName;
  final String expiry;
  final int strike;
  final String optionType;
  final int strikeOffset;
  final double underlyingSpot;
  final double open;
  final double high;
  final double low;
  final double close;
  final int intervalVolume;
  final int absoluteOi;
  final int oiChange1m;
  final int oiChange5m;
  final int oiChange15m;
  final int oiChange60m;
  final double iv;
  final double delta;
  final double gamma;
  final double theta;
  final double vega;
  final double spreadPct;
  final double orderBookImbalance;
  final double? next3mReturn;

  const OneMinEnrichedBar({
    required this.timestampMs,
    required this.indexName,
    required this.expiry,
    required this.strike,
    required this.optionType,
    required this.strikeOffset,
    required this.underlyingSpot,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.intervalVolume,
    required this.absoluteOi,
    required this.oiChange1m,
    required this.oiChange5m,
    required this.oiChange15m,
    required this.oiChange60m,
    required this.iv,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    required this.spreadPct,
    required this.orderBookImbalance,
    this.next3mReturn,
  });

  Map<String, dynamic> toMap() => {
        'timestamp_ms': timestampMs,
        'index_name': indexName,
        'expiry': expiry,
        'strike': strike,
        'option_type': optionType,
        'strike_offset': strikeOffset,
        'underlying_spot': underlyingSpot,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'interval_volume': intervalVolume,
        'absolute_oi': absoluteOi,
        'oi_change_1m': oiChange1m,
        'oi_change_5m': oiChange5m,
        'oi_change_15m': oiChange15m,
        'oi_change_60m': oiChange60m,
        'iv': iv,
        'delta': delta,
        'gamma': gamma,
        'theta': theta,
        'vega': vega,
        'spread_pct': spreadPct,
        'ob_imbalance': orderBookImbalance,
        'next_3m_return': next3mReturn,
      };

  factory OneMinEnrichedBar.fromMap(Map<String, dynamic> m) => OneMinEnrichedBar(
        timestampMs: m['timestamp_ms'] as int,
        indexName: m['index_name'] as String,
        expiry: m['expiry'] as String,
        strike: m['strike'] as int,
        optionType: m['option_type'] as String,
        strikeOffset: m['strike_offset'] as int,
        underlyingSpot: (m['underlying_spot'] as num).toDouble(),
        open: (m['open'] as num).toDouble(),
        high: (m['high'] as num).toDouble(),
        low: (m['low'] as num).toDouble(),
        close: (m['close'] as num).toDouble(),
        intervalVolume: m['interval_volume'] as int,
        absoluteOi: m['absolute_oi'] as int,
        oiChange1m: m['oi_change_1m'] as int,
        oiChange5m: m['oi_change_5m'] as int,
        oiChange15m: m['oi_change_15m'] as int,
        oiChange60m: m['oi_change_60m'] as int,
        iv: (m['iv'] as num).toDouble(),
        delta: (m['delta'] as num).toDouble(),
        gamma: (m['gamma'] as num).toDouble(),
        theta: (m['theta'] as num).toDouble(),
        vega: (m['vega'] as num).toDouble(),
        spreadPct: (m['spread_pct'] as num).toDouble(),
        orderBookImbalance: (m['ob_imbalance'] as num).toDouble(),
        next3mReturn: m['next_3m_return'] == null
            ? null
            : (m['next_3m_return'] as num).toDouble(),
      );
}

class StrikeRowSnapshot {
  final int strike;
  final int offset;
  final String ceSecurityId;
  final String peSecurityId;
  final int lotSize;
  final double ceLtp;
  final double peLtp;
  final int ceOi;
  final int peOi;
  final int ceOiChange5m;
  final int peOiChange5m;
  final int ceOiChange15m;
  final int peOiChange15m;
  final int ceOiChange60m;
  final int peOiChange60m;
  final int ceVolume;
  final int peVolume;
  final double ceIv;
  final double peIv;
  final double ceDelta;
  final double peDelta;
  final double ceGamma;
  final double ceTheta;
  final double ceVega;
  final double ceVanna;
  final double ceCharm;
  final double ceBid;
  final double ceAsk;
  final double peBid;
  final double peAsk;
  final double ceImbalance;
  final double peImbalance;
  final int lastUpdatedMs;

  const StrikeRowSnapshot({
    required this.strike,
    required this.offset,
    required this.ceSecurityId,
    required this.peSecurityId,
    this.lotSize = 75,
    required this.ceLtp,
    required this.peLtp,
    required this.ceOi,
    required this.peOi,
    required this.ceOiChange5m,
    required this.peOiChange5m,
    required this.ceOiChange15m,
    required this.peOiChange15m,
    required this.ceOiChange60m,
    required this.peOiChange60m,
    required this.ceVolume,
    required this.peVolume,
    required this.ceIv,
    required this.peIv,
    required this.ceDelta,
    required this.peDelta,
    required this.ceGamma,
    required this.ceTheta,
    required this.ceVega,
    this.ceVanna = 0.0,
    this.ceCharm = 0.0,
    required this.ceBid,
    required this.ceAsk,
    required this.peBid,
    required this.peAsk,
    required this.ceImbalance,
    required this.peImbalance,
    required this.lastUpdatedMs,
  });
}

class AiSignal {
  final int timestampMs;
  final UnderlyingIndex index;
  final String expiry;
  final int strike;
  final String securityId;
  final SignalAction action;
  final double confidencePct;
  final MarketRegimeState regimeState;
  final String htfOiReason;
  final List<String> reasons;
  final double entryPremium;
  final double stopLossPremium;
  final double targetPremium;
  final int lotSize;
  final double requiredCapital;
  final double availableCapital;
  final bool riskWithinLimits;
  final String riskNote;
  final String modelVersion;
  final int ltpTimestampMs;

  const AiSignal({
    required this.timestampMs,
    required this.index,
    required this.expiry,
    required this.strike,
    this.securityId = '',
    required this.action,
    required this.confidencePct,
    this.regimeState = MarketRegimeState.choppyHighThetaTrap,
    required this.htfOiReason,
    required this.reasons,
    required this.entryPremium,
    required this.stopLossPremium,
    required this.targetPremium,
    required this.lotSize,
    required this.requiredCapital,
    required this.availableCapital,
    required this.riskWithinLimits,
    required this.riskNote,
    required this.modelVersion,
    this.ltpTimestampMs = 0,
  });

  Map<String, dynamic> toMap() => {
        'timestamp_ms': timestampMs,
        'index_name': index.label,
        'expiry': expiry,
        'strike': strike,
        'action': action.label,
        'confidence_pct': confidencePct,
        'htf_oi_reason': htfOiReason,
        'reasons': reasons.join(' | '),
        'entry_premium': entryPremium,
        'sl_premium': stopLossPremium,
        'target_premium': targetPremium,
        'lot_size': lotSize,
        'required_capital': requiredCapital,
        'available_capital': availableCapital,
        'risk_ok': riskWithinLimits ? 1 : 0,
        'risk_note': riskNote,
        'model_version': modelVersion,
      };
}

class TradeOrder {
  final String orderId;
  final String correlationId;
  final int timestampMs;
  final String securityId;
  final String indexName;
  final String expiry;
  final int strike;
  final String optionType;
  final String side;
  final int requestedQty;
  final int filledQty;
  final double avgFillPrice;
  final OrderLifecycleState lifecycleState;
  final String mode;
  final String reason;

  const TradeOrder({
    required this.orderId,
    this.correlationId = '',
    required this.timestampMs,
    this.securityId = '',
    required this.indexName,
    required this.expiry,
    required this.strike,
    required this.optionType,
    required this.side,
    required this.requestedQty,
    required this.filledQty,
    required this.avgFillPrice,
    required this.lifecycleState,
    required this.mode,
    required this.reason,
  });

  int get quantity => filledQty > 0 ? filledQty : requestedQty;
  double get price => avgFillPrice;
  String get status => lifecycleState.label;

  Map<String, dynamic> toMap() => {
        'order_id': orderId,
        'correlation_id': correlationId,
        'timestamp_ms': timestampMs,
        'security_id': securityId,
        'index_name': indexName,
        'expiry': expiry,
        'strike': strike,
        'option_type': optionType,
        'side': side,
        'quantity': quantity,
        'filled_qty': filledQty,
        'price': avgFillPrice,
        'status': lifecycleState.label,
        'mode': mode,
        'reason': reason,
      };

  factory TradeOrder.fromMap(Map<String, dynamic> m) => TradeOrder(
        orderId: m['order_id'] as String,
        correlationId: (m['correlation_id'] ?? '') as String,
        timestampMs: m['timestamp_ms'] as int,
        securityId: (m['security_id'] ?? '') as String,
        indexName: m['index_name'] as String,
        expiry: m['expiry'] as String,
        strike: m['strike'] as int,
        optionType: m['option_type'] as String,
        side: m['side'] as String,
        requestedQty: m['quantity'] as int,
        filledQty: (m['filled_qty'] ?? m['quantity']) as int,
        avgFillPrice: (m['price'] as num).toDouble(),
        lifecycleState: mapBrokerOrderStatus(m['status'] as String?),
        mode: m['mode'] as String,
        reason: m['reason'] as String,
      );
}

class PositionRecord {
  final String positionId;
  final String securityId;
  final String indexName;
  final String expiry;
  final int strike;
  final String optionType;
  final int quantity;
  final double avgEntryPrice;
  final double currentLtp;
  final double stopLossPrice;
  final double targetPrice;
  final String? protectiveSlOrderId;
  final bool isOpen;
  final bool exitFailed;
  final String exitFailureNote;
  final String mode;
  final int openedAtMs;
  final int? closedAtMs;
  final double realizedPnl;

  const PositionRecord({
    required this.positionId,
    required this.securityId,
    required this.indexName,
    required this.expiry,
    required this.strike,
    required this.optionType,
    required this.quantity,
    required this.avgEntryPrice,
    required this.currentLtp,
    required this.stopLossPrice,
    required this.targetPrice,
    this.protectiveSlOrderId,
    required this.isOpen,
    this.exitFailed = false,
    this.exitFailureNote = '',
    required this.mode,
    required this.openedAtMs,
    this.closedAtMs,
    this.realizedPnl = 0.0,
  });

  double get unrealizedPnl => (currentLtp - avgEntryPrice) * quantity;
  double get pnlPct => avgEntryPrice > 0
      ? ((currentLtp - avgEntryPrice) / avgEntryPrice) * 100.0
      : 0.0;

  PositionRecord copyWith({
    double? currentLtp,
    bool? isOpen,
    bool? exitFailed,
    String? exitFailureNote,
    String? protectiveSlOrderId,
    int? closedAtMs,
    double? realizedPnl,
  }) =>
      PositionRecord(
        positionId: positionId,
        securityId: securityId,
        indexName: indexName,
        expiry: expiry,
        strike: strike,
        optionType: optionType,
        quantity: quantity,
        avgEntryPrice: avgEntryPrice,
        currentLtp: currentLtp ?? this.currentLtp,
        stopLossPrice: stopLossPrice,
        targetPrice: targetPrice,
        protectiveSlOrderId: protectiveSlOrderId ?? this.protectiveSlOrderId,
        isOpen: isOpen ?? this.isOpen,
        exitFailed: exitFailed ?? this.exitFailed,
        exitFailureNote: exitFailureNote ?? this.exitFailureNote,
        mode: mode,
        openedAtMs: openedAtMs,
        closedAtMs: closedAtMs ?? this.closedAtMs,
        realizedPnl: realizedPnl ?? this.realizedPnl,
      );

  Map<String, dynamic> toMap() => {
        'position_id': positionId,
        'security_id': securityId,
        'index_name': indexName,
        'expiry': expiry,
        'strike': strike,
        'option_type': optionType,
        'quantity': quantity,
        'avg_entry_price': avgEntryPrice,
        'current_ltp': currentLtp,
        'stop_loss_price': stopLossPrice,
        'target_price': targetPrice,
        'protective_sl_order_id': protectiveSlOrderId,
        'is_open': isOpen ? 1 : 0,
        'exit_failed': exitFailed ? 1 : 0,
        'exit_failure_note': exitFailureNote,
        'mode': mode,
        'opened_at_ms': openedAtMs,
        'closed_at_ms': closedAtMs,
        'realized_pnl': realizedPnl,
      };

  factory PositionRecord.fromMap(Map<String, dynamic> m) => PositionRecord(
        positionId: m['position_id'] as String,
        securityId: m['security_id'] as String,
        indexName: m['index_name'] as String,
        expiry: m['expiry'] as String,
        strike: m['strike'] as int,
        optionType: m['option_type'] as String,
        quantity: m['quantity'] as int,
        avgEntryPrice: (m['avg_entry_price'] as num).toDouble(),
        currentLtp: (m['current_ltp'] as num).toDouble(),
        stopLossPrice: (m['stop_loss_price'] as num).toDouble(),
        targetPrice: (m['target_price'] as num).toDouble(),
        protectiveSlOrderId: m['protective_sl_order_id'] as String?,
        isOpen: (m['is_open'] as int) == 1,
        exitFailed: ((m['exit_failed'] ?? 0) as int) == 1,
        exitFailureNote: (m['exit_failure_note'] ?? '') as String,
        mode: m['mode'] as String,
        openedAtMs: m['opened_at_ms'] as int,
        closedAtMs: m['closed_at_ms'] as int?,
        realizedPnl: (m['realized_pnl'] as num).toDouble(),
      );
}

class RiskConfig {
  final double maxRiskPerTradePct;
  final double maxDailyLossInr;
  final int maxConcurrentPositions;
  final double maxCapitalOutlayPct;
  final int maxOrderQty;
  final double maxOrderValueInr;
  final int maxLtpAgeSeconds;
  final bool enforceMarketHours;
  final bool killSwitchActive;

  const RiskConfig({
    this.maxRiskPerTradePct = 10.0,
    this.maxDailyLossInr = 2500.0,
    this.maxConcurrentPositions = 2,
    this.maxCapitalOutlayPct = 50.0,
    this.maxOrderQty = 300,
    this.maxOrderValueInr = 75000.0,
    this.maxLtpAgeSeconds = 5,
    this.enforceMarketHours = true,
    this.killSwitchActive = false,
  });

  RiskConfig copyWith({
    double? maxRiskPerTradePct,
    double? maxDailyLossInr,
    int? maxConcurrentPositions,
    double? maxCapitalOutlayPct,
    int? maxOrderQty,
    double? maxOrderValueInr,
    int? maxLtpAgeSeconds,
    bool? enforceMarketHours,
    bool? killSwitchActive,
  }) =>
      RiskConfig(
        maxRiskPerTradePct: maxRiskPerTradePct ?? this.maxRiskPerTradePct,
        maxDailyLossInr: maxDailyLossInr ?? this.maxDailyLossInr,
        maxConcurrentPositions:
            maxConcurrentPositions ?? this.maxConcurrentPositions,
        maxCapitalOutlayPct: maxCapitalOutlayPct ?? this.maxCapitalOutlayPct,
        maxOrderQty: maxOrderQty ?? this.maxOrderQty,
        maxOrderValueInr: maxOrderValueInr ?? this.maxOrderValueInr,
        maxLtpAgeSeconds: maxLtpAgeSeconds ?? this.maxLtpAgeSeconds,
        enforceMarketHours: enforceMarketHours ?? this.enforceMarketHours,
        killSwitchActive: killSwitchActive ?? this.killSwitchActive,
      );
}

class BacktestReport {
  final String strategyName;
  final String indexName;
  final String htfConfirmation;
  final int totalTrades;
  final double winRatePct;
  final double grossPnl;
  final double totalCharges;
  final double netPnl;
  final double profitFactor;
  final double maxDrawdown;
  final double expectancyPerTrade;
  final int rejectedByRiskCount;
  final List tradeLogs;
  final int runTimestampMs;

  const BacktestReport({
    required this.strategyName,
    required this.indexName,
    required this.htfConfirmation,
    required this.totalTrades,
    required this.winRatePct,
    required this.grossPnl,
    required this.totalCharges,
    required this.netPnl,
    required this.profitFactor,
    required this.maxDrawdown,
    required this.expectancyPerTrade,
    required this.rejectedByRiskCount,
    required this.tradeLogs,
    required this.runTimestampMs,
  });
}
