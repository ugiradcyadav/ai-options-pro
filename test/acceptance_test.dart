import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_options_pro/core/models.dart';
import 'package:ai_options_pro/core/totp_auth.dart';
import 'package:ai_options_pro/data/angel_smartapi_engine.dart';
import 'package:ai_options_pro/data/angel_ws_streamer.dart';
import 'package:ai_options_pro/data/constituent_flow_engine.dart';
import 'package:ai_options_pro/data/news_wire_engine.dart';
import 'package:ai_options_pro/data/participant_oi_engine.dart';
import 'package:ai_options_pro/data/scrip_master_engine.dart';
import 'package:ai_options_pro/engine/backtest_engine.dart';
import 'package:ai_options_pro/engine/execution_engine.dart';
import 'package:ai_options_pro/engine/exit_manager.dart';
import 'package:ai_options_pro/engine/iv_grid_engine.dart';
import 'package:ai_options_pro/engine/journal_coach_engine.dart';
import 'package:ai_options_pro/engine/ledger_reconciler.dart';
import 'package:ai_options_pro/engine/math_greeks.dart';
import 'package:ai_options_pro/engine/microstructure_engine.dart';
import 'package:ai_options_pro/engine/minor_intel_engine.dart';
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
    final baseMs = DateTime.utc(2026, 11, 20, 4, 30).millisecondsSinceEpoch;
    final bars = <OneMinEnrichedBar>[];

    for (int i = 0; i < 10; i++) {
      final ts = baseMs + i * 60000;
      final spot = 24000.0 + i * 25.0;
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
        absoluteOi: 160000,
        oiChange15m: 90000,
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

  test('Phase2_IntelLayers: FUTIDX + NSE Participant OI + RSS News + Minor Pulse', () {
    // 1. FUTIDX resolution
    final master = ScripMasterEngine.instance;
    master.loadFromAngelJsonList([
      {
        'token': '99001',
        'symbol': 'NIFTY26NOV26FUT',
        'name': 'NIFTY',
        'expiry': '26NOV2026',
        'strike': '0',
        'lotsize': '65',
        'instrumenttype': 'FUTIDX',
        'exch_seg': 'NFO',
      },
      {
        'token': '99002',
        'symbol': 'NIFTY26NOV2624000CE',
        'name': 'NIFTY',
        'expiry': '26NOV2026',
        'strike': '2400000',
        'lotsize': '65',
        'instrumenttype': 'OPTIDX',
        'exch_seg': 'NFO',
      },
    ], referenceNowUtc: DateTime.utc(2026, 11, 25, 6, 0));
    final fut = master.getNearestFutureForIndex(UnderlyingIndex.nifty50);
    expect(fut?.securityId, '99001');
    expect(fut?.tradingSymbol, 'NIFTY26NOV26FUT');

    // 2. Official NSE Participant OI CSV parsing
    const sampleCsv = 'Participant Wise Open Interest\n'
        'Client Type,Future Index Long,Future Index Short,Future Stock Long,Future Stock Short,Option Index Call Long,Option Index Put Long,Option Index Call Short,Option Index Put Short\n'
        'Client,250000,180000,1000,1000,500000,400000,450000,380000\n'
        'DII,80000,40000,1000,1000,10000,20000,5000,10000\n'
        'FII,120000,180000,1000,1000,200000,300000,260000,220000\n'
        'Pro,60000,110000,1000,1000,150000,140000,145000,250000\n';
    final oiSnap = ParticipantOiEngine.parseNseCsv(sampleCsv, '25-Nov-2026');
    expect(oiSnap, isNotNull);
    expect(oiSnap!.fii?.netIndexFutures, -60000);
    expect(oiSnap.fii?.futLongRatioPct, closeTo(40.0, 0.1));
    expect(oiSnap.dii?.netIndexFutures, 40000);

    // 3. Official RSS News parsing & high-impact tagging
    const sampleRss = '<rss><channel>'
        '<item><title>RBI MPC announces Repo Rate policy update</title>'
        '<link>https://rbi.org.in/pr1</link>'
        '<pubDate>Thu, 26 Nov 2026 04:00:00 GMT</pubDate></item>'
        '<item><title>HDFC Bank quarterly disclosure</title>'
        '<link>https://nseindia.com/a1</link>'
        '<pubDate>Thu, 26 Nov 2026 04:15:00 GMT</pubDate></item>'
        '</channel></rss>';
    final rbiNews = NewsWireEngine.parseRssXml(sampleRss, 'RBI');
    expect(rbiNews.length, 2);
    expect(rbiNews.first.isHighImpact, isTrue);
    expect(rbiNews.first.impactTag, 'POLICY');
    final nseNews = NewsWireEngine.parseRssXml(sampleRss, 'NSE');
    expect(nseNews[1].isHighImpact, isTrue);
    expect(nseNews[1].impactTag, 'HEAVYWEIGHT');

    // 4. Heavyweight narrow-rally trap math
    ConstituentFlowItem mkStock(String sym, double chg) => ConstituentFlowItem(
          symbol: sym,
          ltp: 1000,
          open: 1000,
          high: 1020,
          low: 990,
          changePct: chg,
          volume: 100000,
          turnoverCr: 10.0,
          rangePressure: chg >= 0 ? 0.8 : 0.2,
        );
    final constSnap = IndexConstituentFlowSnapshot(
      index: UnderlyingIndex.nifty50,
      items: [
        mkStock('HDFCBANK', 2.5),
        mkStock('RELIANCE', 2.0),
        mkStock('ICICIBANK', 2.0),
        mkStock('ITC', -0.2),
        mkStock('WIPRO', -0.2),
        mkStock('TECHM', -0.2),
        mkStock('CIPLA', -0.2),
        mkStock('ONGC', -0.2),
        mkStock('NTPC', -0.2),
        mkStock('BEL', -0.2),
      ],
      fetchedAtMs: 1764000000000,
    );
    final contrib = MinorIntelEngine.computeHeavyweightPoints(
      index: UnderlyingIndex.nifty50,
      spot: 24000.0,
      constituents: constSnap,
    );
    expect(contrib.isNarrowTrap, isTrue);
    expect(contrib.topDrivers.first.symbol, 'HDFCBANK');

    // 5. 0-DTE Straddle & Gamma Blast Zone + ORB Trap
    final straddle = MinorIntelEngine.instance.evaluateStraddleAndGamma(
      index: UnderlyingIndex.nifty50,
      expiryIso: '2026-11-26',
      spot: 24000.0,
      nowUtc: DateTime.utc(2026, 11, 26, 5, 0),
      rows: const [
        StrikeRowSnapshot(
          strike: 24000,
          offset: 0,
          ceSecurityId: 'C1',
          peSecurityId: 'P1',
          ceTradingSymbol: 'NIFTY_24000_CE',
          peTradingSymbol: 'NIFTY_24000_PE',
          lotSize: 65,
          ceLtp: 120.0,
          peLtp: 110.0,
          ceOi: 50000,
          peOi: 60000,
          ceVolume: 10000,
          peVolume: 10000,
          ceDelta: 0.5,
          peDelta: -0.5,
          ceGamma: 0.002,
          peGamma: 0.002,
          ceTheta: -20.0,
          peTheta: -20.0,
          ceVega: 5.0,
          peVega: 5.0,
          source: 'TEST',
          exchangeTimestampMs: 1764000000000,
          receivedAtMs: 1764000000000,
        ),
      ],
    );
    expect(straddle, isNotNull);
    expect(straddle!.atmStraddlePrice, closeTo(230.0, 1e-6));
    expect(straddle.isZeroDte, isTrue);
    expect(straddle.gammaBlastAlert, isTrue);

    final orbBaseMs = DateTime.utc(2026, 11, 26, 3, 45).millisecondsSinceEpoch; // 09:15 IST
    final orbBars = List.generate(
      5,
      (i) => OneMinEnrichedBar(
        timestampMs: orbBaseMs + i * 60000,
        contractId: 'SPOT_NIFTY',
        indexName: 'NIFTY 50',
        expiry: '2026-11-26',
        strike: 0,
        optionType: 'SPOT',
        strikeOffset: 0,
        underlyingSpot: 24050.0,
        open: 24040.0,
        high: 24100.0,
        low: 24000.0,
        close: 24050.0,
        intervalVolume: 0,
        absoluteOi: 0,
        delta: 1,
        gamma: 0,
        theta: 0,
        vega: 0,
      ),
    );
    final orb = MinorIntelEngine.evaluateOrbAndLevels(
      spotBars: orbBars,
      liveSpot: 24150.0,
      breadthUpPct: 35.0,
    );
    expect(orb.stateLabel, 'ABOVE ORB');
    expect(orb.divergenceTrap, isTrue);
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
    expect(MicrostructureEngine.instance.ingestTick(tick!).weightedObi,
        greaterThan(0.4));

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
