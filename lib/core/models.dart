enum UnderlyingIndex {
  nifty50('NIFTY 50', 'NIFTY', 50),
  bankNifty('BANK NIFTY', 'BANKNIFTY', 100),
  finNifty('FINNIFTY', 'FINNIFTY', 50),
  sensex('SENSEX', 'SENSEX', 100);

  final String label;
  final String dhanSymbol;
  final int strikeStep;

  const UnderlyingIndex(this.label, this.dhanSymbol, this.strikeStep);

  String get spotExchange => this == UnderlyingIndex.sensex ? 'BSE' : 'NSE';
  String get foExchange => this == UnderlyingIndex.sensex ? 'BFO' : 'NFO';
  int get wsSpotExchType => this == UnderlyingIndex.sensex ? 3 : 1;
  int get wsFoExchType => this == UnderlyingIndex.sensex ? 4 : 2;
}

enum OptionType { ce, pe }

enum TradingMode {
  paper('PAPER'),
  live('LIVE');

  final String label;
  const TradingMode(this.label);
}

enum DataHealthStatus {
  live('LIVE'),
  delayed('DELAYED'),
  disconnected('DISCONNECTED');

  final String label;
  const DataHealthStatus(this.label);
}

enum OrderLifecycleState {
  newOrder('NEW'),
  sent('SENT'),
  acked('ACKED'),
  partial('PARTIAL'),
  filled('FILLED'),
  rejected('REJECTED'),
  cancelled('CANCELLED'),
  unknown('UNKNOWN');

  final String label;
  const OrderLifecycleState(this.label);

  static OrderLifecycleState parse(String raw) {
    final s = raw.trim().toUpperCase();
    for (final v in OrderLifecycleState.values) {
      if (v.label == s) return v;
    }
    if (s.contains('FILL') && !s.contains('PART')) return filled;
    if (s.contains('PART')) return partial;
    if (s.contains('ACK') || s.contains('ACCEPT')) return acked;
    if (s.contains('REJ')) return rejected;
    if (s.contains('CANCEL')) return cancelled;
    if (s.contains('SENT') || s.contains('PEND')) return sent;
    return unknown;
  }
}

enum SignalAction {
  buyCe('BUY CE'),
  buyPe('BUY PE'),
  noTrade('NO TRADE');

  final String label;
  const SignalAction(this.label);
}

class DhanCredentials {
  final String clientId;
  final String accessToken;
  final String pin;
  final String totpSecret;
  final int tokenExpiryMs;

  const DhanCredentials({
    required this.clientId,
    required this.accessToken,
    this.pin = '',
    this.totpSecret = '',
    this.tokenExpiryMs = 0,
  });

  bool get isConfigured =>
      clientId.trim().isNotEmpty && accessToken.trim().isNotEmpty;
}

class RiskConfig {
  final double maxRiskPerTradePct;
  final double maxCapitalOutlayPct;
  final double maxDailyLossInr;
  final int maxConcurrentPositions;
  final bool killSwitchActive;

  const RiskConfig({
    this.maxRiskPerTradePct = 1.5,
    this.maxCapitalOutlayPct = 25.0,
    this.maxDailyLossInr = 2500.0,
    this.maxConcurrentPositions = 2,
    this.killSwitchActive = false,
  });

  RiskConfig copyWith({
    double? maxRiskPerTradePct,
    double? maxCapitalOutlayPct,
    double? maxDailyLossInr,
    int? maxConcurrentPositions,
    bool? killSwitchActive,
  }) {
    return RiskConfig(
      maxRiskPerTradePct: maxRiskPerTradePct ?? this.maxRiskPerTradePct,
      maxCapitalOutlayPct: maxCapitalOutlayPct ?? this.maxCapitalOutlayPct,
      maxDailyLossInr: maxDailyLossInr ?? this.maxDailyLossInr,
      maxConcurrentPositions:
          maxConcurrentPositions ?? this.maxConcurrentPositions,
      killSwitchActive: killSwitchActive ?? this.killSwitchActive,
    );
  }

  Map<String, dynamic> toMap() => {
        'max_risk_per_trade_pct': maxRiskPerTradePct,
        'max_capital_outlay_pct': maxCapitalOutlayPct,
        'max_daily_loss_inr': maxDailyLossInr,
        'max_concurrent_positions': maxConcurrentPositions,
        'kill_switch_active': killSwitchActive ? 1 : 0,
      };

  factory RiskConfig.fromMap(Map<String, dynamic> m) {
    return RiskConfig(
      maxRiskPerTradePct:
          ((m['max_risk_per_trade_pct'] ?? 1.5) as num).toDouble(),
      maxCapitalOutlayPct:
          ((m['max_capital_outlay_pct'] ?? 25.0) as num).toDouble(),
      maxDailyLossInr: ((m['max_daily_loss_inr'] ?? 2500.0) as num).toDouble(),
      maxConcurrentPositions:
          ((m['max_concurrent_positions'] ?? 2) as num).toInt(),
      killSwitchActive: ((m['kill_switch_active'] ?? 0) as num).toInt() == 1,
    );
  }
}

class StrikeRowSnapshot {
  final int strike;
  final int offset;
  final String ceSecurityId;
  final String peSecurityId;
  final String ceTradingSymbol;
  final String peTradingSymbol;
  final int lotSize;
  final double ceLtp;
  final double peLtp;
  final int ceOi; // Normalized to contracts (lots) at ingestion
  final int peOi;
  final int? ceOiChange5m; // Null until 5m of real snapshots exist
  final int? peOiChange5m;
  final int? ceOiChange15m; // Null until 15m of real snapshots exist
  final int? peOiChange15m;
  final int? ceOiChange60m; // Null until 60m of real snapshots exist
  final int? peOiChange60m;
  final int ceVolume;
  final int peVolume;
  final double? ceIv; // Null if solver failed
  final double? peIv;
  final double ceDelta;
  final double peDelta;
  final double ceGamma;
  final double peGamma;
  final double ceTheta;
  final double peTheta;
  final double ceVega;
  final double peVega;
  final double? ceBid;
  final double? ceAsk;
  final double? peBid;
  final double? peAsk;
  final int ceBidQty;
  final int ceAskQty;
  final int peBidQty;
  final int peAskQty;
  final double? ceImbalance;
  final double? peImbalance;
  final String source;
  final int exchangeTimestampMs;
  final int receivedAtMs;

  const StrikeRowSnapshot({
    required this.strike,
    required this.offset,
    required this.ceSecurityId,
    required this.peSecurityId,
    this.ceTradingSymbol = '',
    this.peTradingSymbol = '',
    required this.lotSize,
    required this.ceLtp,
    required this.peLtp,
    required this.ceOi,
    required this.peOi,
    this.ceOiChange5m,
    this.peOiChange5m,
    this.ceOiChange15m,
    this.peOiChange15m,
    this.ceOiChange60m,
    this.peOiChange60m,
    required this.ceVolume,
    required this.peVolume,
    this.ceIv,
    this.peIv,
    required this.ceDelta,
    required this.peDelta,
    required this.ceGamma,
    required this.peGamma,
    required this.ceTheta,
    required this.peTheta,
    required this.ceVega,
    required this.peVega,
    this.ceBid,
    this.ceAsk,
    this.peBid,
    this.peAsk,
    this.ceBidQty = 0,
    this.ceAskQty = 0,
    this.peBidQty = 0,
    this.peAskQty = 0,
    this.ceImbalance,
    this.peImbalance,
    required this.source,
    required this.exchangeTimestampMs,
    required this.receivedAtMs,
  });

  int get lastUpdatedMs => receivedAtMs;

  StrikeRowSnapshot copyWith({
    double? ceLtp,
    double? peLtp,
    int? ceOi,
    int? peOi,
    int? ceVolume,
    int? peVolume,
    double? ceBid,
    double? ceAsk,
    double? peBid,
    double? peAsk,
    int? ceBidQty,
    int? ceAskQty,
    int? peBidQty,
    int? peAskQty,
    double? ceImbalance,
    double? peImbalance,
    int? receivedAtMs,
    int? exchangeTimestampMs,
  }) {
    return StrikeRowSnapshot(
      strike: strike,
      offset: offset,
      ceSecurityId: ceSecurityId,
      peSecurityId: peSecurityId,
      ceTradingSymbol: ceTradingSymbol,
      peTradingSymbol: peTradingSymbol,
      lotSize: lotSize,
      ceLtp: ceLtp ?? this.ceLtp,
      peLtp: peLtp ?? this.peLtp,
      ceOi: ceOi ?? this.ceOi,
      peOi: peOi ?? this.peOi,
      ceOiChange5m: ceOiChange5m,
      peOiChange5m: peOiChange5m,
      ceOiChange15m: ceOiChange15m,
      peOiChange15m: peOiChange15m,
      ceOiChange60m: ceOiChange60m,
      peOiChange60m: peOiChange60m,
      ceVolume: ceVolume ?? this.ceVolume,
      peVolume: peVolume ?? this.peVolume,
      ceIv: ceIv,
      peIv: peIv,
      ceDelta: ceDelta,
      peDelta: peDelta,
      ceGamma: ceGamma,
      peGamma: peGamma,
      ceTheta: ceTheta,
      peTheta: peTheta,
      ceVega: ceVega,
      peVega: peVega,
      ceBid: ceBid ?? this.ceBid,
      ceAsk: ceAsk ?? this.ceAsk,
      peBid: peBid ?? this.peBid,
      peAsk: peAsk ?? this.peAsk,
      ceBidQty: ceBidQty ?? this.ceBidQty,
      ceAskQty: ceAskQty ?? this.ceAskQty,
      peBidQty: peBidQty ?? this.peBidQty,
      peAskQty: peAskQty ?? this.peAskQty,
      ceImbalance: ceImbalance ?? this.ceImbalance,
      peImbalance: peImbalance ?? this.peImbalance,
      source: source,
      exchangeTimestampMs: exchangeTimestampMs ?? this.exchangeTimestampMs,
      receivedAtMs: receivedAtMs ?? this.receivedAtMs,
    );
  }
}

class OneMinEnrichedBar {
  final int timestampMs;
  final String contractId;
  final String indexName;
  final String expiry;
  final int strike;
  final String optionType; // 'CE', 'PE', or 'SPOT'
  final int strikeOffset;
  final double underlyingSpot;
  final double open;
  final double high;
  final double low;
  final double close;
  final int intervalVolume;
  final int absoluteOi;
  final int? oiChange1m;
  final int? oiChange5m;
  final int? oiChange15m;
  final int? oiChange60m;
  final double? iv;
  final double delta;
  final double gamma;
  final double theta;
  final double vega;
  final double? spreadPct;
  final double? orderBookImbalance;
  final double next3mReturn;

  const OneMinEnrichedBar({
    required this.timestampMs,
    this.contractId = '',
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
    this.oiChange1m,
    this.oiChange5m,
    this.oiChange15m,
    this.oiChange60m,
    this.iv,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    this.spreadPct,
    this.orderBookImbalance,
    this.next3mReturn = 0.0,
  });

  Map<String, dynamic> toMap() => {
        'timestamp_ms': timestampMs,
        'contract_id': contractId.isNotEmpty
            ? contractId
            : '${indexName}_${expiry}_${strike}_$optionType',
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
        'order_book_imbalance': orderBookImbalance,
        'next_3m_return': next3mReturn,
      };

  factory OneMinEnrichedBar.fromMap(Map<String, dynamic> m) {
    return OneMinEnrichedBar(
      timestampMs: ((m['timestamp_ms'] ?? 0) as num).toInt(),
      contractId: (m['contract_id'] ?? '').toString(),
      indexName: (m['index_name'] ?? '').toString(),
      expiry: (m['expiry'] ?? '').toString(),
      strike: ((m['strike'] ?? 0) as num).toInt(),
      optionType: (m['option_type'] ?? 'CE').toString(),
      strikeOffset: ((m['strike_offset'] ?? 0) as num).toInt(),
      underlyingSpot: ((m['underlying_spot'] ?? 0) as num).toDouble(),
      open: ((m['open'] ?? 0) as num).toDouble(),
      high: ((m['high'] ?? 0) as num).toDouble(),
      low: ((m['low'] ?? 0) as num).toDouble(),
      close: ((m['close'] ?? 0) as num).toDouble(),
      intervalVolume: ((m['interval_volume'] ?? 0) as num).toInt(),
      absoluteOi: ((m['absolute_oi'] ?? 0) as num).toInt(),
      oiChange1m: (m['oi_change_1m'] as num?)?.toInt(),
      oiChange5m: (m['oi_change_5m'] as num?)?.toInt(),
      oiChange15m: (m['oi_change_15m'] as num?)?.toInt(),
      oiChange60m: (m['oi_change_60m'] as num?)?.toInt(),
      iv: (m['iv'] as num?)?.toDouble(),
      delta: ((m['delta'] ?? 0) as num).toDouble(),
      gamma: ((m['gamma'] ?? 0) as num).toDouble(),
      theta: ((m['theta'] ?? 0) as num).toDouble(),
      vega: ((m['vega'] ?? 0) as num).toDouble(),
      spreadPct: (m['spread_pct'] as num?)?.toDouble(),
      orderBookImbalance: (m['order_book_imbalance'] as num?)?.toDouble(),
      next3mReturn: ((m['next_3m_return'] ?? 0) as num).toDouble(),
    );
  }
}

class AiSignal {
  final int timestampMs;
  final UnderlyingIndex index;
  final String expiry;
  final String securityId;
  final String tradingSymbol;
  final int strike;
  final SignalAction action;
  final double confidencePct;
  final String htfOiReason;
  final List<String> reasons;
  final double entryPremium;
  final double stopLossPremium;
  final double targetPremium;
  final int lotSize;
  final int quantity;
  final double requiredCapital;
  final double availableCapital;
  final bool strategyPassed;
  final bool riskWithinLimits;
  final String riskNote;
  final String modelVersion;

  const AiSignal({
    required this.timestampMs,
    required this.index,
    required this.expiry,
    this.securityId = '',
    this.tradingSymbol = '',
    required this.strike,
    required this.action,
    required this.confidencePct,
    required this.htfOiReason,
    required this.reasons,
    required this.entryPremium,
    required this.stopLossPremium,
    required this.targetPremium,
    required this.lotSize,
    this.quantity = 0,
    required this.requiredCapital,
    required this.availableCapital,
    this.strategyPassed = false,
    required this.riskWithinLimits,
    required this.riskNote,
    required this.modelVersion,
  });
}

class TradeOrder {
  final String orderId;
  final String clientCorrelationId;
  final int timestampMs;
  final String securityId;
  final String tradingSymbol;
  final String indexName;
  final String expiry;
  final int strike;
  final String optionType;
  final String side; // 'BUY' or 'SELL'
  final int quantity;
  final int filledQty; // WP-6: Required NOT NULL column
  final double price;
  final double limitPrice;
  final String status;
  final String mode; // 'PAPER' or 'LIVE'
  final String reason;
  final bool legacyUnverified;

  const TradeOrder({
    required this.orderId,
    this.clientCorrelationId = '',
    required this.timestampMs,
    this.securityId = '',
    this.tradingSymbol = '',
    required this.indexName,
    required this.expiry,
    required this.strike,
    required this.optionType,
    required this.side,
    required this.quantity,
    this.filledQty = 0,
    required this.price,
    this.limitPrice = 0.0,
    required this.status,
    required this.mode,
    required this.reason,
    this.legacyUnverified = false,
  });

  OrderLifecycleState get lifecycleState => OrderLifecycleState.parse(status);

  TradeOrder copyWith({
    String? orderId,
    int? filledQty,
    double? price,
    String? status,
    String? reason,
  }) {
    return TradeOrder(
      orderId: orderId ?? this.orderId,
      clientCorrelationId: clientCorrelationId,
      timestampMs: timestampMs,
      securityId: securityId,
      tradingSymbol: tradingSymbol,
      indexName: indexName,
      expiry: expiry,
      strike: strike,
      optionType: optionType,
      side: side,
      quantity: quantity,
      filledQty: filledQty ?? this.filledQty,
      price: price ?? this.price,
      limitPrice: limitPrice,
      status: status ?? this.status,
      mode: mode,
      reason: reason ?? this.reason,
      legacyUnverified: legacyUnverified,
    );
  }

  Map<String, dynamic> toMap() => {
        'order_id': orderId,
        'client_correlation_id': clientCorrelationId,
        'timestamp_ms': timestampMs,
        'security_id': securityId,
        'trading_symbol': tradingSymbol,
        'index_name': indexName,
        'expiry': expiry,
        'strike': strike,
        'option_type': optionType,
        'side': side,
        'quantity': quantity,
        'filled_qty': filledQty,
        'price': price,
        'limit_price': limitPrice,
        'status': status,
        'mode': mode,
        'reason': reason,
        'legacy_unverified': legacyUnverified ? 1 : 0,
      };

  factory TradeOrder.fromMap(Map<String, dynamic> m) {
    return TradeOrder(
      orderId: (m['order_id'] ?? '').toString(),
      clientCorrelationId: (m['client_correlation_id'] ?? '').toString(),
      timestampMs: ((m['timestamp_ms'] ?? 0) as num).toInt(),
      securityId: (m['security_id'] ?? '').toString(),
      tradingSymbol: (m['trading_symbol'] ?? '').toString(),
      indexName: (m['index_name'] ?? '').toString(),
      expiry: (m['expiry'] ?? '').toString(),
      strike: ((m['strike'] ?? 0) as num).toInt(),
      optionType: (m['option_type'] ?? 'CE').toString(),
      side: (m['side'] ?? 'BUY').toString(),
      quantity: ((m['quantity'] ?? 0) as num).toInt(),
      filledQty: ((m['filled_qty'] ?? 0) as num).toInt(),
      price: ((m['price'] ?? 0) as num).toDouble(),
      limitPrice: ((m['limit_price'] ?? 0) as num).toDouble(),
      status: (m['status'] ?? 'UNKNOWN').toString(),
      mode: (m['mode'] ?? 'PAPER').toString(),
      reason: (m['reason'] ?? '').toString(),
      legacyUnverified: ((m['legacy_unverified'] ?? 0) as num).toInt() == 1,
    );
  }
}

class PositionRecord {
  final String positionId;
  final String securityId;
  final String tradingSymbol;
  final String indexName;
  final String expiry;
  final int strike;
  final String optionType;
  final int quantity;
  final double avgEntryPrice;
  final double currentLtp;
  final double stopLossPrice; // WP-2 & WP-6: Real stored stop-loss, never hardcoded 0.90
  final double targetPrice; // WP-2 & WP-6: Real stored target, never hardcoded 1.18
  final int openedAtMs;
  final int? closedAtMs;
  final String status; // 'OPEN' or 'CLOSED'
  final String mode; // 'PAPER' or 'LIVE'
  final double realizedPnl;
  final bool legacyUnverified;

  const PositionRecord({
    required this.positionId,
    required this.securityId,
    this.tradingSymbol = '',
    required this.indexName,
    required this.expiry,
    required this.strike,
    required this.optionType,
    required this.quantity,
    required this.avgEntryPrice,
    required this.currentLtp,
    required this.stopLossPrice,
    required this.targetPrice,
    required this.openedAtMs,
    this.closedAtMs,
    required this.status,
    required this.mode,
    this.realizedPnl = 0.0,
    this.legacyUnverified = false,
  });

  bool get isOpen => status.toUpperCase() == 'OPEN';
  double get stopLoss => stopLossPrice;
  double get target => targetPrice;
  double get unrealizedPnl =>
      isOpen ? ((currentLtp - avgEntryPrice) * quantity) : realizedPnl;

  PositionRecord copyWith({
    double? currentLtp,
    double? stopLossPrice,
    double? targetPrice,
    int? closedAtMs,
    String? status,
    double? realizedPnl,
  }) {
    return PositionRecord(
      positionId: positionId,
      securityId: securityId,
      tradingSymbol: tradingSymbol,
      indexName: indexName,
      expiry: expiry,
      strike: strike,
      optionType: optionType,
      quantity: quantity,
      avgEntryPrice: avgEntryPrice,
      currentLtp: currentLtp ?? this.currentLtp,
      stopLossPrice: stopLossPrice ?? this.stopLossPrice,
      targetPrice: targetPrice ?? this.targetPrice,
      openedAtMs: openedAtMs, // WP-6: Never overwrite openedAtMs on update/close
      closedAtMs: closedAtMs ?? this.closedAtMs,
      status: status ?? this.status,
      mode: mode,
      realizedPnl: realizedPnl ?? this.realizedPnl,
      legacyUnverified: legacyUnverified,
    );
  }

  Map<String, dynamic> toMap() => {
        'position_id': positionId,
        'security_id': securityId,
        'trading_symbol': tradingSymbol,
        'index_name': indexName,
        'expiry': expiry,
        'strike': strike,
        'option_type': optionType,
        'quantity': quantity,
        'avg_entry_price': avgEntryPrice,
        'current_ltp': currentLtp,
        'stop_loss_price': stopLossPrice,
        'target_price': targetPrice,
        'opened_at_ms': openedAtMs,
        'closed_at_ms': closedAtMs,
        'status': status,
        'mode': mode,
        'realized_pnl': realizedPnl,
        'legacy_unverified': legacyUnverified ? 1 : 0,
      };

  factory PositionRecord.fromMap(Map<String, dynamic> m) {
    return PositionRecord(
      positionId: (m['position_id'] ?? '').toString(),
      securityId: (m['security_id'] ?? '').toString(),
      tradingSymbol: (m['trading_symbol'] ?? '').toString(),
      indexName: (m['index_name'] ?? '').toString(),
      expiry: (m['expiry'] ?? '').toString(),
      strike: ((m['strike'] ?? 0) as num).toInt(),
      optionType: (m['option_type'] ?? 'CE').toString(),
      quantity: ((m['quantity'] ?? 0) as num).toInt(),
      avgEntryPrice: ((m['avg_entry_price'] ?? 0) as num).toDouble(),
      currentLtp: ((m['current_ltp'] ?? 0) as num).toDouble(),
      stopLossPrice:
          ((m['stop_loss_price'] ?? m['stop_loss'] ?? 0) as num).toDouble(),
      targetPrice:
          ((m['target_price'] ?? m['target'] ?? 0) as num).toDouble(),
      openedAtMs:
          ((m['opened_at_ms'] ?? m['open_timestamp_ms'] ?? 0) as num).toInt(),
      closedAtMs: (m['closed_at_ms'] as num?)?.toInt(),
      status: (m['status'] ?? 'OPEN').toString(),
      mode: (m['mode'] ?? 'PAPER').toString(),
      realizedPnl: ((m['realized_pnl'] ?? 0) as num).toDouble(),
      legacyUnverified: ((m['legacy_unverified'] ?? 0) as num).toInt() == 1,
    );
  }
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
