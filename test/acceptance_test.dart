import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_options_pro/core/models.dart';
import 'package:ai_options_pro/core/totp_auth.dart';
import 'package:ai_options_pro/data/angel_smartapi_engine.dart';
import 'package:ai_options_pro/data/angel_ws_streamer.dart';
import 'package:ai_options_pro/data/scrip_master_engine.dart';
import 'package:ai_options_pro/data/strike_selector.dart';
import 'package:ai_options_pro/engine/backtest_engine.dart';
import 'package:ai_options_pro/engine/execution_engine.dart';
import 'package:ai_options_pro/engine/exit_manager.dart';
import 'package:ai_options_pro/engine/iv_grid_engine.dart';
import 'package:ai_options_pro/engine/journal_coach_engine.dart';
import 'package:ai_options_pro/engine/ledger_reconciler.dart';
import 'package:ai_options_pro/engine/math_greeks.dart';
import 'package:ai_options_pro/engine/microstructure_engine.dart';
import 'package:ai_options_pro/engine/monte_carlo_engine.dart';
import 'package:ai_options_pro/engine/mtf_strategy_engine.dart';
import 'package:ai_options_pro/engine/quantstats_engine.dart';
import 'package:ai_options_pro/engine/regime_engine.dart';
import 'package:ai_options_pro/engine/sadhu_ml_engine.dart';
import 'package:ai_options_pro/engine/trendline_engine.dart';
import 'package:ai_options_pro/state/app_state.dart';

String _makeTestJwt(int expEpochSec) {
  final h = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final p = base64Url.encode(utf8.encode('{"exp":$expEpochSec}'));
  return '$h.$p.sig';
}

void main() {
  test('Phase1_C1_C2_C3: Per-contract 2-option backtest is isolated & reproducible', () {
    // 10:00 IST = 04:30 UTC (before 15:10 IST cut-off)
    final baseMs = DateTime.utc(2026, 11, 20, 4, 30).millisecondsSinceEpoch;
    final bars = <OneMinEnrichedBar>[];

    for (int i = 0; i < 10; i++) {
      final ts = baseMs + i * 60000;
      final spot = 24000.0 + i * 25.0; // steady uptrend
      bars.add(OneMinEnrichedBar(
        timestampMs: ts,
        contractId: 'SPOT_NIFTY',
        indexName: 'NIFTY 50',
        expiry: '2026-11-26',
        strike: 0,
        optionType: 'SPOT',
        strikeOffset: 0,
        underlyingSpot: spot,
        open: spot - 5,
        high: spot + 8,
        low: spot - 8,
        close: spot,
        intervalVolume: 0,
        absoluteOi: 0,
        delta: 1.0,
        gamma: 0,
        theta: 0,
        vega: 0,
      ));

      // Contract 1: CE_24000 rises cleanly to hit target
      final cePx = 100.0 + i * 6.0;
      bars.add(OneMinEnrichedBar(
        timestampMs: ts,
        contractId: 'CE_24000',
        indexName: 'NIFTY 50',
        expiry: '2026-11-26',
        strike: 24000,
        optionType: 'CE',
        strikeOffset: 0,
        underlyingSpot: spot,
        open: cePx,
        high: cePx + 18.0,
        low: cePx - 1.0,
        close: cePx + 5.0,
        intervalVolume: 50000,
        absoluteOi: 100000,
        oiChange15m: -50000,
        iv: 15.0,
        delta: 0.52,
        gamma: 0.001,
        theta: -12.0,
        vega: 9.0,
        spreadPct: 0.20,
      ));

      // Contract 2: PE_24000 crashes (must NEVER leak into CE_24000 trade path)
      final pePx = (80.0 - i * 7.0).clamp(5.0, 200.0).toDouble();
      bars.add(OneMinEnrichedBar(
        timestampMs: ts,
        contractId: 'PE_24000',
        indexName: 'NIFTY 50',
        expiry: '2026-11-26',
        strike: 24000,
        optionType: 'PE',
        strikeOffset: 0,
        underlyingSpot: spot,
        open: pePx,
        high: pePx + 1.0,
        low: pePx - 4.0,
        close: pePx,
        intervalVolume: 50000,
        absoluteOi: 160000, // PCR = 1.60 >= 1.05
        oiChange15m: 90000, // Net ΔOI = +140,000 lots
        iv: 15.0,
        delta: -0.48,
        gamma: 0.001,
        theta: -12.0,
        vega: 9.0,
        spreadPct: 0.20,
      ));
    }

    final r1 = BacktestEngine.runRealisticBacktest(
      index: UnderlyingIndex.nifty50,
      bars: bars,
      riskConfig: const RiskConfig(),
      startingCapital: 500000.0,
      lotSize: 65,
      outOfSampleOnly: false,
    );
    final r2 = BacktestEngine.runRealisticBacktest(
      index: UnderlyingIndex.nifty50,
      bars: bars,
      riskConfig: const RiskConfig(),
      startingCapital: 500000.0,
      lotSize: 65,
      outOfSampleOnly: false,
    );

    expect(r1.totalTrades, greaterThan(0));
    expect(r1.totalTrades, r2.totalTrades);
    expect(r1.netPnl, closeTo(r2.netPnl, 1e-6));
    for (final raw in r1.tradeLogs) {
      final m = raw as Map;
      expect(m['contractId'], 'CE_24000');
      expect((m['entry'] as num).toDouble(), greaterThanOrEqualTo(100.0));
    }
  });

  test('Phase1_Regime_Cutoff_JWT: Measured Regime moves, 15:10 cutoff & JWT expiry', () {
    final baseMs = DateTime.utc(2026, 11, 20, 4, 0).millisecondsSinceEpoch;
    List<OneMinEnrichedBar> makeTrend(double step) => List.generate(20, (i) {
          final p = 24000.0 + i * step;
          return OneMinEnrichedBar(
            timestampMs: baseMs + i * 60000,
            contractId: 'SPOT_NIFTY',
            indexName: 'NIFTY 50',
            expiry: '2026-11-26',
            strike: 0,
            optionType: 'SPOT',
            strikeOffset: 0,
            underlyingSpot: p,
            open: p - step * 0.4,
            high: p + step.abs() * 0.6,
            low: p - step.abs() * 0.6,
            close: p,
            intervalVolume: 0,
            absoluteOi: 0,
            delta: 1,
            gamma: 0,
            theta: 0,
            vega: 0,
          );
        });

    final bull = RegimeEngine.evaluate(
        indexLabel: 'NIFTY 50', spotBars: makeTrend(18.0));
    final bear = RegimeEngine.evaluate(
        indexLabel: 'NIFTY 50', spotBars: makeTrend(-18.0));
    expect(bull.hasSufficientData, isTrue);
    expect(bull.bullProb, greaterThan(bull.bearProb));
    expect(bear.bearProb, greaterThan(bear.bullProb));

    // H4: 15:11 IST blocked, 10:30 IST allowed
    expect(
      AppState.isAtOrPastEntryCutoffIst(
          nowUtc: DateTime.utc(2026, 11, 20, 9, 41)),
      isTrue,
    );
    expect(
      AppState.isAtOrPastEntryCutoffIst(
          nowUtc: DateTime.utc(2026, 11, 20, 5, 0)),
      isFalse,
    );

    // H6: JWT real exp validation
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    expect(AngelSmartApiEngine.isJwtValid(_makeTestJwt(nowSec + 3600)), isTrue);
    expect(AngelSmartApiEngine.isJwtValid(_makeTestJwt(nowSec - 120)), isFalse);
  });

  test('Phase1_SadhuML_MonteCarlo_Journal: ML training, 10k MC & Streak Coach', () {
    final x = List.generate(60, (i) {
      final pos = i % 2 == 0;
      return [pos ? 0.08 : -0.08, pos ? 0.02 : -0.02, pos ? 0.4 : -0.4];
    });
    final y = List.generate(60, (i) => i % 2 == 0 ? 1 : 0);

    final rep = SadhuMlEngine.instance.trainOnRealDataset(features: x, labels: y);
    expect(rep.trained, isTrue);
    expect(rep.stumpCount, greaterThan(0));
    expect(rep.oosAccuracyPct, greaterThan(70.0));
    final predPos = SadhuMlEngine.instance.predict([0.09, 0.02, 0.4]);
    final predNeg = SadhuMlEngine.instance.predict([-0.09, -0.02, -0.4]);
    expect(predPos.calibratedProb, greaterThan(predNeg.calibratedProb));

    final mc1 = MonteCarloEngine.runSync(
      tradePnls: [1200, -400, 950, 800, -350, 1400, -250, 1100],
      startingCapitalInr: 50000,
      simulations: 2000,
      seed: 42,
    );
    final mc2 = MonteCarloEngine.runSync(
      tradePnls: [1200, -400, 950, 800, -350, 1400, -250, 1100],
      startingCapitalInr: 50000,
      simulations: 2000,
      seed: 42,
    );
    expect(mc1.p95MaxDdPct, greaterThanOrEqualTo(mc1.p50MaxDdPct));
    expect(mc1.p50EndingEquityInr, closeTo(mc2.p50EndingEquityInr, 1e-6));
    expect(mc1.ddHistogramBuckets.length, 10);

    final coach = JournalCoachEngine.analyze([
      PositionRecord(
        positionId: 'P1',
        securityId: '55001',
        tradingSymbol: 'NIFTY_24000_CE',
        indexName: 'NIFTY 50',
        expiry: '2026-11-26',
        strike: 24000,
        optionType: 'CE',
        quantity: 65,
        avgEntryPrice: 100,
        currentLtp: 115,
        stopLossPrice: 80,
        targetPrice: 120,
        openedAtMs: DateTime.utc(2026, 11, 19, 5, 0).millisecondsSinceEpoch,
        closedAtMs: DateTime.utc(2026, 11, 19, 5, 10).millisecondsSinceEpoch,
        status: 'CLOSED',
        mode: 'PAPER',
        realizedPnl: 900.0,
      ),
      PositionRecord(
        positionId: 'P2',
        securityId: '55001',
        tradingSymbol: 'NIFTY_24000_CE',
        indexName: 'NIFTY 50',
        expiry: '2026-11-26',
        strike: 24000,
        optionType: 'CE',
        quantity: 65,
        avgEntryPrice: 100,
        currentLtp: 110,
        stopLossPrice: 80,
        targetPrice: 120,
        openedAtMs: DateTime.utc(2026, 11, 20, 5, 0).millisecondsSinceEpoch,
        closedAtMs: DateTime.utc(2026, 11, 20, 5, 10).millisecondsSinceEpoch,
        status: 'CLOSED',
        mode: 'PAPER',
        realizedPnl: 600.0,
      ),
    ]);
    expect(coach.greenDays, 2);
    expect(coach.currentStreakDays, 2);
  });

  test('Core_Infra: Sensex BFO + NSE Constituents + WS v2 + Black-76 + QuantStats', () {
    final master = ScripMasterEngine.instance;
    final loaded = master.loadFromAngelJsonList([
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
        'token': '1333',
        'symbol': 'HDFCBANK-EQ',
        'name': 'HDFCBANK',
        'expiry': '',
        'strike': '0',
        'lotsize': '1',
        'instrumenttype': '',
        'exch_seg': 'NSE',
      },
    ], referenceNowUtc: DateTime.utc(2026, 11, 19, 6, 0));
    expect(loaded, 1);
    expect(master.getNseEquityToken('HDFCBANK'), '1333');
    expect(
      master.resolveOptionContract(
        index: UnderlyingIndex.sensex,
        expiryIso: '2026-11-27',
        strike: 80000,
        optionType: OptionType.ce,
      )?.lotSize,
      20,
    );

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
    bd.setUint16(147, 1, Endian.little);
    bd.setInt64(149, 500, Endian.little);
    bd.setInt64(157, 24500, Endian.little);
    bd.setUint16(167, 0, Endian.little);
    bd.setInt64(169, 150, Endian.little);
    bd.setInt64(177, 24600, Endian.little);

    final tick = AngelWsStreamer.parseBinaryPacket(buf);
    expect(tick?.ltp, closeTo(245.50, 0.001));
    expect(MicrostructureEngine.instance.ingestTick(tick!).weightedObi, greaterThan(0.4));

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
    expect(TotpAuthManager.generateTotpCode('JBSWY3DPEHPK3PXP').length, 6);
    expect(
      ExitManager.isAtOrPastForcedSquareOffIst(
          nowUtc: DateTime.utc(2026, 11, 19, 9, 45)),
      isTrue,
    );
    expect(
      ExecutionEngine.computeVolumeCappedFillQty(
        requestedQty: 130,
        lotSize: 65,
        topBookQty: 600,
      ),
      65,
    );
    expect(
      LedgerReconciler.reconcileSnapshots(
        startingCapitalInr: 50000.0,
        orders: const [],
        positions: const [],
        liveLtpBySecurityId: const {},
        isFeedLive: false,
      ).isReconciled,
      isTrue,
    );
    expect(IvGridEngine.buildNoExtrapolationGrid(const []).cells, isEmpty);
    expect(
      QuantStatsEngine.computeFromTradeLogs(
        tradeLogs: [
          {'netPnl': 1200.0, 'exitTimeMs': 1764000000000},
          {'netPnl': -400.0, 'exitTimeMs': 1764003600000},
          {'netPnl': 1600.0, 'exitTimeMs': 1764007200000},
        ],
        startingCapitalInr: 50000.0,
      ).sharpeRatio,
      greaterThan(0),
    );
    expect(TrendlineEngine.detect(const []).breakoutState, 'NO DATA');
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
  });
}
