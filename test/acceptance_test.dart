import 'package:flutter_test/flutter_test.dart';
import 'package:ai_options_pro/core/models.dart';
import 'package:ai_options_pro/core/totp_auth.dart';
import 'package:ai_options_pro/data/angel_smartapi_engine.dart';
import 'package:ai_options_pro/data/scrip_master_engine.dart';
import 'package:ai_options_pro/data/strike_selector.dart';
import 'package:ai_options_pro/engine/ai_recalibration_engine.dart';
import 'package:ai_options_pro/engine/backtest_engine.dart';
import 'package:ai_options_pro/engine/dataset_label_engine.dart';
import 'package:ai_options_pro/engine/execution_engine.dart';
import 'package:ai_options_pro/engine/exit_manager.dart';
import 'package:ai_options_pro/engine/iv_grid_engine.dart';
import 'package:ai_options_pro/engine/ledger_reconciler.dart';
import 'package:ai_options_pro/engine/math_greeks.dart';
import 'package:ai_options_pro/engine/mtf_strategy_engine.dart';
import 'package:ai_options_pro/engine/options_payoff_engine.dart';
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
    ];

    final loaded = master.loadFromAngelJsonList(
      fixture,
      referenceNowUtc: DateTime.utc(2026, 11, 19, 6, 0),
    );
    expect(loaded, 1);

    final resolved = master.resolveOptionContract(
      index: UnderlyingIndex.nifty50,
      expiryIso: '2026-11-24',
      strike: 24000,
      optionType: OptionType.ce,
    );
    expect(resolved, isNotNull);
    expect(resolved!.securityId, '55001');
    expect(resolved.lotSize, 65);
    expect(
      StrikeSelectionEngine.computeFractionalYearsToExpiryIst(
        '2026-11-24',
        nowUtc: DateTime.utc(2026, 11, 24, 10, 0),
      ),
      0.0,
    );
    expect(AngelSmartApiEngine.normalizeAngelOiToLots(6500, 65), 100);
  });

  test('WP7: Black-76 IV round-trip < 1e-6 & Put-Call Parity', () {
    const f = 24050.0, k = 24000.0, t = 5.0 / 365.0, sigma = 0.16;
    final cPrice = MathGreeksEngine.black76Price(
        forward: f, strike: k, timeYears: t, sigma: sigma, isCall: true);
    final pPrice = MathGreeksEngine.black76Price(
        forward: f, strike: k, timeYears: t, sigma: sigma, isCall: false);

    final recoveredF = MathGreeksEngine.deriveForwardFromParity(
      spot: 24000.0,
      atmStrike: k,
      atmCallMid: cPrice,
      atmPutMid: pPrice,
      timeYears: t,
    );
    expect((recoveredF - f).abs(), lessThan(1e-4));

    final solved = MathGreeksEngine.solveBlack76IvDetailed(
      forward: f,
      strike: k,
      timeYears: t,
      marketMidPrice: cPrice,
      isCall: true,
    );
    expect(((solved['iv'] as double) - sigma).abs(), lessThan(1e-6));
  });

  test('WP6: Risk gates, 0.15% STT, Partial Fills & Ledger Reconciler', () {
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

    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: 100.0,
      exitPremium: 100.0,
      quantity: 100,
    );
    expect(costs.sttInr, closeTo(15.0, 0.01));

    // Partial fill volume cap: 15% of 600 depth = 90 qty -> snaps to 1 lot (65) out of 130 requested
    expect(
      ExecutionEngine.computeVolumeCappedFillQty(
        requestedQty: 130,
        lotSize: 65,
        topBookQty: 600,
        orderVolumeRatio: 0.15,
      ),
      65,
    );
    // Too thin for even 1 lot -> 0 (cancelled)
    expect(
      ExecutionEngine.computeVolumeCappedFillQty(
        requestedQty: 65,
        lotSize: 65,
        topBookQty: 200,
        orderVolumeRatio: 0.15,
      ),
      0,
    );

    // Ledger Reconciler: unmeasured open P&L must remain null (N/A), never 0
    final openPos = PositionRecord(
      positionId: 'P1',
      securityId: '55001',
      indexName: 'NIFTY 50',
      expiry: '2026-11-24',
      strike: 24000,
      optionType: 'CE',
      quantity: 65,
      avgEntryPrice: 100.0,
      currentLtp: 100.0,
      stopLossPrice: 90.0,
      targetPrice: 120.0,
      openedAtMs: 1000,
      status: 'OPEN',
      mode: 'PAPER',
    );
    final buyOrd = TradeOrder(
      orderId: 'O1',
      timestampMs: 1000,
      indexName: 'NIFTY 50',
      expiry: '2026-11-24',
      strike: 24000,
      optionType: 'CE',
      side: 'BUY',
      quantity: 65,
      filledQty: 65,
      price: 100.0,
      status: 'FILLED',
      mode: 'PAPER',
      reason: 'test',
    );
    final auditDisconnected = LedgerReconciler.reconcileSnapshots(
      startingCapitalInr: 50000.0,
      orders: [buyOrd],
      positions: [openPos],
      liveLtpBySecurityId: const {},
      isFeedLive: false,
    );
    expect(auditDisconnected.isReconciled, isTrue);
    expect(auditDisconnected.openUnrealizedPnlInr, isNull);
    expect(auditDisconnected.expectedNavInr, isNull);

    expect(
      ExitManager.isAtOrPastForcedSquareOffIst(
          nowUtc: DateTime.utc(2026, 11, 19, 9, 45)),
      isTrue,
    );
  });

  test('VibeUpgrades: Payoff Comparator, No-Extrapolation IV Grid & Stress Test', () {
    StrikeRowSnapshot mkRow(int strike, int offset, double? ceIv, double ceLtp) {
      return StrikeRowSnapshot(
        strike: strike,
        offset: offset,
        ceSecurityId: 'CE_$strike',
        peSecurityId: 'PE_$strike',
        lotSize: 65,
        ceLtp: ceLtp,
        peLtp: 80.0,
        ceOi: 100,
        peOi: 100,
        ceVolume: 500,
        peVolume: 500,
        ceIv: ceIv,
        peIv: ceIv,
        ceDelta: 0.5,
        peDelta: -0.5,
        ceGamma: 0.001,
        peGamma: 0.001,
        ceTheta: -10.0,
        peTheta: -10.0,
        ceVega: 8.0,
        peVega: 8.0,
        source: 'TEST',
        exchangeTimestampMs: 1000,
        receivedAtMs: 1000,
      );
    }

    // 23900 (missing wing), 23950 (14%), 24000 (missing interior), 24050 (16%), 24100 (missing wing)
    final rows = [
      mkRow(23900, -2, null, 200.0),
      mkRow(23950, -1, 14.0, 150.0),
      mkRow(24000, 0, null, 110.0),
      mkRow(24050, 1, 16.0, 80.0),
      mkRow(24100, 2, null, 55.0),
    ];

    final grid = IvGridEngine.buildNoExtrapolationGrid(rows);
    expect(grid.cells[0].ceSource, IvCellSource.unavailable); // No left extrapolation
    expect(grid.cells[1].ceSource, IvCellSource.observed);
    expect(grid.cells[2].ceSource, IvCellSource.interpolated); // Interior 24000 interpolated
    expect(grid.cells[2].ceIv, closeTo(15.0, 0.01));
    expect(grid.cells[4].ceSource, IvCellSource.unavailable); // No right extrapolation

    // Payoff Comparator: Debit Spread must reduce net debit vs Naked Buy
    final cmp = OptionsPayoffEngine.compareNakedVsDebitSpread(
      chainRows: rows,
      spot: 24000.0,
      isCall: true,
      strikeStep: 50,
    );
    expect(cmp, isNotNull);
    expect(cmp!.length, 2);
    expect(cmp[1].netDebitInr, lessThan(cmp[0].netDebitInr));
    expect(cmp[1].maxProfitInr, isNotNull); // Capped spread profit

    // Stress test always returns 3 scenarios (1.0x, 1.5x, 2.0x)
    final stress = BacktestEngine.runFrictionStressTest(
      index: UnderlyingIndex.nifty50,
      bars: const [],
      riskConfig: const RiskConfig(),
      startingCapital: 50000.0,
      lotSize: 65,
    );
    expect(stress.length, 3);
    expect(stress[0].multiplier, 1.0);
    expect(stress[2].multiplier, 2.0);
  });

  test('WP8: Stale feed fail-closed, no-look-ahead & TOTP', () {
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
    expect(TotpAuthManager.generateTotpCode('JBSWY3DPEHPK3PXP').length, 6);
    expect(
      AiRecalibrationEngine.instance.evaluateUnclampedOutOfSample(
        List.generate(20, (_) => [0.1, -0.05, 0.02]),
        List.generate(20, (i) => i % 2),
      )['accuracyPct'],
      closeTo(50.0, 0.01),
    );
    expect(DatasetLabelEngine.featureSchemaVersion, 'FEATURE_SCHEMA_V3_SIGNED');
  });
}
