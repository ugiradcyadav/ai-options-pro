import '../core/models.dart';
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

class DatasetLabelEngine {
  static const String featureSchemaVersion = 'FEATURE_SCHEMA_V3_SIGNED';

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

  /// WP-2 & WP-8: Returns signed causal feature vector, or null if required real inputs are missing.
  static List<double>? extractCausalFeaturesAt({
    required List historyUpToT,
    required int entryTimestampMs,
    required StrategySettings settings,
  }) {
    enforceNoLookAhead(entryTimestampMs, historyUpToT);
    if (historyUpToT.length < 4) return null;

    final cur = historyUpToT.last as OneMinEnrichedBar;
    final prev = historyUpToT[historyUpToT.length - 4] as OneMinEnrichedBar;
    if (cur.close <= 0 || prev.close <= 0) return null;

    final int? oiRaw = settings.lookbackMinutes == 5
        ? cur.oiChange5m
        : (settings.lookbackMinutes == 60 ? cur.oiChange60m : cur.oiChange15m);
    if (oiRaw == null || cur.iv == null || cur.orderBookImbalance == null) {
      return null;
    }

    // Signed directional features (normalized by current contract OI base, never arbitrary constants)
    final oiBase = cur.absoluteOi > 0 ? cur.absoluteOi.toDouble() : 1.0;
    final f0OiRatio = (oiRaw / oiBase).clamp(-1.0, 1.0);
    final f1Mom = ((cur.close - prev.close) / prev.close).clamp(-1.0, 1.0);
    final f2Imb = cur.orderBookImbalance!.clamp(-1.0, 1.0);
    final f3Iv = cur.iv!;
    final f4Delta = cur.delta; // Signed delta (+ for CE, - for PE)

    return [f0OiRatio, f1Mom, f2Imb, f3Iv, f4Delta];
  }
}
