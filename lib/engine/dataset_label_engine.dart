import '../core/models.dart';
import 'risk_engine.dart';
import 'strategy_settings.dart';

class LookAheadViolationError implements Exception {
  final int entryTimestampMs;
  final int violatingFeatureTimestampMs;

  const LookAheadViolationError({
    required this.entryTimestampMs,
    required this.violatingFeatureTimestampMs,
  });

  @override
  String toString() =>
      'LookAheadViolationError: Feature at $violatingFeatureTimestampMs is strictly after candidate entry at $entryTimestampMs';
}

class LabeledSampleRecord {
  final int entryTimestampMs;
  final String indexName;
  final int strike;
  final String optionType;
  final List<double> features;
  final int tripleBarrierLabel; // 1 = target hit net of costs, 0 = stop or negative time exit
  final double netPnlInr;
  final double netReturnPct;
  final String exitReason; // 'TARGET', 'STOP_FIRST', 'TIME_EXIT'
  final String schemaVersion;

  const LabeledSampleRecord({
    required this.entryTimestampMs,
    required this.indexName,
    required this.strike,
    required this.optionType,
    required this.features,
    required this.tripleBarrierLabel,
    required this.netPnlInr,
    required this.netReturnPct,
    required this.exitReason,
    this.schemaVersion = DatasetLabelEngine.featureSchemaVersion,
  });
}

class DatasetLabelEngine {
  static const String featureSchemaVersion = 'FEATURE_SCHEMA_V2_1';

  static const Map<String, String> dataDictionary = {
    'f0_oi_flow_norm': 'Normalized lookback OI change at time <= t',
    'f1_mom_3m': '3-minute option premium return at time <= t',
    'f2_ob_imbalance': 'Top-5 bid-ask order book imbalance at time <= t',
    'f3_iv_pct': 'Black-76 implied volatility % at time <= t',
    'f4_delta_abs': 'Absolute Black-76 option delta at time <= t',
    'label_triple_barrier':
        '1 if net profit hits target before stop/time-exit (after statutory costs & slippage), else 0',
  };

  /// A2 Acceptance: Rejects any feature window containing bars timestamped after entryTimestampMs
  static void enforceNoLookAhead(
    int entryTimestampMs,
    List<OneMinEnrichedBar> featureBars,
  ) {
    for (final b in featureBars) {
      if (b.timestampMs > entryTimestampMs) {
        throw LookAheadViolationError(
          entryTimestampMs: entryTimestampMs,
          violatingFeatureTimestampMs: b.timestampMs,
        );
      }
    }
  }

  /// Extracts causal feature vector using strictly bars at or before candidate index t
  static List<double> extractCausalFeaturesAt({
    required List<OneMinEnrichedBar> historyUpToT,
    required int entryTimestampMs,
    required StrategySettings settings,
  }) {
    enforceNoLookAhead(entryTimestampMs, historyUpToT);
    if (historyUpToT.isEmpty) {
      return [0.0, 0.0, 0.0, 15.0, 0.50];
    }

    final cur = historyUpToT.last;
    final prevIdx = historyUpToT.length >= 4 ? historyUpToT.length - 4 : 0;
    final prev = historyUpToT[prevIdx];

    final oiRaw = settings.lookbackMinutes == 5
        ? cur.oiChange5m
        : (settings.lookbackMinutes == 60 ? cur.oiChange60m : cur.oiChange15m);
    final f0 = (oiRaw / 500000.0).clamp(-2.0, 2.0);
    final f1 = prev.close > 0
        ? (((cur.close - prev.close) / prev.close) * 15.0).clamp(-2.0, 2.0)
        : 0.0;
    final f2 = cur.orderBookImbalance.clamp(-1.0, 1.0);
    final f3 = cur.iv;
    final f4 = cur.delta.abs();

    return [f0, f1, f2, f3, f4];
  }

  /// A2 & M7.3: Builds triple-barrier labeled dataset across all indices net of Indian statutory costs & slippage
  static List<LabeledSampleRecord> buildTripleBarrierDataset({
    required List<OneMinEnrichedBar> chronologicalBars,
    required UnderlyingIndex index,
    required StrategySettings settings,
  }) {
    final samples = <LabeledSampleRecord>[];
    if (chronologicalBars.length < 6) return samples;

    final targetFrac = settings.targetPctForIndex(index) / 100.0;
    final stopFrac = settings.stopLossPctForIndex(index) / 100.0;
    final maxHoldBars = settings.timeExitMinutes.clamp(1, 60);
    final lotSize = index.defaultLotSize;

    for (int t = 3; t < chronologicalBars.length - 2; t++) {
      final signalBar = chronologicalBars[t];
      final fillBar = chronologicalBars[t + 1]; // M7.3: Fill at NEXT bar open
      if (fillBar.open <= 0) continue;

      final historySlice = chronologicalBars.sublist(0, t + 1);
      final feats = extractCausalFeaturesAt(
        historyUpToT: historySlice,
        entryTimestampMs: signalBar.timestampMs,
        settings: settings,
      );

      final rawEntry = fillBar.open;
      final targetPrice = rawEntry * (1.0 + targetFrac);
      final stopPrice = rawEntry * (1.0 - stopFrac);

      double rawExit = fillBar.close;
      String exitReason = 'TIME_EXIT';
      final lastBarIdx = (t + 1 + maxHoldBars < chronologicalBars.length)
          ? (t + 1 + maxHoldBars)
          : (chronologicalBars.length - 1);

      for (int h = t + 1; h <= lastBarIdx; h++) {
        final bar = chronologicalBars[h];
        // M7.3: If target and stop are both inside one bar, assume STOP first!
        if (bar.low <= stopPrice) {
          rawExit = stopPrice;
          exitReason = 'STOP_FIRST';
          break;
        }
        if (bar.high >= targetPrice) {
          rawExit = targetPrice;
          exitReason = 'TARGET';
          break;
        }
        rawExit = bar.close;
      }

      final costBreakdown = RiskEngine.computeRoundTripCostsAndSlippage(
        entryPremium: rawEntry,
        exitPremium: rawExit,
        quantity: lotSize,
        spreadPct: fillBar.spreadPct > 0 ? fillBar.spreadPct : 0.25,
        barVolume: fillBar.intervalVolume > 0 ? fillBar.intervalVolume : 1200,
      );

      final grossPnl = (rawExit - rawEntry) * lotSize;
      final netPnl = grossPnl - costBreakdown.totalFrictionInr;
      final netRetPct = (rawEntry * lotSize) > 0
          ? (netPnl / (rawEntry * lotSize)) * 100.0
          : 0.0;

      samples.add(
        LabeledSampleRecord(
          entryTimestampMs: signalBar.timestampMs,
          indexName: index.label,
          strike: signalBar.strike,
          optionType: signalBar.optionType,
          features: feats,
          tripleBarrierLabel: netPnl > 0 ? 1 : 0,
          netPnlInr: double.parse(netPnl.toStringAsFixed(2)),
          netReturnPct: double.parse(netRetPct.toStringAsFixed(3)),
          exitReason: exitReason,
        ),
      );
    }

    return samples;
  }
}
