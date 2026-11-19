import 'dart:math' as math;
import '../core/models.dart';
import 'strategy_settings.dart';

/// WP-6: Dated Indian NFO Options Statutory Cost Schedule (Verify against broker contract note)
class IndianOptionCostConfig {
  static const String effectiveDate = '2026-04-01';
  static const double brokeragePerOrderInr = 20.0;
  static const double sttSellOptionRate = 0.0015; // 0.15% on sell option premium (effective 1 Apr 2026)
  static const double nseExchangeTxnRate = 0.0003503; // 0.03503% on buy + sell premium turnover
  static const double sebiTurnoverRate = 0.000001; // Rs 10 per crore
  static const double stampDutyBuyRate = 0.00003; // 0.003% on buy turnover
  static const double gstRate = 0.18; // 18% on (brokerage + exchange txn + SEBI)
  static const double maxPermittedSpreadPct = 0.80; // Block illiquid spreads > 0.80%
}

class OrderCostBreakdown {
  final double brokerageInr;
  final double sttInr;
  final double exchangeTxnInr;
  final double sebiFeesInr;
  final double stampDutyInr;
  final double gstInr;
  final double entrySlippageInr;
  final double exitSlippageInr;

  const OrderCostBreakdown({
    required this.brokerageInr,
    required this.sttInr,
    required this.exchangeTxnInr,
    required this.sebiFeesInr,
    required this.stampDutyInr,
    required this.gstInr,
    required this.entrySlippageInr,
    required this.exitSlippageInr,
  });

  double get totalStatutoryChargesInr =>
      brokerageInr + sttInr + exchangeTxnInr + sebiFeesInr + stampDutyInr + gstInr;

  double get totalSlippageInr => entrySlippageInr + exitSlippageInr;

  double get totalFrictionInr => totalStatutoryChargesInr + totalSlippageInr;
}

class RiskEngine {
  static OrderCostBreakdown computeRoundTripCostsAndSlippage({
    required double entryPremium,
    required double exitPremium,
    required int quantity,
    double spreadPct = 0.25,
    int barVolume = 1500,
    double flatBrokeragePerOrder = IndianOptionCostConfig.brokeragePerOrderInr,
  }) {
    if (quantity <= 0 || entryPremium <= 0) {
      return const OrderCostBreakdown(
        brokerageInr: 0,
        sttInr: 0,
        exchangeTxnInr: 0,
        sebiFeesInr: 0,
        stampDutyInr: 0,
        gstInr: 0,
        entrySlippageInr: 0,
        exitSlippageInr: 0,
      );
    }

    final buyTurnover = entryPremium * quantity;
    final sellTurnover = math.max(0.0, exitPremium) * quantity;
    final totalTurnover = buyTurnover + sellTurnover;

    final brokerage = flatBrokeragePerOrder * 2.0;
    final stt = sellTurnover * IndianOptionCostConfig.sttSellOptionRate;
    final exchTxn = totalTurnover * IndianOptionCostConfig.nseExchangeTxnRate;
    final sebiFee = totalTurnover * IndianOptionCostConfig.sebiTurnoverRate;
    final stampDuty = buyTurnover * IndianOptionCostConfig.stampDutyBuyRate;
    final gst = IndianOptionCostConfig.gstRate * (brokerage + exchTxn + sebiFee);

    final halfSpreadFrac = math.max(0.001, (spreadPct / 100.0) * 0.5);
    final liqRatio = quantity / math.max(100.0, barVolume.toDouble());
    final impactFrac = 0.0012 * math.sqrt(liqRatio.clamp(0.01, 4.0));

    final entrySlipPerUnit = entryPremium * (halfSpreadFrac + impactFrac);
    final exitSlipPerUnit =
        math.max(1.0, exitPremium) * (halfSpreadFrac + impactFrac);

    return OrderCostBreakdown(
      brokerageInr: brokerage,
      sttInr: stt,
      exchangeTxnInr: exchTxn,
      sebiFeesInr: sebiFee,
      stampDutyInr: stampDuty,
      gstInr: gst,
      entrySlippageInr: entrySlipPerUnit * quantity,
      exitSlippageInr: exitSlipPerUnit * quantity,
    );
  }

  /// WP-6 & WP-8: Strict sizing. When [useModelProbability] is false (rules-only mode before Gate A5),
  /// uses fixed small 1-lot sizing within risk caps. When true, uses capped 25% Kelly (returns 0 on zero/negative edge).
  static int computeOptimalBuyerQuantity({
    required double winProbability,
    required double entryPremium,
    required double stopLossPremium,
    required double targetPremium,
    required int lotSize,
    required double? availableCapital,
    required RiskConfig config,
    bool useModelProbability = true,
  }) {
    if (availableCapital == null ||
        availableCapital <= 0 ||
        entryPremium <= 0 ||
        lotSize <= 0 ||
        targetPremium <= entryPremium ||
        stopLossPremium >= entryPremium) {
      return 0;
    }

    final costs1Lot = computeRoundTripCostsAndSlippage(
      entryPremium: entryPremium,
      exitPremium: targetPremium,
      quantity: lotSize,
    );

    final netRewardPerLot =
        ((targetPremium - entryPremium) * lotSize) - costs1Lot.totalFrictionInr;
    final netRiskPerLot =
        ((entryPremium - stopLossPremium) * lotSize) + costs1Lot.totalFrictionInr;
    final totalOutlay1Lot =
        (entryPremium * lotSize) + costs1Lot.totalFrictionInr;

    if (netRewardPerLot <= 0 || netRiskPerLot <= 0) return 0;
    if (totalOutlay1Lot > availableCapital) return 0;

    final hardRiskBudget =
        availableCapital * (config.maxRiskPerTradePct / 100.0);
    final hardOutlayBudget =
        availableCapital * (config.maxCapitalOutlayPct / 100.0);

    // WP-8: Before calibrated model passes Gate A5, rules-only mode uses fixed 1-lot cap if within risk limits
    if (!useModelProbability) {
      if (netRiskPerLot <= hardRiskBudget &&
          totalOutlay1Lot <= hardOutlayBudget) {
        return lotSize;
      }
      return 0;
    }

    final p = winProbability.clamp(0.0, 1.0);
    final q = 1.0 - p;
    final b = netRewardPerLot / netRiskPerLot;

    // Full Kelly f* = (p*b - q) / b; zero or negative edge strictly returns 0 (WP-6: no 1-lot bypass)
    final fullKelly = (p * b - q) / b;
    if (fullKelly <= 0.0) {
      return 0;
    }

    final quarterKelly =
        (fullKelly * 0.25).clamp(0.0, config.maxRiskPerTradePct / 100.0);
    final riskBudgetInr = availableCapital * quarterKelly;

    final lotsByRisk = (riskBudgetInr / netRiskPerLot).floor();
    final lotsByOutlay = (hardOutlayBudget / totalOutlay1Lot).floor();
    final lotsByCap = (availableCapital / totalOutlay1Lot).floor();

    final chosenLots = math.min(lotsByRisk, math.min(lotsByOutlay, lotsByCap));
    if (chosenLots <= 0) return 0;
    return chosenLots * lotSize;
  }

  static double computeNetExpectedValueInr({
    required double winProbability,
    required double entryPremium,
    required double stopLossPremium,
    required double targetPremium,
    required int quantity,
    double spreadPct = 0.25,
    int barVolume = 1500,
  }) {
    if (quantity <= 0 || entryPremium <= 0) return -999.0;
    final costs = computeRoundTripCostsAndSlippage(
      entryPremium: entryPremium,
      exitPremium: targetPremium,
      quantity: quantity,
      spreadPct: spreadPct,
      barVolume: barVolume,
    );
    final grossWin = math.max(0.0, targetPremium - entryPremium) * quantity;
    final grossLoss = math.max(0.0, entryPremium - stopLossPremium) * quantity;
    final p = winProbability.clamp(0.0, 1.0);
    return (p * grossWin) - ((1.0 - p) * grossLoss) - costs.totalFrictionInr;
  }

  /// WP-6: Fail-Closed Risk Gate (no capital bypass, no Kelly-0 bypass, spread gate, IST daily loss + open risk)
  static AiSignal validateAndEnforceRisk({
    required AiSignal rawSignal,
    required RiskConfig config,
    required int openPositionsCount,
    required double todayNetRealizedPnlIst,
    required double openPositionsRiskInr,
    required double? availableCapital,
    double? bidPrice,
    double? askPrice,
    int? topAskQty,
    bool enforceEvGate = false,
  }) {
    if (rawSignal.action == SignalAction.noTrade || !rawSignal.strategyPassed) {
      return _blockSignal(
        rawSignal,
        availableCapital ?? 0.0,
        rawSignal.riskNote.isNotEmpty
            ? rawSignal.riskNote
            : 'BLOCKED: Strategy gate not passed',
      );
    }

    if (config.killSwitchActive) {
      return _blockSignal(
          rawSignal, availableCapital ?? 0.0, 'BLOCKED: Kill Switch is ACTIVE');
    }

    // WP-6: Unknown or zero capital ALWAYS blocks (no bypass)
    if (availableCapital == null || availableCapital <= 0) {
      return _blockSignal(
          rawSignal, 0.0, 'BLOCKED: Broker capital unavailable or zero');
    }

    if (rawSignal.securityId.isEmpty || rawSignal.lotSize <= 0) {
      return _blockSignal(rawSignal, availableCapital,
          'BLOCKED: Unresolved contract securityId or lot size');
    }

    final qty = rawSignal.quantity;
    if (qty <= 0) {
      return _blockSignal(rawSignal, availableCapital,
          'BLOCKED: Position size is 0 (Kelly/Risk cap exceeded)');
    }

    // WP-6: Daily loss check using IST net realized P&L + open risk
    final realizedLossToday =
        todayNetRealizedPnlIst < 0 ? todayNetRealizedPnlIst.abs() : 0.0;
    if (realizedLossToday >= config.maxDailyLossInr) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Today IST Net Loss (₹${realizedLossToday.toStringAsFixed(0)}) >= Limit (₹${config.maxDailyLossInr.toStringAsFixed(0)})',
      );
    }

    if (openPositionsCount >= config.maxConcurrentPositions) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Max concurrent positions (${config.maxConcurrentPositions}) reached',
      );
    }

    // Bid-ask spread & liquidity gate
    double spreadPct = 0.25;
    if (bidPrice != null &&
        askPrice != null &&
        bidPrice > 0 &&
        askPrice >= bidPrice) {
      final mid = 0.5 * (bidPrice + askPrice);
      spreadPct = mid > 0 ? ((askPrice - bidPrice) / mid) * 100.0 : 99.0;
      if (spreadPct > IndianOptionCostConfig.maxPermittedSpreadPct) {
        return _blockSignal(
          rawSignal,
          availableCapital,
          'BLOCKED: Wide bid-ask spread (${spreadPct.toStringAsFixed(2)}% > ${IndianOptionCostConfig.maxPermittedSpreadPct}%)',
        );
      }
    }
    if (topAskQty != null && topAskQty > 0 && topAskQty < qty) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Top-of-book liquidity ($topAskQty) < order qty ($qty)',
      );
    }

    final costs = computeRoundTripCostsAndSlippage(
      entryPremium: rawSignal.entryPremium,
      exitPremium: rawSignal.targetPremium,
      quantity: qty,
      spreadPct: spreadPct,
    );

    final requiredCap =
        (rawSignal.entryPremium * qty) + costs.totalFrictionInr;
    if (availableCapital < requiredCap) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Required ₹${requiredCap.toStringAsFixed(0)} > Available ₹${availableCapital.toStringAsFixed(0)}',
      );
    }

    final stopLossRiskInr =
        ((rawSignal.entryPremium - rawSignal.stopLossPremium).abs() * qty) +
            costs.totalFrictionInr;
    if (realizedLossToday + openPositionsRiskInr + stopLossRiskInr >
        config.maxDailyLossInr) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Combined daily + open + trade risk (₹${(realizedLossToday + openPositionsRiskInr + stopLossRiskInr).toStringAsFixed(0)}) exceeds limit ₹${config.maxDailyLossInr.toStringAsFixed(0)}',
      );
    }

    if (enforceEvGate) {
      final winProb = (rawSignal.confidencePct / 100.0).clamp(0.01, 0.99);
      final netEv = computeNetExpectedValueInr(
        winProbability: winProb,
        entryPremium: rawSignal.entryPremium,
        stopLossPremium: rawSignal.stopLossPremium,
        targetPremium: rawSignal.targetPremium,
        quantity: qty,
        spreadPct: spreadPct,
      );
      final minEv = StrategySettingsEngine.instance.current.minNetEvInr;
      if (netEv < minEv) {
        return _blockSignal(
          rawSignal,
          availableCapital,
          'BLOCKED by EV Gate: Net EV ₹${netEv.toStringAsFixed(1)} < ₹${minEv.toStringAsFixed(1)}',
        );
      }
    }

    return AiSignal(
      timestampMs: rawSignal.timestampMs,
      index: rawSignal.index,
      expiry: rawSignal.expiry,
      securityId: rawSignal.securityId,
      tradingSymbol: rawSignal.tradingSymbol,
      strike: rawSignal.strike,
      action: rawSignal.action,
      confidencePct: rawSignal.confidencePct,
      htfOiReason: rawSignal.htfOiReason,
      reasons: [
        ...rawSignal.reasons,
        'Risk Approved • Qty $qty | Est. Friction ₹${costs.totalFrictionInr.toStringAsFixed(1)} (STT 0.15%)',
      ],
      entryPremium: rawSignal.entryPremium,
      stopLossPremium: rawSignal.stopLossPremium,
      targetPremium: rawSignal.targetPremium,
      lotSize: rawSignal.lotSize,
      quantity: qty,
      requiredCapital: requiredCap,
      availableCapital: availableCapital,
      strategyPassed: true,
      riskWithinLimits: true,
      riskNote:
          'Approved • MaxLoss ₹${stopLossRiskInr.toStringAsFixed(0)} | Friction ₹${costs.totalFrictionInr.toStringAsFixed(0)}',
      modelVersion: rawSignal.modelVersion,
    );
  }

  static AiSignal _blockSignal(
      AiSignal sig, double availCap, String blockReason) {
    return AiSignal(
      timestampMs: sig.timestampMs,
      index: sig.index,
      expiry: sig.expiry,
      securityId: sig.securityId,
      tradingSymbol: sig.tradingSymbol,
      strike: sig.strike,
      action: SignalAction.noTrade,
      confidencePct: sig.confidencePct,
      htfOiReason: sig.htfOiReason,
      reasons: [...sig.reasons, blockReason],
      entryPremium: sig.entryPremium,
      stopLossPremium: sig.stopLossPremium,
      targetPremium: sig.targetPremium,
      lotSize: sig.lotSize,
      quantity: 0,
      requiredCapital: sig.requiredCapital,
      availableCapital: availCap,
      strategyPassed: sig.strategyPassed,
      riskWithinLimits: false,
      riskNote: blockReason,
      modelVersion: sig.modelVersion,
    );
  }
}
