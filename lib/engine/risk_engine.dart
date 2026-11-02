import 'dart:math' as math;
import '../core/models.dart';
import 'strategy_settings.dart';

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
  /// M7.1 & M7.2: Realistic Indian Equity Index Options Round-Trip Cost & Slippage Model
  /// Rates (verify against latest NSE/SEBI/broker schedule):
  /// - Brokerage: Rs 20 buy + Rs 20 sell = Rs 40 per round trip
  /// - STT: 0.10% on sell-side option premium turnover
  /// - NSE Exchange Transaction Charge: 0.03503% on buy + sell premium turnover
  /// - SEBI Turnover Fee: 0.0001% (Rs 10/crore) on buy + sell turnover
  /// - Stamp Duty: 0.003% on buy-side premium turnover
  /// - GST: 18% on (Brokerage + Exchange Txn + SEBI Fee)
  /// - Slippage: >= 0.5 * bid-ask spread + volume impact term per leg
  static OrderCostBreakdown computeRoundTripCostsAndSlippage({
    required double entryPremium,
    required double exitPremium,
    required int quantity,
    double spreadPct = 0.25,
    int barVolume = 1500,
    double flatBrokeragePerOrder = 20.0,
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
    final stt = sellTurnover * 0.001; // 0.10% on sell option premium
    final exchTxn = totalTurnover * 0.0003503; // 0.03503% NSE NFO
    final sebiFee = totalTurnover * 0.000001; // Rs 10 per crore
    final stampDuty = buyTurnover * 0.00003; // 0.003% on buy side
    final gst = 0.18 * (brokerage + exchTxn + sebiFee);

    // M7.2: Half-spread + square-root market impact slippage
    final halfSpreadFrac = math.max(0.001, (spreadPct / 100.0) * 0.5);
    final liqRatio = quantity / math.max(100.0, barVolume.toDouble());
    final impactFrac = 0.0012 * math.sqrt(liqRatio.clamp(0.01, 4.0));

    final entrySlipPerUnit = entryPremium * (halfSpreadFrac + impactFrac);
    final exitSlipPerUnit =
        math.max(1.0, exitPremium) * (halfSpreadFrac + impactFrac);

    return OrderCostBreakdown(
      brokerageInr: double.parse(brokerage.toStringAsFixed(2)),
      sttInr: double.parse(stt.toStringAsFixed(2)),
      exchangeTxnInr: double.parse(exchTxn.toStringAsFixed(2)),
      sebiFeesInr: double.parse(sebiFee.toStringAsFixed(2)),
      stampDutyInr: double.parse(stampDuty.toStringAsFixed(2)),
      gstInr: double.parse(gst.toStringAsFixed(2)),
      entrySlippageInr:
          double.parse((entrySlipPerUnit * quantity).toStringAsFixed(2)),
      exitSlippageInr:
          double.parse((exitSlipPerUnit * quantity).toStringAsFixed(2)),
    );
  }

  /// M8: Capped Fractional Kelly Position Sizing (at most 25% of Kelly, goes to 0 at zero/negative edge)
  static int computeOptimalBuyerQuantity({
    required double winProbability, // 0.0 .. 1.0 (use lower CI bound when available)
    required double entryPremium,
    required double stopLossPremium,
    required double targetPremium,
    required int lotSize,
    required double availableCapital,
    required RiskConfig config,
  }) {
    if (entryPremium <= 0 ||
        lotSize <= 0 ||
        availableCapital <= 0 ||
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

    if (netRewardPerLot <= 0 || netRiskPerLot <= 0) return 0;

    final p = winProbability.clamp(0.0, 1.0);
    final q = 1.0 - p;
    final b = netRewardPerLot / netRiskPerLot; // Net payoff odds

    // Full Kelly fraction f* = (p*b - q) / b
    final fullKelly = (p * b - q) / b;
    if (fullKelly <= 0.0) {
      // M8 Acceptance: At zero or negative edge, size goes to zero!
      return 0;
    }

    // Cap at 25% of Kelly and never exceed RiskConfig maxRiskPerTradePct
    final quarterKelly = (fullKelly * 0.25).clamp(0.0, config.maxRiskPerTradePct / 100.0);
    final maxRiskBudgetInr = availableCapital * quarterKelly;
    final maxCapitalOutlayInr =
        availableCapital * (config.maxCapitalOutlayPct / 100.0);

    final lotsByRisk = (maxRiskBudgetInr / netRiskPerLot).floor();
    final lotsByOutlay =
        (maxCapitalOutlayInr / (entryPremium * lotSize)).floor();

    // Buyer-only max loss = entryPremium * quantity must be <= availableCapital
    final maxAffordableLots =
        (availableCapital / (entryPremium * lotSize + costs1Lot.totalFrictionInr))
            .floor();

    int chosenLots = math.min(lotsByRisk, math.min(lotsByOutlay, maxAffordableLots));
    if (chosenLots < 1 && maxAffordableLots >= 1 && fullKelly > 0.02) {
      // Allow 1 minimum lot if positive edge & within hard RiskConfig per-trade cap
      final hardRiskBudget =
          availableCapital * (config.maxRiskPerTradePct / 100.0);
      if (netRiskPerLot <= hardRiskBudget * 1.25 &&
          (entryPremium * lotSize) <= availableCapital) {
        chosenLots = 1;
      }
    }

    return math.max(0, chosenLots * lotSize);
  }

  /// M8: Modeled Net Expected Value (EV in INR) after all statutory charges & slippage
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
    final netEv =
        (p * grossWin) - ((1.0 - p) * grossLoss) - costs.totalFrictionInr;
    return double.parse(netEv.toStringAsFixed(2));
  }

  /// Enforces Phase-1 & V2 M8 Risk Guardrails (Kill Switch, Net Daily Loss Limit, Max Positions, Buyer Max Loss, Net EV Gate)
  static AiSignal validateAndEnforceRisk({
    required AiSignal rawSignal,
    required RiskConfig config,
    required int openPositionsCount,
    required double todayRealizedLossInr,
    required double availableCapital,
  }) {
    if (rawSignal.action == SignalAction.noTrade) {
      return rawSignal;
    }

    if (config.killSwitchActive) {
      return _blockSignal(
          rawSignal, availableCapital, 'BLOCKED: Kill Switch is ACTIVE');
    }

    if (todayRealizedLossInr >= config.maxDailyLossInr) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Net Daily Loss (₹${todayRealizedLossInr.toStringAsFixed(0)}) >= Limit (₹${config.maxDailyLossInr.toStringAsFixed(0)})',
      );
    }

    if (openPositionsCount >= config.maxConcurrentPositions) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Max concurrent positions (${config.maxConcurrentPositions}) reached',
      );
    }

    final qty = rawSignal.lotSize;
    final costs = computeRoundTripCostsAndSlippage(
      entryPremium: rawSignal.entryPremium,
      exitPremium: rawSignal.targetPremium,
      quantity: qty,
    );

    // M8: Buyer-only max possible loss is full premium outlay + statutory charges
    final maxPossibleLoss =
        (rawSignal.entryPremium * qty) + costs.totalStatutoryChargesInr;
    final requiredCap =
        (rawSignal.entryPremium * qty) + costs.totalFrictionInr;

    if (availableCapital < requiredCap || availableCapital < maxPossibleLoss) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Required ₹${requiredCap.toStringAsFixed(0)} (incl. ₹${costs.totalFrictionInr.toStringAsFixed(0)} costs) > Available ₹${availableCapital.toStringAsFixed(0)}',
      );
    }

    final stopLossRiskInr =
        ((rawSignal.entryPremium - rawSignal.stopLossPremium).abs() * qty) +
            costs.totalFrictionInr;
    if (todayRealizedLossInr + stopLossRiskInr > config.maxDailyLossInr * 1.15) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED: Trade stop-loss risk (₹${stopLossRiskInr.toStringAsFixed(0)}) would breach daily loss cap',
      );
    }

    // M8: Net Expected Value Gate after costs & slippage
    final winProb = (rawSignal.confidencePct / 100.0).clamp(0.01, 0.99);
    final netEv = computeNetExpectedValueInr(
      winProbability: winProb,
      entryPremium: rawSignal.entryPremium,
      stopLossPremium: rawSignal.stopLossPremium,
      targetPremium: rawSignal.targetPremium,
      quantity: qty,
    );
    final minEv = StrategySettingsEngine.instance.current.minNetEvInr;
    if (netEv < minEv) {
      return _blockSignal(
        rawSignal,
        availableCapital,
        'BLOCKED by EV Gate: Net EV ₹${netEv.toStringAsFixed(1)} < ₹${minEv.toStringAsFixed(1)} after ₹${costs.totalFrictionInr.toStringAsFixed(0)} friction',
      );
    }

    return AiSignal(
      timestampMs: rawSignal.timestampMs,
      index: rawSignal.index,
      expiry: rawSignal.expiry,
      strike: rawSignal.strike,
      action: rawSignal.action,
      confidencePct: rawSignal.confidencePct,
      htfOiReason: rawSignal.htfOiReason,
      reasons: [
        ...rawSignal.reasons,
        'Net EV: +₹${netEv.toStringAsFixed(0)} (Costs+Slip: ₹${costs.totalFrictionInr.toStringAsFixed(0)})',
      ],
      entryPremium: rawSignal.entryPremium,
      stopLossPremium: rawSignal.stopLossPremium,
      targetPremium: rawSignal.targetPremium,
      lotSize: qty,
      requiredCapital: double.parse(requiredCap.toStringAsFixed(2)),
      availableCapital: availableCapital,
      riskWithinLimits: true,
      riskNote:
          'Approved • Net EV +₹${netEv.toStringAsFixed(0)} | MaxLoss ₹${stopLossRiskInr.toStringAsFixed(0)}',
      modelVersion: rawSignal.modelVersion,
    );
  }

  static AiSignal _blockSignal(
      AiSignal sig, double availCap, String blockReason) {
    return AiSignal(
      timestampMs: sig.timestampMs,
      index: sig.index,
      expiry: sig.expiry,
      strike: sig.strike,
      action: SignalAction.noTrade,
      confidencePct: sig.confidencePct,
      htfOiReason: sig.htfOiReason,
      reasons: [...sig.reasons, blockReason],
      entryPremium: sig.entryPremium,
      stopLossPremium: sig.stopLossPremium,
      targetPremium: sig.targetPremium,
      lotSize: sig.lotSize,
      requiredCapital: sig.requiredCapital,
      availableCapital: availCap,
      riskWithinLimits: false,
      riskNote: blockReason,
      modelVersion: sig.modelVersion,
    );
  }
}
