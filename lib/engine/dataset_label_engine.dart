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
      'LookAheadViolationError: Feature at $violatingFeatureTimestampMs is after entry at $entryTimestampMs';
}

class LabeledSampleRecord {
  final int entryTimestampMs;
  final String indexName;
  final int strike;
  final String optionType;
  final List features;
  final int tripleBarrierLabel;
  final double netPnlInr;
  final double netReturnPct;
  final String exitReason;
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

  static void enforceNoLookAhead(int entryTimestampMs, List featureBars) {
    for (final raw in featureBars) {
      final b = raw as OneMinEnrichedBar;
      if (b.timestampMs > entryTimestampMs) {
        throw LookAheadViolationError(
          entryTimestampMs: entryTimestampMs,
          violatingFeatureTimestampMs: b.timestampMs,
        );
      }
    }
  }

  static List extractCausalFeaturesAt({
    required List historyUpToT,
    required int entryTimestampMs,
    required StrategySettings settings,
  }) {
    enforceNoLookAhead(entryTimestampMs, historyUpToT);
    if (historyUpToT.isEmpty) {
      return [0.0, 0.0, 0.0, 15.0, 0.50];
    }

    final cur = historyUpToT.last as OneMinEnrichedBar;
    final prevIdx = historyUpToT.length >= 4 ? historyUpToT.length - 4 : 0;
    final prev = historyUpToT[prevIdx] as OneMinEnrichedBar;

    final oiRaw = settings.lookbackMinutes == 5
        ? cur.oiChange5m
        : (settings.lookbackMinutes == 60 ? cur.oiChange60m : cur.oiChange15m);
    final f0 = (oiRaw / 500000.0).clamp(-2.0, 2.0);
    final f1 = prev.close > 0
        ? (((cur.close - prev.close) / prev.close) * 15.0).clamp(-2.0, 2.0)
        : 0.0;
    final f2 = cur.orderBookImbalance.clamp(-1.0, 1.0);
    return [f0, f1, f2, cur.iv, cur.delta.abs()];
  }
}
