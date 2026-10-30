import 'package:flutter_test/flutter_test.dart';
import 'package:ai_options_pro/core/models.dart';
import 'package:ai_options_pro/core/totp_auth.dart';
import 'package:ai_options_pro/data/strike_selector.dart';
import 'package:ai_options_pro/engine/math_greeks.dart';
import 'package:ai_options_pro/engine/risk_engine.dart';

void main() {
  test('T1 & T2: ATM Strike Selection & 6-Contract Buyer Band', () {
    final atm = StrikeSelectionEngine.computeAtmStrike(
        UnderlyingIndex.nifty50, 24318.5);
    expect(atm, 24300);

    final band = StrikeSelectionEngine.getMonitoringStrikeBand(
        UnderlyingIndex.nifty50, 24318.5);
    expect(band, [24200, 24250, 24300, 24350, 24400]);

    expect(
      StrikeSelectionEngine.isInActiveBuyerSignalBand(
          strikeOffset: 1, optionType: OptionType.ce),
      isTrue,
    );
    expect(
      StrikeSelectionEngine.isInActiveBuyerSignalBand(
          strikeOffset: -1, optionType: OptionType.pe),
      isTrue,
    );
  });

  test('T3 & T4: Black-Scholes IV, Greeks & Order-Book Imbalance', () {
    final g = MathGreeksEngine.computeIvAndGreeks(
      spot: 24300,
      strike: 24300,
      optionLtp: 112.5,
      daysToExpiry: 4.0,
      isCall: true,
    );
    expect(g.ivPct, greaterThan(5.0));
    expect(g.delta, inInclusiveRange(0.40, 0.65));

    final imb = MathGreeksEngine.calculateOrderBookImbalance(
        totalBidQty: 600, totalAskQty: 400);
    expect(imb, closeTo(0.20, 0.001));
  });

  test('T5 & T6: Buyer-Only Risk Engine, 1-Lot Capital & Daily Loss Guardrail', () {
    const rawSig = AiSignal(
      timestampMs: 1700000000000,
      index: UnderlyingIndex.nifty50,
      expiry: '2026-11-05',
      strike: 24300,
      action: SignalAction.buyCe,
      confidencePct: 76.0,
      htfOiReason: '5m/15m PE OI support',
      reasons: ['1m breakout'],
      entryPremium: 100.0,
      stopLossPremium: 93.0,
      targetPremium: 115.0,
      lotSize: 75,
      requiredCapital: 7558.0,
      availableCapital: 12000.0,
      riskWithinLimits: true,
      riskNote: 'Within Limits',
      modelVersion: 'LGBM-HMM-v1.0',
    );

    final approved = RiskEngine.validateAndEnforceRisk(
      rawSignal: rawSig,
      config: const RiskConfig(maxDailyLossInr: 2500.0),
      openPositionsCount: 0,
      todayRealizedLossInr: 500.0,
      availableCapital: 12000.0,
    );
    expect(approved.action, SignalAction.buyCe);
    expect(approved.riskWithinLimits, isTrue);

    final blocked = RiskEngine.validateAndEnforceRisk(
      rawSignal: rawSig,
      config: const RiskConfig(maxDailyLossInr: 1500.0),
      openPositionsCount: 0,
      todayRealizedLossInr: 1600.0,
      availableCapital: 12000.0,
    );
    expect(blocked.action, SignalAction.noTrade);
    expect(blocked.riskWithinLimits, isFalse);

    final otp = TotpAuthManager.generateTotpCode('JBSWY3DPEHPK3PXP');
    expect(otp.length, 6);
  });
}
