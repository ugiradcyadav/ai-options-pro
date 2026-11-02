import 'dart:math' as math;
import '../core/models.dart';
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
      'Bars:$totalBarsChecked | Gaps:$gapCount | Stale:$staleQuoteCount | ZeroVol:$zeroVolumeCount | BadTicks:$badTickCount';
}

class BacktestEngine {
  /// M7.6: Data-Quality Auditor for 1-minute option bars
  static BacktestDataQualityReport auditBarQuality(List<OneMinEnrichedBar> bars) {
    int gaps = 0;
    int stale = 0;
    int zeroVol = 0;
    int badTicks = 0;

    for (int i = 0; i < bars.length; i++) {
      final b = bars[i];
      if (b.close <= 0 || b.open <= 0 || b.low <= 0 || b.high < b.low) {
        badTicks++;
      }
      if (b.intervalVolume <= 0) {
        zeroVol++;
      }
      if (i > 0) {
        final prev = bars[i - 1];
        final dtMs = (b.timestampMs - prev.timestampMs).abs();
        if (dtMs > 5 * 60 * 1000 && dtMs < 12 * 3600 * 1000) {
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

  /// Compatibility alias so any existing caller in app_state.dart or UI works without error
  static BacktestReport runFiveDayBacktest({
    required UnderlyingIndex index,
    required List<OneMinEnrichedBar> bars,
    required RiskConfig riskConfig,
    double startingCapital = 25000.0,
  }) {
    return runRealisticBacktest(
      index: index,
      bars: bars,
      riskConfig: riskConfig,
      startingCapital: startingCapital,
    );
  }

  /// M7: Walk-Forward Out-of-Sample Realistic Backtester
  static BacktestReport runRealisticBacktest({
    required UnderlyingIndex index,
    required List<OneMinEnrichedBar> bars,
    required RiskConfig riskConfig,
    double startingCapital = 25000.0,
    StrategySettings? settingsOverride,
    bool outOfSampleOnly = true,
  }) {
    final settings =
        settingsOverride ?? StrategySettingsEngine.instance.current;
    final sorted = List<OneMinEnrichedBar>.from(bars)
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    final dq = auditBarQuality(sorted);
    if (sorted.length < 10) {
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

    // M7.5: Walk-Forward split (Train + Embargo, then evaluate strictly on Out-of-Sample window)
    const int embargoBars = 3;
    final int oosStartIdx = outOfSampleOnly && sorted.length >= 25
        ? ((sorted.length * 0.40).floor() + embargoBars)
        : 2;

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

    final List> tradeLogs = [];
    final List<double> netTradeReturns = [];

    // M7.4: Test EVERY eligible bar (step = 1, never skip every 3rd bar unless inside an active position)
    int i = math.max(1, oosStartIdx);
    while (i < sorted.length - 2) {
      final signalBar = sorted[i];
      final prevBar = sorted[i - 1];

      // M7.6: Skip bad ticks or zero-volume bars
      if (signalBar.close <= 0 ||
          signalBar.high < signalBar.low ||
          signalBar.intervalVolume <= 0) {
        i++;
        continue;
      }

      // M7.7: Call single-source-of-truth eligibility function from MtfStrategyEngine
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

      // M7.3: Fill at NEXT bar open (i + 1), never at signalBar.close!
      final fillBar = sorted[i + 1];
      if (fillBar.open <= 0) {
        i++;
        continue;
      }

      final rawEntryPrice = fillBar.open;
      final stopPrice = rawEntryPrice * (1.0 - stopFrac);
      final targetPrice = rawEntryPrice * (1.0 + targetFrac);

      // Check RiskConfig guardrails before entering
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

      // Walk through holding window bar by bar
      double rawExitPrice = fillBar.close;
      String exitReason = 'TIME_EXIT';
      int exitBarIdx = i + 1;
      final maxIdx =
          math.min(sorted.length - 1, i + 1 + maxHoldBars);

      for (int h = i + 1; h <= maxIdx; h++) {
        final hBar = sorted[h];
        exitBarIdx = h;

        // M7.3 CRITICAL RULE: If target and stop are both inside one bar, assume STOP first!
        if (hBar.low <= stopPrice) {
          rawExitPrice = stopPrice;
          exitReason = 'STOP_LOSS (Stop-First Rule)';
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
        'exitTimeMs': sorted[exitBarIdx].timestampMs,
        'strike': signalBar.strike,
        'optionType': signalBar.optionType,
        'qty': lot,
        'entryPrice': double.parse(rawEntryPrice.toStringAsFixed(2)),
        'exitPrice': double.parse(rawExitPrice.toStringAsFixed(2)),
        'grossPnl': double.parse(grossPnl.toStringAsFixed(2)),
        'chargesAndSlippage': double.parse(friction.toStringAsFixed(2)),
        'netPnl': double.parse(netPnl.toStringAsFixed(2)),
        'exitReason': exitReason,
      });

      // Advance past exit bar so positions don't overlap on same contract
      i = exitBarIdx + 1;
    }

    final winRate =
        totalTrades > 0 ? (wins / totalTrades.toDouble()) * 100.0 : 0.0;
    final expectancy =
        totalTrades > 0 ? (netPnlSum / totalTrades.toDouble()) : 0.0;
    final profitFactor = grossLossAbs > 0
        ? (grossProfitWins / grossLossAbs)
        : (grossProfitWins > 0 ? 9.99 : 0.0);

    // Compute Sharpe, Sortino & 95% CI Lower Bound
    double sharpe = 0.0;
    double sortino = 0.0;
    double ciLow = 0.0;
    if (netTradeReturns.length >= 2) {
      final n = netTradeReturns.length;
      final mean = netPnlSum / n;
      double varSum = 0.0;
      double downVarSum = 0.0;
      for (final r in netTradeReturns) {
        varSum += (r - mean) * (r - mean);
        if (r < 0) downVarSum += r * r;
      }
      final std = math.sqrt(varSum / (n - 1));
      final downStd = math.sqrt(downVarSum / n);
      if (std > 1e-6) {
        sharpe = (mean / std) * math.sqrt(n.toDouble());
        ciLow = mean - 1.96 * (std / math.sqrt(n.toDouble()));
      }
      if (downStd > 1e-6) {
        sortino = (mean / downStd) * math.sqrt(n.toDouble());
      }
    }

    return BacktestReport(
      strategyName:
          'Walk-Forward OOS (Sharpe ${sharpe.toStringAsFixed(2)} | Sortino ${sortino.toStringAsFixed(2)} | 95%CI_L ₹${ciLow.toStringAsFixed(0)})',
      indexName: index.label,
      htfConfirmation:
          '${settings.lookbackMinutes}m OI + Next-Bar Open + Stop-First (${dq.summary})',
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
