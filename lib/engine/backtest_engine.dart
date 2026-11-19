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
      if (b.close <= 0 ||
          b.open <= 0 ||
          b.low <= 0 ||
          b.low > b.high) {
        badTicks++;
      }
      if (b.intervalVolume <= 0) zeroVol++;
      if (i > 0) {
        final prev = bars[i - 1] as OneMinEnrichedBar;
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
      limit: 600,
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

  /// 3-Way Chronological Split: 50% Train | embargo | 25% Frozen OOS | embargo | 25% Final Holdout
  static ThreeWayBacktestReport runThreeWayHoldout({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    required double startingCapital,
    required int lotSize,
    StrategySettings? settingsOverride,
  }) {
    final allBars = bars.map((e) => e as OneMinEnrichedBar).toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    final contractCount =
        allBars.where((b) => b.optionType.toUpperCase() != 'SPOT').length;

    const int embargo = 5;
    if (contractCount < 40 || startingCapital <= 0 || lotSize <= 0) {
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
            'Insufficient recorded bars ($contractCount found; need >= 40 for 3-way split).',
      );
    }

    final trainEnd = (contractCount * 0.50).floor();
    final oosStart = trainEnd + embargo;
    final oosEnd = (contractCount * 0.75).floor();
    final holdoutStart = oosEnd + embargo;

    final trainRep = runRealisticBacktest(
      index: index,
      bars: allBars,
      riskConfig: riskConfig,
      startingCapital: startingCapital,
      lotSize: lotSize,
      settingsOverride: settingsOverride,
      outOfSampleOnly: false,
      startIdxOverride: 4,
      endIdxOverride: trainEnd,
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

    final holdoutRep = runRealisticBacktest(
      index: index,
      bars: allBars,
      riskConfig: riskConfig,
      startingCapital: startingCapital,
      lotSize: lotSize,
      settingsOverride: settingsOverride,
      outOfSampleOnly: false,
      startIdxOverride: holdoutStart,
      endIdxOverride: contractCount - 2,
    );

    return ThreeWayBacktestReport(
      trainReport: trainRep,
      frozenOosReport: oosRep,
      finalHoldoutReport: holdoutRep,
      hasSufficientBars: true,
      summaryNote:
          '3-Way Split (50% Train / 25% Frozen OOS / 25% Holdout, $embargo-bar embargo)',
    );
  }

  /// Reruns the exact same recorded bars under 1.0x, 1.5x, and 2.0x friction/slippage stress
  static List<FrictionStressRow> runFrictionStressTest({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    required double startingCapital,
    required int lotSize,
    StrategySettings? settingsOverride,
    bool outOfSampleOnly = true,
  }) {
    const scenarios = [
      {'mult': 1.0, 'label': '1.0x Base (0.15% STT)'},
      {'mult': 1.5, 'label': '1.5x Slippage Stress'},
      {'mult': 2.0, 'label': '2.0x Severe Stress'},
    ];

    final results = <FrictionStressRow>[];
    for (final sc in scenarios) {
      final mult = sc['mult'] as double;
      final rep = runRealisticBacktest(
        index: index,
        bars: bars,
        riskConfig: riskConfig,
        startingCapital: startingCapital,
        lotSize: lotSize,
        settingsOverride: settingsOverride,
        outOfSampleOnly: outOfSampleOnly,
        frictionMultiplier: mult,
      );
      results.add(FrictionStressRow(
        multiplier: mult,
        label: sc['label'] as String,
        totalTrades: rep.totalTrades,
        winRatePct: rep.winRatePct,
        totalChargesInr: rep.totalCharges,
        netPnlInr: rep.netPnl,
        profitFactor: rep.profitFactor,
        maxDrawdownInr: rep.maxDrawdown,
      ));
    }
    return results;
  }

  /// Calls MtfStrategyEngine.evaluateEntry() chronologically with IST day-reset loss, real-minute hold, and gap-aware stop fills
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
    final contractBars = allBars
        .where((b) => b.optionType.toUpperCase() != 'SPOT')
        .toList();

    final dq = auditBarQuality(contractBars);
    if (contractBars.length < 10 || startingCapital <= 0 || lotSize <= 0) {
      return BacktestReport(
        strategyName: 'Walk-Forward OOS (NO DATA or unresolved lot/capital)',
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

    const int embargoBars = 5;
    final int defaultStart = outOfSampleOnly && contractBars.length >= 25
        ? ((contractBars.length * 0.40).floor() + embargoBars)
        : 4;
    final int startIdx = math.max(4, startIdxOverride ?? defaultStart);
    final int endIdx =
        math.min(contractBars.length - 2, endIdxOverride ?? (contractBars.length - 2));

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

    // Strictly chronological loop: next trade cannot start until prior trade settles
    int i = startIdx;
    while (i < endIdx) {
      final bar = contractBars[i];
      final barDay = _istDayKey(bar.timestampMs);
      if (barDay != currentIstDay) {
        currentIstDay = barDay;
        todayNetRealizedPnlIst = 0.0;
      }

      final causalSpots = spotBars
          .where((s) => s.timestampMs <= bar.timestampMs)
          .toList();

      final isCallBar = bar.optionType.toUpperCase() == 'CE';
      final snap = StrikeRowSnapshot(
        strike: bar.strike,
        offset: bar.strikeOffset,
        ceSecurityId: isCallBar ? bar.contractId : '',
        peSecurityId: isCallBar ? '' : bar.contractId,
        lotSize: lotSize,
        ceLtp: isCallBar ? bar.close : 0.0,
        peLtp: isCallBar ? 0.0 : bar.close,
        ceOi: isCallBar ? bar.absoluteOi : (bar.absoluteOi * 0.90).round(),
        peOi: isCallBar ? (bar.absoluteOi * 1.12).round() : bar.absoluteOi,
        ceOiChange5m: isCallBar ? bar.oiChange5m : 0,
        peOiChange5m: isCallBar ? 0 : bar.oiChange5m,
        ceOiChange15m: isCallBar ? bar.oiChange15m : 0,
        peOiChange15m: isCallBar ? 0 : bar.oiChange15m,
        ceOiChange60m: isCallBar ? bar.oiChange60m : 0,
        peOiChange60m: isCallBar ? 0 : bar.oiChange60m,
        ceVolume: isCallBar ? bar.intervalVolume : 0,
        peVolume: isCallBar ? 0 : bar.intervalVolume,
        ceIv: isCallBar ? bar.iv : null,
        peIv: isCallBar ? null : bar.iv,
        ceDelta: isCallBar ? bar.delta : 0.0,
        peDelta: isCallBar ? 0.0 : bar.delta,
        ceGamma: isCallBar ? bar.gamma : 0.0,
        peGamma: isCallBar ? 0.0 : bar.gamma,
        ceTheta: isCallBar ? bar.theta : 0.0,
        peTheta: isCallBar ? 0.0 : bar.theta,
        ceVega: isCallBar ? bar.vega : 0.0,
        peVega: isCallBar ? 0.0 : bar.vega,
        ceImbalance: isCallBar ? bar.orderBookImbalance : null,
        peImbalance: isCallBar ? null : bar.orderBookImbalance,
        source: 'BACKTEST_RECORDED',
        exchangeTimestampMs: bar.timestampMs,
        receivedAtMs: bar.timestampMs,
      );

      final sig = MtfStrategyEngine.evaluateEntry(
        index: index,
        expiry: bar.expiry,
        spot: bar.underlyingSpot,
        dataHealth: DataHealthStatus.live,
        chainRows: [snap],
        recentSpotBars: causalSpots,
        availableCapital: currentEquity,
        riskConfig: riskConfig,
        openPositionsCount: 0,
        todayNetRealizedPnlIst: todayNetRealizedPnlIst,
        openPositionsRiskInr: 0.0,
        settingsOverride: settings,
        timestampMsOverride: bar.timestampMs,
      );

      if (sig.action == SignalAction.noTrade || !sig.riskWithinLimits) {
        if (sig.strategyPassed && !sig.riskWithinLimits) rejectedByRisk++;
        i++;
        continue;
      }

      final fillBar = contractBars[i + 1];
      if (_istDayKey(fillBar.timestampMs) != barDay || fillBar.open <= 0) {
        i++;
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
      int exitBarIdx = i + 1;

      for (int h = i + 1; h <= endIdx; h++) {
        final hBar = contractBars[h];
        if (_istDayKey(hBar.timestampMs) != barDay) break;
        exitBarIdx = h;

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
        'entryTimeMs': fillBar.timestampMs,
        'exitTimeMs': contractBars[exitBarIdx].timestampMs,
        'strike': bar.strike,
        'optionType': bar.optionType,
        'qty': qty,
        'entryPrice': rawEntry,
        'exitPrice': rawExit,
        'grossPnl': grossPnl,
        'charges': friction,
        'netPnl': netPnl,
        'reason': exitReason,
      });

      i = exitBarIdx + 1;
    }

    final winRate =
        totalTrades > 0 ? (wins / totalTrades.toDouble()) * 100.0 : 0.0;
    final expectancy =
        totalTrades > 0 ? (netPnlSum / totalTrades.toDouble()) : 0.0;
    final profitFactor = grossLossAbs > 0
        ? (grossProfitWins / grossLossAbs)
        : (grossProfitWins > 0 ? 9.99 : 0.0);

    return BacktestReport(
      strategyName:
          'Unified Walk-Forward ${outOfSampleOnly ? "OOS" : "Window"} (${frictionMultiplier.toStringAsFixed(1)}x Friction)',
      indexName: index.label,
      htfConfirmation: 'Same evaluateEntry() • Gap-Aware Stops • 0.15% STT',
      totalTrades: totalTrades,
      winRatePct: winRate,
      grossPnl: grossPnlSum,
      totalCharges: totalFrictionSum,
      netPnl: netPnlSum,
      profitFactor: profitFactor,
      maxDrawdown: maxDrawdownInr,
      expectancyPerTrade: expectancy,
      rejectedByRiskCount: rejectedByRisk,
      tradeLogs: tradeLogs,
      runTimestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
