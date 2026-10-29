import '../core/models.dart';

class RiskEngine {
  /// Strictly enforces buyer-only rules, capital checks, and risk limits
  static AiSignal validateAndEnforceRisk({
    required AiSignal rawSignal,
    required RiskConfig config,
    required int openPositionsCount,
    required double todayRealizedLossInr,
    required double availableCapital,
  }) {
    if (config.killSwitchActive) {
      return _reject(rawSignal, 'Kill Switch is ACTIVATED');
    }
    if (openPositionsCount >= config.maxConcurrentPositions) {
      return _reject(rawSignal, 'Max Concurrent Positions limit reached (${config.maxConcurrentPositions})');
    }
    if (todayRealizedLossInr >= config.maxDailyLossInr) {
      return _reject(rawSignal, 'Daily Loss Limit reached (Rs. ${config.maxDailyLossInr})');
    }
    if (rawSignal.action == SignalAction.noTrade) {
      return rawSignal;
    }
    if (rawSignal.requiredCapital > availableCapital && availableCapital > 0) {
      return _reject(rawSignal, 'Required premium (Rs. ${rawSignal.requiredCapital.toStringAsFixed(0)}) exceeds available capital');
    }

    // Buyer-only guardrail check
    if (rawSignal.action != SignalAction.buyCe && rawSignal.action != SignalAction.buyPe) {
      return _reject(rawSignal, 'Violation: Only BUY CE or BUY PE entries are permitted');
    }

    return rawSignal;
  }

  static AiSignal _reject(AiSignal sig, String reason) {
    return AiSignal(
      timestampMs: sig.timestampMs,
      index: sig.index,
      expiry: sig.expiry,
      strike: sig.strike,
      action: SignalAction.noTrade,
      confidencePct: 0.0,
      htfOiReason: sig.htfOiReason,
      reasons: [...sig.reasons, 'Risk Block: $reason'],
      entryPremium: sig.entryPremium,
      stopLossPremium: sig.stopLossPremium,
      targetPremium: sig.targetPremium,
      lotSize: sig.lotSize,
      requiredCapital: sig.requiredCapital,
      availableCapital: sig.availableCapital,
      riskWithinLimits: false,
      riskNote: reason,
      modelVersion: sig.modelVersion,
    );
  }
}
