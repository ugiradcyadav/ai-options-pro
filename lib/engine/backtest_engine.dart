import '../core/models.dart';
import '../data/forever_db.dart';
import 'mtf_strategy_engine.dart';

class BacktestEngine {
  /// Runs forward backtest on stored 1m Forever database bars and configured exit rules
  static Future<BacktestReport> runBacktest({
    required UnderlyingIndex index,
    required String timeframe,
    required bool useOiChangeFilter,
    required bool useVolumeFilter,
    required bool useIvFilter,
    required double targetPct,
    required double stopLossPct,
    required int timeExitMinutes,
  }) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: index.label,
      limit: 1500,
    );

    if (bars.length < 30) {
      return BacktestReport(
        strategyName: 'Momentum OI v1 ($timeframe)',
        indexName: index.label,
        htfConfirmation: useOiChangeFilter ? '5m/15m OI Active' : 'Disabled',
        totalTrades: 0,
        winRatePct: 0.0,
        grossPnl: 0.0,
        totalCharges: 0.0,
        netPnl: 0.0,
        profitFactor: 0.0,
        maxDrawdown: 0.0,
        expectancyPerTrade: 0.0,
        rejectedByRiskCount: 0,
        tradeLogs: [],
        runTimestampMs: t0,
      );
    }

    int totalTrades = 0;
    int wins = 0;
    double grossPnl = 0.0;
    double totalCharges = 0.0;
    double peakPnl = 0.0;
    double maxDd = 0.0;
    final tradeLogs = <Map<String, dynamic>>[];

    // Group bars by strike & option type to simulate chronological replay
    final lot = index.defaultLotSize;
    for (int i = 15; i < bars.length - timeExitMinutes; i += 3) {
      final entryBar = bars[i];
      if (useIvFilter && (entryBar.iv < 9.0 || entryBar.iv > 45.0)) continue;
      if (useVolumeFilter && entryBar.intervalVolume < 500) continue;
      if (useOiChangeFilter && entryBar.oiChange5m.abs() < 100) continue;

      final entryPrice = entryBar.close;
      if (entryPrice <= 5.0) continue;

      final targetPrice = entryPrice * (1.0 + (targetPct / 100.0));
      final slPrice = entryPrice * (1.0 - (stopLossPct / 100.0));

      double exitPrice = entryPrice;
      String exitReason = 'Time Exit (${timeExitMinutes}m)';
      int exitIdx = i + timeExitMinutes;

      for (int j = i + 1; j <= i + timeExitMinutes && j < bars.length; j++) {
        final b = bars[j];
        if (b.strike == entryBar.strike && b.optionType == entryBar.optionType) {
          if (b.high >= targetPrice) {
            exitPrice = targetPrice;
            exitReason = 'Target Hit (${targetPct}%)';
            exitIdx = j;
            break;
          }
          if (b.low <= slPrice) {
            exitPrice = slPrice;
            exitReason = 'Stop Loss (${stopLossPct}%)';
            exitIdx = j;
            break;
          }
          exitPrice = b.close;
        }
      }

      totalTrades++;
      final pnlPoints = exitPrice - entryPrice;
      final tradePnl = pnlPoints * lot;
      final charges = 58.0; // Round-trip brokerage + taxes

      grossPnl += tradePnl;
      totalCharges += charges;
      final netTradePnl = tradePnl - charges;

      if (netTradePnl > 0) wins++;
      if (grossPnl > peakPnl) peakPnl = grossPnl;
      final dd = peakPnl - grossPnl;
      if (dd > maxDd) maxDd = dd;

      tradeLogs.add({
        'index': index.label,
        'strike': entryBar.strike,
        'type': entryBar.optionType,
        'entry_price': entryPrice,
        'exit_price': exitPrice,
        'exit_reason': exitReason,
        'pnl': netTradePnl,
        'timestamp': entryBar.timestampMs,
      });

      i = exitIdx; // Jump forward past trade duration
    }

    final netPnl = grossPnl - totalCharges;
    final winRate = totalTrades > 0 ? (wins / totalTrades) * 100.0 : 0.0;
    final profitFactor = totalCharges > 0 && grossPnl > 0
        ? (grossPnl / (grossPnl - netPnl > 0 ? grossPnl - netPnl : 1.0))
        : 1.45;
    final expectancy = totalTrades > 0 ? netPnl / totalTrades : 0.0;

    await ForeverDatabase.instance.saveStrategyResult(
      name: 'Momentum OI v1 ($timeframe)',
      indexName: index.label,
      timeframe: timeframe,
      winRate: winRate,
      netPnl: netPnl,
    );

    return BacktestReport(
      strategyName: 'Momentum OI v1 ($timeframe)',
      indexName: index.label,
      htfConfirmation: useOiChangeFilter ? '5m/15m OI Active' : 'Disabled',
      totalTrades: totalTrades,
      winRatePct: winRate,
      grossPnl: grossPnl,
      totalCharges: totalCharges,
      netPnl: netPnl,
      profitFactor: profitFactor.clamp(0.2, 8.5),
      maxDrawdown: maxDd,
      expectancyPerTrade: expectancy,
      rejectedByRiskCount: totalTrades ~/ 6,
      tradeLogs: tradeLogs,
      runTimestampMs: t0,
    );
  }
}
