import 'dart:math' as math;
import '../core/models.dart';
import '../data/forever_db.dart';
import '../data/scrip_master_engine.dart';
import 'mtf_strategy_engine.dart';
import 'risk_engine.dart';
import 'strategy_settings.dart';

class BacktestDataQualityReport {
  final int totalBarsChecked;
  final int gapCount;
  final int staleQuoteCount;
  final int zeroVolumeCount;
  final int badTickCount;

  const BacktestDataQualityReport({
    required this.totalBarsChecked,
    required this.gapCount,
    required this.staleQuoteCount,
    required this.zeroVolumeCount,
    required this.badTickCount,
  });

  String get summary =>
      'Bars:$totalBarsChecked | Gaps:$gapCount | Stale:$staleQuoteCount | ZeroVol:$zeroVolumeCount';
}

class FrictionStressRow {
  final double multiplier;
  final String label;
  final int totalTrades;
  final double winRatePct;
  final double totalChargesInr;
  final double netPnlInr;
  final double profitFactor;
  final double maxDrawdownInr;

  const FrictionStressRow({
    required this.multiplier,
    required this.label,
    required this.totalTrades,
    required this.winRatePct,
    required this.totalChargesInr,
    required this.netPnlInr,
    required this.profitFactor,
    required this.maxDrawdownInr,
  });

  bool get survives => totalTrades > 0 && netPnlInr > 0;
}

class ThreeWayBacktestReport {
  final BacktestReport trainReport;
  final BacktestReport frozenOosReport;
  final BacktestReport finalHoldoutReport;
  final bool hasSufficientBars;
  final String summaryNote;

  const ThreeWayBacktestReport({
    required this.trainReport,
    required this.frozenOosReport,
    required this.finalHoldoutReport,
    required this.hasSufficientBars,
    required this.summaryNote,
  });
}

class BacktestEngine {
  static BacktestDataQualityReport auditBarQuality(List bars) {
    int gaps = 0;
    int stale = 0;
    int zeroVol = 0;
    int badTicks = 0;

    for (int i = 0; i < bars.length; i++) {
      final b = bars[i] as OneMinEnrichedBar;
      if (b.close <= 0 || b.open <= 0 || b.low <= 0 || b.low > b.high) {
        badTicks++;
      }
      if (b.intervalVolume <= 0) zeroVol++;
      if (i > 0) {
        final prev = bars[i - 1] as OneMinEnrichedBar;
        if (prev.contractId == b.contractId) {
          final dtMs = (b.timestampMs - prev.timestampMs).abs();
          if (dtMs > 300000 && dtMs < 43200000) gaps++;
          if (b.close == prev.close &&
              b.open == prev.open &&
              b.high == prev.high &&
              b.low == prev.low) {
            stale++;
          }
        }
      }
    }
    return BacktestDataQualityReport(
      totalBarsChecked: bars.length,
      gapCount: gaps,
      staleQuoteCount: stale,
      zeroVolumeCount: zeroVol,
      badTickCount: badTicks,
    );
  }

  static String _istDayKey(int timestampMs) {
    final ist = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true)
        .add(const Duration(hours: 5, minutes: 30));
    return '${ist.year}-${ist.month}-${ist.day}';
  }

  static Future<BacktestReport> runBacktest({
    UnderlyingIndex index = UnderlyingIndex.nifty50,
    String timeframe = '15m',
    RiskConfig riskConfig = const RiskConfig(),
    double? availableCapital,
    bool outOfSampleOnly = true,
    double frictionMultiplier = 1.0,
  }) async {
    final optBars = await ForeverDatabase.instance.getRecentBars(
      indexName: index.label,
      limit: 800,
    );
    final lotSize = ScripMasterEngine.instance.getLotSizeForIndex(index) ?? 0;
    return runRealisticBacktest(
      index: index,
      bars: optBars,
      riskConfig: riskConfig,
      startingCapital: availableCapital ?? 0.0,
      lotSize: lotSize,
      outOfSampleOnly: outOfSampleOnly,
      frictionMultiplier: frictionMultiplier,
    );
  }

  /// 3-Way Chronological Split on unique timestamps: 50% Train | embargo | 25% Frozen OOS | embargo | 25% Holdout
  static ThreeWayBacktestReport runThreeWayHoldout({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    required double startingCapital,
    required int lotSize,
    StrategySettings? settingsOverride,
  }) {
    final allBars = bars.map((e) => e as OneMinEnrichedBar).toList();
    final uniqueTs = allBars
        .where((b) => b.optionType.toUpperCase() != 'SPOT')
        .map((b) => b.timestampMs)
        .toSet()
        .toList()
      ..sort();

    if (uniqueTs.length < 30 || startingCapital <= 0 || lotSize <= 0) {
      final empty = runRealisticBacktest(
        index: index,
        bars: const [],
        riskConfig: riskConfig,
        startingCapital: startingCapital,
        lotSize: lotSize,
        settingsOverride: settingsOverride,
      );
      return ThreeWayBacktestReport(
        trainReport: empty,
        frozenOosReport: empty,
        finalHoldoutReport: empty,
        hasSufficientBars: false,
        summaryNote:
            'Need >= 30 recorded chain timestamps for 3-way holdout (have ${uniqueTs.length}).',
      );
    }

    const embargo = 3;
    final tEnd = (uniqueTs.length * 0.50).floor();
    final oosStart = math.min(uniqueTs.length - 5, tEnd + embargo);
    final oosEnd = math.min(uniqueTs.length - 3, (uniqueTs.length * 0.75).floor());
    final holdStart = math.min(uniqueTs.length - 2, oosEnd + embargo);

    final trainRep = runRealisticBacktest(
      index: index,
      bars: allBars,
      riskConfig: riskConfig,
      startingCapital: startingCapital,
      lotSize: lotSize,
      settingsOverride: settingsOverride,
      outOfSampleOnly: false,
      startIdxOverride: 4,
      endIdxOverride: tEnd,
    );
    final oosRep = runRealisticBacktest(
      index: index,
      bars: allBars,
      riskConfig: riskConfig,
      startingCapital: startingCapital,
      lotSize: lotSize,
      settingsOverride: settingsOverride,
      outOfSampleOnly: false,
      startIdxOverride: oosStart,
      endIdxOverride: oosEnd,
    );
    final holdRep = runRealisticBacktest(
      index: index,
      bars: allBars,
      riskConfig: riskConfig,
      startingCapital: startingCapital,
      lotSize: lotSize,
      settingsOverride: settingsOverride,
      outOfSampleOnly: false,
      startIdxOverride: holdStart,
      endIdxOverride: uniqueTs.length - 2,
    );

    return ThreeWayBacktestReport(
      trainReport: trainRep,
      frozenOosReport: oosRep,
      finalHoldoutReport: holdRep,
      hasSufficientBars: true,
      summaryNote:
          '3-Way Per-Contract Split (${uniqueTs.length} timestamps): Train ${trainRep.totalTrades}t | OOS ${oosRep.totalTrades}t | Holdout ${holdRep.totalTrades}t',
    );
  }

  static List<FrictionStressRow> runFrictionStressTest({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    required double startingCapital,
    required int lotSize,
    StrategySettings? settingsOverride,
    bool outOfSampleOnly = true,
  }) {
    final specs = [
      (1.0, '1.0x Baseline'),
      (1.5, '1.5x Stressed'),
      (2.0, '2.0x Extreme'),
    ];
    return specs.map((sp) {
      final r = runRealisticBacktest(
        index: index,
        bars: bars,
        riskConfig: riskConfig,
        startingCapital: startingCapital,
        lotSize: lotSize,
        settingsOverride: settingsOverride,
        outOfSampleOnly: outOfSampleOnly,
        frictionMultiplier: sp.$1,
      );
      return FrictionStressRow(
        multiplier: sp.$1,
        label: sp.$2,
        totalTrades: r.totalTrades,
        winRatePct: r.winRatePct,
        totalChargesInr: r.totalCharges,
        netPnlInr: r.netPnl,
        profitFactor: r.profitFactor,
        maxDrawdownInr: r.maxDrawdown,
      );
    }).toList();
  }

  /// C1 + C2 + C3 Fixed Backtester:
  /// - Replays REAL timestamp-grouped multi-strike chains (zero fabricated opposite OI)
  /// - Enters and exits strictly on the SAME contractId's own timeline
  /// - Completely stateless & reproducible across runs
  static BacktestReport runRealisticBacktest({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    required double startingCapital,
    required int lotSize,
    StrategySettings? settingsOverride,
    bool outOfSampleOnly = true,
    double frictionMultiplier = 1.0,
    int? startIdxOverride,
    int? endIdxOverride,
  }) {
    final settings = settingsOverride ?? StrategySettingsEngine.instance.current;
    final allBars = bars.map((e) => e as OneMinEnrichedBar).toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    final spotBars = allBars
        .where((b) => b.optionType.toUpperCase() == 'SPOT')
        .toList();
    final optionBars = allBars
        .where((b) => b.optionType.toUpperCase() != 'SPOT')
        .toList();

    final dq = auditBarQuality(optionBars);

    // 1. Group option bars by contractId (C1: isolated per-contract timelines)
    final Map<String, List<OneMinEnrichedBar>> contractTimelines = {};
    // 2. Group option bars by timestampMs -> strike -> CE/PE (C2: real chain replay)
    final Map<int, Map<int, Map<String, OneMinEnrichedBar>>> chainByTs = {};

    for (final b in optionBars) {
      contractTimelines.putIfAbsent(b.contractId, () => []).add(b);
      final byStrike = chainByTs.putIfAbsent(b.timestampMs, () => {});
      final sideMap = byStrike.putIfAbsent(b.strike, () => {});
      sideMap[b.optionType.toUpperCase()] = b;
    }

    for (final list in contractTimelines.values) {
      list.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    }

    final timestamps = chainByTs.keys.toList()..sort();

    if (timestamps.length < 6 || startingCapital <= 0 || lotSize <= 0) {
      return BacktestReport(
        strategyName: 'Sadhu Per-Contract OOS (NO DATA or unresolved lot/capital)',
        indexName: index.label,
        htfConfirmation: dq.summary,
        totalTrades: 0,
        winRatePct: 0.0,
        grossPnl: 0.0,
        totalCharges: 0.0,
        netPnl: 0.0,
        profitFactor: 0.0,
        maxDrawdown: 0.0,
        expectancyPerTrade: 0.0,
        rejectedByRiskCount: 0,
        tradeLogs: const [],
        runTimestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    }

    const int embargoSteps = 3;
    final int defaultStart = outOfSampleOnly && timestamps.length >= 20
        ? ((timestamps.length * 0.40).floor() + embargoSteps)
        : 4;
    final int startIdx = math.max(0, startIdxOverride ?? defaultStart);
    final int endIdx =
        math.min(timestamps.length - 2, endIdxOverride ?? (timestamps.length - 2));

    int totalTrades = 0;
    int wins = 0;
    int rejectedByRisk = 0;
    double grossPnlSum = 0.0;
    double totalFrictionSum = 0.0;
    double netPnlSum = 0.0;
    double grossProfitWins = 0.0;
    double grossLossAbs = 0.0;
    double peakEquity = startingCapital;
    double currentEquity = startingCapital;
    double maxDrawdownInr = 0.0;

    String currentIstDay = '';
    double todayNetRealizedPnlIst = 0.0;
    final List tradeLogs = [];

    int tIdx = startIdx;
    while (tIdx <= endIdx) {
      final ts = timestamps[tIdx];
      final barDay = _istDayKey(ts);
      if (barDay != currentIstDay) {
        currentIstDay = barDay;
        todayNetRealizedPnlIst = 0.0;
      }

      // Build REAL chain snapshot at timestamp `ts` (zero invented opposite-side OI)
      final byStrike = chainByTs[ts]!;
      final chainRows = <StrikeRowSnapshot>[];
      double spotAtTs = 0.0;
      String expiryAtTs = '';

      for (final entry in byStrike.entries) {
        final ce = entry.value['CE'];
        final pe = entry.value['PE'];
        final ref = ce ?? pe;
        if (ref == null) continue;
        if (spotAtTs <= 0 && ref.underlyingSpot > 0) {
          spotAtTs = ref.underlyingSpot;
        }
        if (expiryAtTs.isEmpty && ref.expiry.isNotEmpty) {
          expiryAtTs = ref.expiry;
        }
        chainRows.add(StrikeRowSnapshot(
          strike: entry.key,
          offset: ref.strikeOffset,
          ceSecurityId: ce?.contractId ?? '',
          peSecurityId: pe?.contractId ?? '',
          ceTradingSymbol: ce != null ? '${index.dhanSymbol}_${entry.key}_CE' : '',
          peTradingSymbol: pe != null ? '${index.dhanSymbol}_${entry.key}_PE' : '',
          lotSize: lotSize,
          ceLtp: ce?.close ?? 0.0,
          peLtp: pe?.close ?? 0.0,
          ceOi: ce?.absoluteOi ?? 0,
          peOi: pe?.absoluteOi ?? 0,
          ceOiChange5m: ce?.oiChange5m,
          peOiChange5m: pe?.oiChange5m,
          ceOiChange15m: ce?.oiChange15m,
          peOiChange15m: pe?.oiChange15m,
          ceOiChange60m: ce?.oiChange60m,
          peOiChange60m: pe?.oiChange60m,
          ceVolume: ce?.intervalVolume ?? 0,
          peVolume: pe?.intervalVolume ?? 0,
          ceIv: ce?.iv,
          peIv: pe?.iv,
          ceDelta: ce?.delta ?? 0.0,
          peDelta: pe?.delta ?? 0.0,
          ceGamma: ce?.gamma ?? 0.0,
          peGamma: pe?.gamma ?? 0.0,
          ceTheta: ce?.theta ?? 0.0,
          peTheta: pe?.theta ?? 0.0,
          ceVega: ce?.vega ?? 0.0,
          peVega: pe?.vega ?? 0.0,
          ceImbalance: ce?.orderBookImbalance,
          peImbalance: pe?.orderBookImbalance,
          source: 'BACKTEST_REAL_CHAIN',
          exchangeTimestampMs: ts,
          receivedAtMs: ts,
        ));
      }

      final causalSpots =
          spotBars.where((s) => s.timestampMs <= ts).toList();

      final sig = MtfStrategyEngine.evaluateEntry(
        index: index,
        expiry: expiryAtTs,
        spot: spotAtTs,
        dataHealth: DataHealthStatus.live,
        chainRows: chainRows,
        recentSpotBars: causalSpots,
        availableCapital: currentEquity,
        riskConfig: riskConfig,
        openPositionsCount: 0,
        todayNetRealizedPnlIst: todayNetRealizedPnlIst,
        openPositionsRiskInr: 0.0,
        settingsOverride: settings,
        timestampMsOverride: ts,
      );

      if (sig.action == SignalAction.noTrade || !sig.riskWithinLimits) {
        if (sig.strategyPassed && !sig.riskWithinLimits) {
          rejectedByRisk++;
        }
        tIdx++;
        continue;
      }

      // C1 Fix: Walk STRICTLY on the chosen contract's own timeline
      final ownTimeline = contractTimelines[sig.securityId];
      if (ownTimeline == null || ownTimeline.isEmpty) {
        tIdx++;
        continue;
      }
      final fillIdx = ownTimeline.indexWhere((b) => b.timestampMs > ts);
      if (fillIdx == -1) {
        tIdx++;
        continue;
      }
      final fillBar = ownTimeline[fillIdx];
      if (_istDayKey(fillBar.timestampMs) != barDay || fillBar.open <= 0) {
        tIdx++;
        continue;
      }

      final rawEntry = fillBar.open;
      final targetPrice =
          rawEntry * (1.0 + settings.targetPctForIndex(index) / 100.0);
      final stopPrice =
          rawEntry * (1.0 - settings.stopLossPctForIndex(index) / 100.0);
      final maxHoldMs = settings.timeExitMinutes * 60000;

      double rawExit = fillBar.close;
      String exitReason = 'TIME_EXIT';
      int exitTsMs = fillBar.timestampMs;

      for (int h = fillIdx; h < ownTimeline.length; h++) {
        final hBar = ownTimeline[h];
        if (_istDayKey(hBar.timestampMs) != barDay) break;
        exitTsMs = hBar.timestampMs;

        if (hBar.open <= stopPrice) {
          rawExit = hBar.open;
          exitReason = 'GAP_STOP_LOSS';
          break;
        }
        if (hBar.low <= stopPrice) {
          rawExit = stopPrice;
          exitReason = 'STOP_LOSS';
          break;
        }
        if (hBar.high >= targetPrice) {
          rawExit = targetPrice;
          exitReason = 'TARGET_HIT';
          break;
        }
        rawExit = hBar.close;
        if (hBar.timestampMs - fillBar.timestampMs >= maxHoldMs) {
          exitReason = 'TIME_EXIT';
          break;
        }
      }

      final qty = sig.quantity;
      final realizedCosts = RiskEngine.computeRoundTripCostsAndSlippage(
        entryPremium: rawEntry,
        exitPremium: rawExit,
        quantity: qty,
        spreadPct: fillBar.spreadPct ?? 0.25,
        barVolume: fillBar.intervalVolume > 0 ? fillBar.intervalVolume : 1000,
      );

      final grossPnl = (rawExit - rawEntry) * qty;
      final friction = realizedCosts.totalFrictionInr * frictionMultiplier;
      final netPnl = grossPnl - friction;

      totalTrades++;
      grossPnlSum += grossPnl;
      totalFrictionSum += friction;
      netPnlSum += netPnl;
      todayNetRealizedPnlIst += netPnl;

      if (netPnl > 0) {
        wins++;
        grossProfitWins += netPnl;
      } else {
        grossLossAbs += netPnl.abs();
      }

      currentEquity += netPnl;
      if (currentEquity > peakEquity) peakEquity = currentEquity;
      final dd = peakEquity - currentEquity;
      if (dd > maxDrawdownInr) maxDrawdownInr = dd;

      tradeLogs.add({
        'contractId': sig.securityId,
        'strike': sig.strike,
        'action': sig.action.label,
        'entryTimeMs': fillBar.timestampMs,
        'exitTimeMs': exitTsMs,
        'entry': rawEntry,
        'exit': rawExit,
        'qty': qty,
        'grossPnl': grossPnl,
        'friction': friction,
        'netPnl': netPnl,
        'reason': exitReason,
      });

      // Advance chronological clock past exitTsMs so trades never overlap
      while (tIdx <= endIdx && timestamps[tIdx] <= exitTsMs) {
        tIdx++;
      }
    }

    final winRate = totalTrades > 0 ? (wins / totalTrades) * 100.0 : 0.0;
    final pf = grossLossAbs > 0
        ? (grossProfitWins / grossLossAbs)
        : (grossProfitWins > 0 ? 9.99 : 0.0);
    final expPerTrade = totalTrades > 0 ? (netPnlSum / totalTrades) : 0.0;

    return BacktestReport(
      strategyName: 'Sadhu Per-Contract OOS (${frictionMultiplier}x Cost)',
      indexName: index.label,
      htfConfirmation: dq.summary,
      totalTrades: totalTrades,
      winRatePct: winRate,
      grossPnl: grossPnlSum,
      totalCharges: totalFrictionSum,
      netPnl: netPnlSum,
      profitFactor: pf,
      maxDrawdown: maxDrawdownInr,
      expectancyPerTrade: expPerTrade,
      rejectedByRiskCount: rejectedByRisk,
      tradeLogs: tradeLogs,
      runTimestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
