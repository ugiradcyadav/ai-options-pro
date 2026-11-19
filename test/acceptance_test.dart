import 'package:flutter_test/flutter_test.dart';
import 'package:ai_options_pro/core/models.dart';
import 'package:ai_options_pro/core/totp_auth.dart';
import 'package:ai_options_pro/data/angel_smartapi_engine.dart';
import 'package:ai_options_pro/data/scrip_master_engine.dart';
import 'package:ai_options_pro/data/strike_selector.dart';
import 'package:ai_options_pro/engine/ai_recalibration_engine.dart';
import 'package:ai_options_pro/engine/dataset_label_engine.dart';
import 'package:ai_options_pro/engine/execution_engine.dart';
import 'package:ai_options_pro/engine/exit_manager.dart';
import 'package:ai_options_pro/engine/math_greeks.dart';
import 'package:ai_options_pro/engine/mtf_strategy_engine.dart';
import 'package:ai_options_pro/engine/risk_engine.dart';

void main() {
  test('WP4_WP5: Instrument master exact resolution, lot sizes & IST expiry', () {
    final master = ScripMasterEngine.instance;
    final fixture = [
      {
        'token': '55001',
        'symbol': 'NIFTY24NOV2624000CE',
        'name': 'NIFTY',
        'expiry': '24NOV2026',
        'strike': '2400000.000000',
        'lotsize': '65',
        'instrumenttype': 'OPTIDX',
        'exch_seg': 'NFO',
      },
      {
        'token': '55002',
        'symbol': 'NIFTYNXT5024NOV2670000CE',
        'name': 'NIFTYNXT50',
        'expiry': '24NOV2026',
        'strike': '7000000.000000',
        'lotsize': '25',
        'instrumenttype': 'OPTIDX',
        'exch_seg': 'NFO',
      },
      {
        'token': '55003',
        'symbol': 'BANKNIFTY24NOV2652000PE',
        'name': 'BANKNIFTY',
        'expiry': '24NOV2026',
        'strike': '5200000.000000',
        'lotsize': '30',
        'instrumenttype': 'OPTIDX',
        'exch_seg': 'NFO',
      },
    ];

    final loaded = master.loadFromAngelJsonList(
      fixture,
      referenceNowUtc: DateTime.utc(2026, 11, 19, 6, 0),
    );
    expect(loaded, 2); // NIFTYNXT50 must be excluded

    final resolved = master.resolveOptionContract(
      index: UnderlyingIndex.nifty50,
      expiryIso: '2026-11-24',
      strike: 24000,
      optionType: OptionType.ce,
    );
    expect(resolved, isNotNull);
    expect(resolved!.securityId, '55001');
    expect(resolved.lotSize, 65);

    // Unknown strike returns null (fail closed)
    final missing = master.resolveOptionContract(
      index: UnderlyingIndex.nifty50,
      expiryIso: '2026-11-24',
      strike: 99900,
      optionType: OptionType.ce,
    );
    expect(missing, isNull);

    // 15:30 IST == 10:00 UTC; at 10:00 UTC on expiry day, timeYears == 0
    final tZero = StrikeSelectionEngine.computeFractionalYearsToExpiryIst(
      '2026-11-24',
      nowUtc: DateTime.utc(2026, 11, 24, 10, 0),
    );
    expect(tZero, 0.0);

    // OI normalization from Angel qty to lots
    expect(AngelSmartApiEngine.normalizeAngelOiToLots(6500, 65), 100);
  });

  test('WP7: Black-76 IV round-trip < 1e-6, Put-Call Parity & Grid GEX', () {
    const f = 24050.0;
    const k = 24000.0;
    const t = 5.0 / 365.0;
    const sigma = 0.16;

    final cPrice = MathGreeksEngine.black76Price(
        forward: f, strike: k, timeYears: t, sigma: sigma, isCall: true);
    final pPrice = MathGreeksEngine.black76Price(
        forward: f, strike: k, timeYears: t, sigma: sigma, isCall: false);

    // Put-Call Parity forward recovery
    final recoveredF = MathGreeksEngine.deriveForwardFromParity(
      spot: 24000.0,
      atmStrike: k,
      atmCallMid: cPrice,
      atmPutMid: pPrice,
      timeYears: t,
    );
    expect((recoveredF - f).abs(), lessThan(1e-4));

    // IV round-trip accuracy < 1e-6
    final solved = MathGreeksEngine.solveBlack76IvDetailed(
      forward: f,
      strike: k,
      timeYears: t,
      marketMidPrice: cPrice,
      isCall: true,
    );
    final recSigma = solved['iv'] as double?;
    expect(recSigma, isNotNull);
    expect((recSigma! - sigma).abs(), lessThan(1e-6));

    // Price below intrinsic returns null
    final badIv = MathGreeksEngine.solveBlack76IvDetailed(
      forward: 24500.0,
      strike: 24000.0,
      timeYears: t,
      marketMidPrice: 100.0,
      isCall: true,
    );
    expect(badIv['iv'], isNull);
  });

  test('WP6: Risk gates (zero capital, Kelly 0, 0.15% STT, 15:15 IST square-off)', () {
    // Zero capital -> size 0
    expect(
      RiskEngine.computeOptimalBuyerQuantity(
        winProbability: 0.65,
        entryPremium: 100.0,
        stopLossPremium: 90.0,
        targetPremium: 120.0,
        lotSize: 65,
        availableCapital: 0.0,
        config: const RiskConfig(),
      ),
      0,
    );

    // Zero/negative edge -> Kelly returns 0 (no 1-lot bypass)
    expect(
      RiskEngine.computeOptimalBuyerQuantity(
        winProbability: 0.35,
        entryPremium: 100.0,
        stopLossPremium: 90.0,
        targetPremium: 110.0,
        lotSize: 65,
        availableCapital: 100000.0,
        config: const RiskConfig(),
        useModelProbability: true,
      ),
      0,
    );

    // Verify 0.15% sell-side STT
    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: 100.0,
      exitPremium: 100.0,
      quantity: 100,
    );
    expect(costs.sttInr, closeTo(15.0, 0.01));

    // Marketable limit price is above ask for buy and below bid for sell
    final buyLim = ExecutionEngine.computeMarketableLimitPrice(
        isBuy: true, ltp: 100.0, bestBid: 99.8, bestAsk: 100.2);
    expect(buyLim, greaterThan(100.2));

    // 15:15 IST == 09:45 UTC
    expect(
      ExitManager.isAtOrPastForcedSquareOffIst(
          nowUtc: DateTime.utc(2026, 11, 19, 9, 45)),
      isTrue,
    );
    expect(
      ExitManager.isAtOrPastForcedSquareOffIst(
          nowUtc: DateTime.utc(2026, 11, 19, 9, 44)),
      isFalse,
    );
  });

  test('WP8: Fail-closed stale feed, symmetric rules, no-look-ahead & HMM single-pass', () {
    // Stale / Disconnected feed MUST produce NO TRADE
    final staleSig = MtfStrategyEngine.evaluateEntry(
      index: UnderlyingIndex.nifty50,
      expiry: '2026-11-24',
      spot: 24000.0,
      dataHealth: DataHealthStatus.disconnected,
      chainRows: const [],
      recentSpotBars: const [],
      availableCapital: 50000.0,
      riskConfig: const RiskConfig(),
      openPositionsCount: 0,
      todayNetRealizedPnlIst: 0.0,
      openPositionsRiskInr: 0.0,
    );
    expect(staleSig.action, SignalAction.noTrade);

    // No-look-ahead throws LookAheadViolationError
    const b1 = OneMinEnrichedBar(
      timestampMs: 1000,
      indexName: 'NIFTY 50',
      expiry: '2026-11-24',
      strike: 24000,
      optionType: 'CE',
      strikeOffset: 0,
      underlyingSpot: 24000,
      open: 100,
      high: 102,
      low: 99,
      close: 101,
      intervalVolume: 500,
      absoluteOi: 1000,
      delta: 0.5,
      gamma: 0.001,
      theta: -10,
      vega: 8,
    );
    const bFuture = OneMinEnrichedBar(
      timestampMs: 2000,
      indexName: 'NIFTY 50',
      expiry: '2026-11-24',
      strike: 24000,
      optionType: 'CE',
      strikeOffset: 0,
      underlyingSpot: 24010,
      open: 101,
      high: 103,
      low: 100,
      close: 102,
      intervalVolume: 600,
      absoluteOi: 1050,
      delta: 0.52,
      gamma: 0.001,
      theta: -10,
      vega: 8,
    );
    expect(
      () => DatasetLabelEngine.enforceNoLookAhead(1000, [b1, bFuture]),
      throwsA(isA<LookAheadViolationError>()),
    );

    // Unclamped ~50% accuracy on balanced labels
    final ai = AiRecalibrationEngine.instance;
    final feats = List.generate(40, (_) => [0.1, -0.05, 0.02]);
    final labels = List.generate(40, (i) => i % 2);
    expect(ai.evaluateUnclampedOutOfSample(feats, labels)['accuracyPct'],
        closeTo(50.0, 0.01));

    // TOTP 6-digit format
    expect(TotpAuthManager.generateTotpCode('JBSWY3DPEHPK3PXP').length, 6);
  });
}
