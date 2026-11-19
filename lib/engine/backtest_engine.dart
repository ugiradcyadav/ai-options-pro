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
    );
  }

  /// WP-8: Calls MtfStrategyEngine.evaluateEntry() with IST day-reset loss, real-minute hold, and gap-aware stop fills
  static BacktestReport runRealisticBacktest({
    required UnderlyingIndex index,
    required List bars,
    required RiskConfig riskConfig,
    required double startingCapital,
    required int lotSize,
    StrategySettings? settingsOverride,
    bool outOfSampleOnly = true,
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
    final int oosStartIdx = outOfSampleOnly && contractBars.length >= 25
        ? ((contractBars.length * 0.40).floor() + embargoBars)
        : 4;

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

    int i = math.max(4, oosStartIdx);
    while (i < contractBars.length - 2) {
      final bar = contractBars[i];
      final barDay = _istDayKey(bar.timestampMs);
      if (barDay != currentIstDay) {
        currentIstDay = barDay;
        todayNetRealizedPnlIst = 0.0; // WP-8: Reset daily P&L per IST day
      }

      // Build causal spot window up to bar.timestampMs
      final causalSpots = spotBars
          .where((s) => s.timestampMs <= bar.timestampMs)
          .toList();

      // Build single-strike snapshot from recorded contract bar for unified evaluateEntry()
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

      // Fill at NEXT bar open (same IST day only — no overnight holds)
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

      for (int h = i + 1; h < contractBars.length; h++) {
        final hBar = contractBars[h];
        // WP-8: No overnight holds — exit on last bar of same IST day
        if (_istDayKey(hBar.timestampMs) != barDay) {
          break;
        }
        exitBarIdx = h;

        // WP-8: Gap-aware stop fill (if bar opens below stop, fill at bar.open, not stopPrice)
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
        // WP-8: Max hold measured in real elapsed milliseconds, not bar count
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
      final friction = realizedCosts.totalFrictionInr;
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
          'Unified Walk-Forward ${outOfSampleOnly ? "OOS" : "Full"} (${dq.summary})',
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
