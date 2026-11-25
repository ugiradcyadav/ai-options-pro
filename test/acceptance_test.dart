import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_options_pro/core/models.dart';
import 'package:ai_options_pro/core/totp_auth.dart';
import 'package:ai_options_pro/data/angel_smartapi_engine.dart';
import 'package:ai_options_pro/data/angel_ws_streamer.dart';
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
import 'package:ai_options_pro/engine/microstructure_engine.dart';
import 'package:ai_options_pro/engine/mtf_strategy_engine.dart';
import 'package:ai_options_pro/engine/options_payoff_engine.dart';
import 'package:ai_options_pro/engine/quantstats_engine.dart';
import 'package:ai_options_pro/engine/risk_engine.dart';
import 'package:ai_options_pro/engine/trendline_engine.dart';

void main() {
  test('WP4_WP5: NFO + Sensex BFO master resolution, lot sizes & IST expiry', () {
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
        'token': '88001',
        'symbol': 'SENSEX27NOV2680000CE',
        'name': 'SENSEX',
        'expiry': '27NOV2026',
        'strike': '8000000.000000',
        'lotsize': '20',
        'instrumenttype': 'OPTIDX',
        'exch_seg': 'BFO',
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
    expect(loaded, 2);

    final sensexC = master.resolveOptionContract(
      index: UnderlyingIndex.sensex,
      expiryIso: '2026-11-27',
      strike: 80000,
      optionType: OptionType.ce,
    );
    expect(sensexC, isNotNull);
    expect(sensexC!.securityId, '88001');
    expect(sensexC.lotSize, 20);
    expect(sensexC.exchangeSegment, 'BFO');
    expect(AngelSmartApiEngine.spotTokenForIndex(UnderlyingIndex.sensex), '99919000');
    expect(UnderlyingIndex.sensex.spotExchange, 'BSE');
    expect(UnderlyingIndex.sensex.foExchange, 'BFO');
    expect(
      StrikeSelectionEngine.computeFractionalYearsToExpiryIst(
        '2026-11-24',
        nowUtc: DateTime.utc(2026, 11, 24, 10, 0),
      ),
      0.0,
    );
  });

  test('V4_0: SmartStream WS v2 Binary Parser & VisualHFT Microstructure', () {
    final buf = Uint8List(347);
    final bd = ByteData.sublistView(buf);
    buf[0] = 3;
    buf[1] = 4;
    final tokBytes = '88001'.codeUnits;
    for (int i = 0; i < tokBytes.length; i++) {
      buf[2 + i] = tokBytes[i];
    }
    bd.setInt64(35, 1764000000000, Endian.little);
    bd.setInt64(43, 24550, Endian.little);
    bd.setInt64(67, 12500, Endian.little);
    bd.setInt64(115, 22000, Endian.little);
    bd.setInt64(131, 4000, Endian.little);

    bd.setUint16(147, 1, Endian.little);
    bd.setInt64(149, 500, Endian.little);
    bd.setInt64(157, 24500, Endian.little);
    bd.setUint16(165, 5, Endian.little);

    bd.setUint16(167, 0, Endian.little);
    bd.setInt64(169, 150, Endian.little);
    bd.setInt64(177, 24600, Endian.little);
    bd.setUint16(185, 2, Endian.little);

    final tick = AngelWsStreamer.parseBinaryPacket(buf);
    expect(tick, isNotNull);
    expect(tick!.token, '88001');
    expect(tick.ltp, closeTo(245.50, 0.001));
    expect(tick.bestBid, closeTo(245.00, 0.001));
    expect(tick.bestAsk, closeTo(246.00, 0.001));
    expect(tick.openInterestRaw, 4000);

    final snap = MicrostructureEngine.instance.ingestTick(tick);
    expect(snap.weightedObi, greaterThan(0.4));
    expect(snap.microPrice, isNotNull);
    expect(snap.spreadBps, greaterThan(0));
  });

  test('V4_0: QuantStats Tear-Sheet & Auto S/R Trendline Engine', () {
    final qs = QuantStatsEngine.computeFromTradeLogs(
      tradeLogs: [
        {'netPnl': 1200.0, 'exitTimeMs': 1764000000000},
        {'netPnl': -400.0, 'exitTimeMs': 1764003600000},
        {'netPnl': 1600.0, 'exitTimeMs': 1764007200000},
        {'netPnl': 900.0, 'exitTimeMs': 1764010800000},
      ],
      startingCapitalInr: 50000.0,
    );
    expect(qs.totalTrades, 4);
    expect(qs.sharpeRatio, greaterThan(0));
    expect(qs.maxConsecutiveWins, 2);
    expect(qs.payoffRatio, greaterThan(2.0));

    final bars = List.generate(14, (i) {
      final base =
          100.0 + (i % 4 == 2 ? 12.0 : (i % 4 == 0 ? -4.0 : 4.0)) + i * 0.8;
      return OneMinEnrichedBar(
        timestampMs: 1764000000000 + i * 60000,
        contractId: '55001',
        indexName: 'NIFTY 50',
        expiry: '2026-11-24',
        strike: 24000,
        optionType: 'CE',
        strikeOffset: 0,
        underlyingSpot: 24000.0,
        open: base - 1.0,
        high: base + 3.0,
        low: base - 3.0,
        close: base + 1.0,
        intervalVolume: 1000,
        absoluteOi: 500,
        delta: 0.5,
        gamma: 0.001,
        theta: -10.0,
        vega: 8.0,
      );
    });
    final sr = TrendlineEngine.detect(bars, pivotWindow: 1);
    expect(sr.supportLine, isNotNull);
    expect(sr.resistanceLine, isNotNull);
  });

  test('WP6_WP7_WP8: Black-76, Risk, Partial Fills, IV Grid & Fail-Closed', () {
    const f = 24050.0, k = 24000.0, t = 5.0 / 365.0, sigma = 0.16;
    final cPrice = MathGreeksEngine.black76Price(
        forward: f, strike: k, timeYears: t, sigma: sigma, isCall: true);
    final solved = MathGreeksEngine.solveBlack76IvDetailed(
      forward: f,
      strike: k,
      timeYears: t,
      marketMidPrice: cPrice,
      isCall: true,
    );
    expect(((solved['iv'] as double) - sigma).abs(), lessThan(1e-6));

    expect(
      ExecutionEngine.computeVolumeCappedFillQty(
        requestedQty: 130,
        lotSize: 65,
        topBookQty: 600,
        orderVolumeRatio: 0.15,
      ),
      65,
    );

    final audit = LedgerReconciler.reconcileSnapshots(
      startingCapitalInr: 50000.0,
      orders: const [],
      positions: const [],
      liveLtpBySecurityId: const {},
      isFeedLive: false,
    );
    expect(audit.isReconciled, isTrue);

    expect(
      ExitManager.isAtOrPastForcedSquareOffIst(
          nowUtc: DateTime.utc(2026, 11, 19, 9, 45)),
      isTrue,
    );
    expect(TotpAuthManager.generateTotpCode('JBSWY3DPEHPK3PXP').length, 6);
    expect(
      MtfStrategyEngine.evaluateEntry(
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
      ).action,
      SignalAction.noTrade,
    );
    expect(
      AiRecalibrationEngine.instance.evaluateUnclampedOutOfSample(
        List.generate(20, (_) => [0.1, -0.05, 0.02]),
        List.generate(20, (i) => i % 2),
      )['accuracyPct'],
      closeTo(50.0, 0.01),
    );
    expect(DatasetLabelEngine.featureSchemaVersion, 'FEATURE_SCHEMA_V3_SIGNED');
    expect(
      BacktestEngine.runFrictionStressTest(
        index: UnderlyingIndex.nifty50,
        bars: const [],
        riskConfig: const RiskConfig(),
        startingCapital: 50000.0,
        lotSize: 65,
      ).length,
      3,
    );
    expect(IvGridEngine.buildNoExtrapolationGrid(const []).cells, isEmpty);
    expect(
      OptionsPayoffEngine.compareNakedVsDebitSpread(
        chainRows: const [],
        spot: 24000,
        isCall: true,
        strikeStep: 50,
      ),
      isNull,
    );
  });
}
