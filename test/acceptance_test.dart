import 'package:flutter_test/flutter_test.dart';
import 'package:ai_options_pro/core/models.dart';
import 'package:ai_options_pro/core/totp_auth.dart';
import 'package:ai_options_pro/data/strike_selector.dart';
import 'package:ai_options_pro/engine/ai_recalibration_engine.dart';
import 'package:ai_options_pro/engine/backtest_engine.dart';
import 'package:ai_options_pro/engine/dataset_label_engine.dart';
import 'package:ai_options_pro/engine/math_greeks.dart';
import 'package:ai_options_pro/engine/risk_engine.dart';
import 'package:ai_options_pro/engine/strategy_settings.dart';

void main() {
  test('strike_selection: ATM Strike Selection & 6-Contract Buyer Band', () {
    final atm = StrikeSelectionEngine.computeAtmStrike(
        UnderlyingIndex.nifty50, 23053.10);
    expect(atm, 23050);

    final band = StrikeSelectionEngine.getMonitoringStrikeBand(
        UnderlyingIndex.nifty50, 23053.10);
    expect(band, [22950, 23000, 23050, 23100, 23150]);

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

  test('greeks_and_black76: M1 Price->IV->Price round-trip < 0.01 & M2 2nd-order Greeks', () {
    const forward = 23110.0;
    const strike = 23050.0;
    const tYears = 5.0 / 365.0;
    const trueSigma = 0.165;

    final callPrice = MathGreeksEngine.black76Price(
      forward: forward,
      strike: strike,
      timeYears: tYears,
      sigma: trueSigma,
      isCall: true,
    );
    final solved = MathGreeksEngine.solveBlack76IvDetailed(
      forward: forward,
      strike: strike,
      timeYears: tYears,
      marketMidPrice: callPrice,
      isCall: true,
    );
    final recoveredSigma = solved['iv'] as double?;
    expect(recoveredSigma, isNotNull);

    final roundTripPrice = MathGreeksEngine.black76Price(
      forward: forward,
      strike: strike,
      timeYears: tYears,
      sigma: recoveredSigma!,
      isCall: true,
    );
    expect((roundTripPrice - callPrice).abs(), lessThan(0.01));

    // Verify failure returns null instead of silent clamped number when price < intrinsic
    final badSolved = MathGreeksEngine.solveBlack76IvDetailed(
      forward: 23200.0,
      strike: 23000.0,
      timeYears: tYears,
      marketMidPrice: 50.0, // Below intrinsic (~199)
      isCall: true,
    );
    expect(badSolved['iv'], isNull);

    // M2: Verify 1st & 2nd order Greeks populate
    final g = MathGreeksEngine.computeIvAndGreeks(
      spot: 23053.10,
      strike: 23050.0,
      optionLtp: callPrice,
      daysToExpiry: 5.0,
      isCall: true,
    );
    expect(g.delta, inInclusiveRange(0.45, 0.65));
    expect(g.gamma, greaterThan(0.0));
    expect(g.vega, greaterThan(0.0));
    expect(g.vanna.abs(), greaterThan(0.0));
    expect(g.charm.abs(), greaterThan(0.0));
  });

  test('honest_ai_metrics_A1_M6: Unclamped ~50% accuracy on balanced random labels & HMM round-trip', () {
    final ai = AiRecalibrationEngine.instance;
    final features = <List<double>>[];
    final labels = <int>[];
    for (int i = 0; i < 40; i++) {
      features.add([0.1, -0.05, 0.02]);
      labels.add(i % 2); // 50/50 alternating labels
    }

    final res = ai.evaluateUnclampedOutOfSample(features, labels);
    // Must be exactly 50.0%, NOT clamped to 58.5%!
    expect(res['accuracyPct'], closeTo(50.0, 0.01));
    expect(ai.activeModel.displayAccuracyLabel, contains('Insufficient data'));

    // M6: HMM JSON round-trip
    final exported = ai.exportHmmParamsJson();
    ai.importHmmParamsJson(exported);
    expect(ai.hmmTransitionMatrix.length, 3);
  });

  test('dataset_no_lookahead_A2: Rejects features timestamped after entry', () {
    const bar1 = OneMinEnrichedBar(
      timestampMs: 1000,
      indexName: 'NIFTY 50',
      expiry: '2026-11-03',
      strike: 23050,
      optionType: 'CE',
      strikeOffset: 0,
      underlyingSpot: 23050,
      open: 100,
      high: 102,
      low: 99,
      close: 101,
      intervalVolume: 1000,
      absoluteOi: 3500000,
      oiChange1m: 5000,
      oiChange5m: 25000,
      oiChange15m: 150000,
      oiChange60m: 300000,
      iv: 15.0,
      delta: 0.5,
      gamma: 0.001,
      theta: -12.0,
      vega: 9.0,
      spreadPct: 0.2,
      orderBookImbalance: 0.1,
    );
    const futureBar = OneMinEnrichedBar(
      timestampMs: 2000,
      indexName: 'NIFTY 50',
      expiry: '2026-11-03',
      strike: 23050,
      optionType: 'CE',
      strikeOffset: 0,
      underlyingSpot: 23060,
      open: 101,
      high: 104,
      low: 100,
      close: 103,
      intervalVolume: 1200,
      absoluteOi: 3520000,
      oiChange1m: 6000,
      oiChange5m: 30000,
      oiChange15m: 160000,
      oiChange60m: 310000,
      iv: 15.1,
      delta: 0.52,
      gamma: 0.001,
      theta: -12.0,
      vega: 9.0,
      spreadPct: 0.2,
      orderBookImbalance: 0.15,
    );

    expect(
      () => DatasetLabelEngine.enforceNoLookAhead(1000, [bar1, futureBar]),
      throwsA(isA<LookAheadViolationError>()),
    );
  });

  test('realistic_backtest_M7_and_kelly_M8: Zero-edge series yields negative net P&L & zero Kelly size', () {
    // M8: Zero edge (winProb = 0.35 with 1:1 payoff) must return 0 quantity
    final zeroEdgeQty = RiskEngine.computeOptimalBuyerQuantity(
      winProbability: 0.35,
      entryPremium: 100.0,
      stopLossPremium: 90.0,
      targetPremium: 110.0,
      lotSize: 75,
      availableCapital: 50000.0,
      config: const RiskConfig(),
    );
    expect(zeroEdgeQty, 0);

    // M7: Deliberately flat/zero-edge synthetic series must produce negative net P&L due to statutory costs & slippage
    final synthBars = <OneMinEnrichedBar>[];
    for (int i = 0; i < 40; i++) {
      final p = 100.0 + ((i % 2 == 0) ? 0.2 : -0.2);
      synthBars.add(
        OneMinEnrichedBar(
          timestampMs: 1700000000000 + i * 60000,
          indexName: 'NIFTY 50',
          expiry: '2026-11-03',
          strike: 23050,
          optionType: 'CE',
          strikeOffset: 0,
          underlyingSpot: 23050.0,
          open: p,
          high: p + 0.5,
          low: p - 0.5,
          close: p + 0.1,
          intervalVolume: 1500,
          absoluteOi: 3500000,
          oiChange1m: 10000,
          oiChange5m: 50000,
          oiChange15m: 200000,
          oiChange60m: 400000,
          iv: 15.0,
          delta: 0.50,
          gamma: 0.001,
          theta: -12.0,
          vega: 9.0,
          spreadPct: 0.30,
          orderBookImbalance: 0.10,
        ),
      );
    }

    final report = BacktestEngine.runRealisticBacktest(
      index: UnderlyingIndex.nifty50,
      bars: synthBars,
      riskConfig: const RiskConfig(),
      outOfSampleOnly: false,
    );
    expect(report.totalTrades, greaterThan(0));
    expect(report.netPnl, lessThan(0.0));

    // Verify RFC-6238 TOTP generator returns 6 digits
    final otp = TotpAuthManager.generateTotpCode('JBSWY3DPEHPK3PXP');
    expect(otp.length, 6);
  });
}
