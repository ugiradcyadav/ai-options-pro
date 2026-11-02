import 'dart:math' as math;
import '../core/models.dart';
import '../data/forever_db.dart';
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

class BacktestEngine {
  static BacktestDataQualityReport auditBarQuality(List bars) {
    int gaps = 0;
    int stale = 0;
    int zeroVol = 0;
    int badTicks = 0;

    for (int i = 0; bars.length > i; i++) {
      final b = bars[i] as OneMinEnrichedBar;
      if (0 >= b.close || 0 >= b.open || 0 >= b.low || b.low > b.high) {
        badTicks++;
      }
      if (0 >= b.intervalVolume) {
        zeroVol++;
      }
      if (i > 0) {
        final prev = bars[i - 1] as OneMinEnrichedBar;
        final dtMs = (b.timestampMs - prev.timestampMs).abs();
        if (dtMs > 300000 && 43200000 > dtMs) {
          gaps++;
        }
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

  /// Async method called by BacktestScreen
  static Future runBacktest({
    required UnderlyingIndex index,
    String timeframe = '15m', String htfRule = '15m',
    required RiskConfig riskConfig,
    double availableCapital = 25000.0,
  }) async {
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: index.label,
      limit: 500,
    );
    return runRealisticBacktest(
      index: index,
      bars: bars,
      riskConfig: riskConfig,
      startingCapital: availableCapital,
      outOfSampleOnly: false,
    );
  }

  static BacktestReport runFiveDayBacktest({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    double startingCapital = 25000.0,
  }) {
    return runRealisticBacktest(
      index: index,
      bars: bars,
      riskConfig: riskConfig,
      startingCapital: startingCapital,
      outOfSampleOnly: false,
    );
  }

  static BacktestReport runRealisticBacktest({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    double startingCapital = 25000.0,
    StrategySettings? settingsOverride,
    bool outOfSampleOnly = true,
  }) {
    final settings =
        settingsOverride ?? StrategySettingsEngine.instance.current;
    final List sorted = List.from(bars);
    sorted.sort((a, b) => (a as OneMinEnrichedBar)
        .timestampMs
        .compareTo((b as OneMinEnrichedBar).timestampMs));

    final dq = auditBarQuality(sorted);
    if (10 > sorted.length) {
      return BacktestReport(
        strategyName: 'Walk-Forward MTF + Black-76 EV (${dq.summary})',
        indexName: index.label,
        htfConfirmation: '${settings.lookbackMinutes}m OI + Next-Bar Open Fill',
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

    const int embargoBars = 3;
    final int oosStartIdx = outOfSampleOnly && sorted.length >= 25
        ? ((sorted.length * 0.40).floor() + embargoBars)
        : 1;

    final lot = index.defaultLotSize;
    final targetFrac = settings.targetPctForIndex(index) / 100.0;
    final stopFrac = settings.stopLossPctForIndex(index) / 100.0;
    final maxHoldBars = settings.timeExitMinutes.clamp(1, 60);

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
    double dailyNetLossInr = 0.0;

    final List tradeLogs = [];
    final List netTradeReturns = [];

    int i = math.max(1, oosStartIdx);
    while (sorted.length - 2 > i) {
      final signalBar = sorted[i] as OneMinEnrichedBar;
      final prevBar = sorted[i - 1] as OneMinEnrichedBar;

      if (0 >= signalBar.close ||
          signalBar.low > signalBar.high ||
          0 >= signalBar.intervalVolume) {
        i++;
        continue;
      }

      final eligible = MtfStrategyEngine.isBarEligibleForEntry(
        bar: signalBar,
        prevBar: prevBar,
        settings: settings,
        index: index,
      );

      if (!eligible) {
        i++;
        continue;
      }

      // M7.3: Fill at NEXT bar open (i + 1)
      final fillBar = sorted[i + 1] as OneMinEnrichedBar;
      if (0 >= fillBar.open) {
        i++;
        continue;
      }

      final rawEntryPrice = fillBar.open;
      final stopPrice = rawEntryPrice * (1.0 - stopFrac);
      final targetPrice = rawEntryPrice * (1.0 + targetFrac);

      final estCosts = RiskEngine.computeRoundTripCostsAndSlippage(
        entryPremium: rawEntryPrice,
        exitPremium: targetPrice,
        quantity: lot,
        spreadPct: fillBar.spreadPct > 0 ? fillBar.spreadPct : 0.25,
        barVolume: fillBar.intervalVolume > 0 ? fillBar.intervalVolume : 1200,
      );

      final reqCapital = (rawEntryPrice * lot) + estCosts.totalFrictionInr;
      if (riskConfig.killSwitchActive ||
          dailyNetLossInr >= riskConfig.maxDailyLossInr ||
          reqCapital > currentEquity) {
        rejectedByRisk++;
        i++;
        continue;
      }

      double rawExitPrice = fillBar.close;
      String exitReason = 'TIME_EXIT';
      int exitBarIdx = i + 1;
      final maxIdx = math.min(sorted.length - 1, i + 1 + maxHoldBars);

      for (int h = i + 1; maxIdx >= h; h++) {
        final hBar = sorted[h] as OneMinEnrichedBar;
        exitBarIdx = h;

        // M7.3: Stop checked BEFORE target inside the same bar
        if (stopPrice >= hBar.low) {
          rawExitPrice = stopPrice;
          exitReason = 'STOP_LOSS (Stop-First)';
          break;
        }
        if (hBar.high >= targetPrice) {
          rawExitPrice = targetPrice;
          exitReason = 'TARGET_HIT';
          break;
        }
        rawExitPrice = hBar.close;
      }

      final realizedCosts = RiskEngine.computeRoundTripCostsAndSlippage(
        entryPremium: rawEntryPrice,
        exitPremium: rawExitPrice,
        quantity: lot,
        spreadPct: fillBar.spreadPct > 0 ? fillBar.spreadPct : 0.25,
        barVolume: fillBar.intervalVolume > 0 ? fillBar.intervalVolume : 1200,
      );

      final grossPnl = (rawExitPrice - rawEntryPrice) * lot;
      final friction = realizedCosts.totalFrictionInr;
      final netPnl = grossPnl - friction;

      totalTrades++;
      grossPnlSum += grossPnl;
      totalFrictionSum += friction;
      netPnlSum += netPnl;
      netTradeReturns.add(netPnl);

      if (netPnl > 0) {
        wins++;
        grossProfitWins += netPnl;
      } else {
        grossLossAbs += netPnl.abs();
        dailyNetLossInr += netPnl.abs();
      }

      currentEquity += netPnl;
      if (currentEquity > peakEquity) peakEquity = currentEquity;
      final dd = peakEquity - currentEquity;
      if (dd > maxDrawdownInr) maxDrawdownInr = dd;

      tradeLogs.add({
        'entryTimeMs': fillBar.timestampMs,
        'exitTimeMs': (sorted[exitBarIdx] as OneMinEnrichedBar).timestampMs,
        'strike': signalBar.strike,
        'optionType': signalBar.optionType,
        'qty': lot,
        'entryPrice': double.parse(rawEntryPrice.toStringAsFixed(2)),
        'exitPrice': double.parse(rawExitPrice.toStringAsFixed(2)),
        'grossPnl': double.parse(grossPnl.toStringAsFixed(2)),
        'charges': double.parse(friction.toStringAsFixed(2)),
        'netPnl': double.parse(netPnl.toStringAsFixed(2)),
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
      strategyName: 'Walk-Forward OOS (${dq.summary})',
      indexName: index.label,
      htfConfirmation:
          '${settings.lookbackMinutes}m OI + Next-Bar Open + Stop-First',
      totalTrades: totalTrades,
      winRatePct: double.parse(winRate.toStringAsFixed(2)),
      grossPnl: double.parse(grossPnlSum.toStringAsFixed(2)),
      totalCharges: double.parse(totalFrictionSum.toStringAsFixed(2)),
      netPnl: double.parse(netPnlSum.toStringAsFixed(2)),
      profitFactor: double.parse(profitFactor.toStringAsFixed(2)),
      maxDrawdown: double.parse(maxDrawdownInr.toStringAsFixed(2)),
      expectancyPerTrade: double.parse(expectancy.toStringAsFixed(2)),
      rejectedByRiskCount: rejectedByRisk,
      tradeLogs: tradeLogs,
      runTimestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
