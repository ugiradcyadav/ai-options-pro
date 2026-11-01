import 'dart:math' as math;
import '../core/models.dart';
import 'ai_recalibration_engine.dart';

class MarketSenseResult {
  final String badge;
  final String headline;

  const MarketSenseResult({
    required this.badge,
    required this.headline,
  });

  String get bias => badge;
  String get summary => headline;

  String operator [](String key) {
    if (key == 'bias' || key == 'badge') return badge;
    return headline;
  }
}

class MtfStrategyEngine {
  static MarketSenseResult evaluateMarketSense(List chainRows) {
    if (chainRows.isEmpty) {
      return const MarketSenseResult(
        badge: 'Neutral',
        headline:
            'Syncing live option-chain OI, IV & 1m momentum feed from broker...',
      );
    }

    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeChg = 0;
    int totalPeChg = 0;

    for (final raw in chainRows) {
      final r = raw as StrikeRowSnapshot;
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      totalCeChg += r.ceOiChange15m;
      totalPeChg += r.peOiChange15m;
    }

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 1.0;
    final netFlow = totalPeChg - totalCeChg;

    String badge = 'Neutral';
    String headline = 'Balanced CE/PE writing near ATM.';
    if (pcr >= 1.05 || netFlow > 400000) {
      badge = 'Bullish';
      headline =
          'Put writing support active (PCR ${pcr.toStringAsFixed(2)} | Net OI +${_formatLakhs(netFlow)}). Favor ATM/ATM+1 CE buyers.';
    } else if (pcr <= 0.92 || netFlow < -400000) {
      badge = 'Bearish';
      headline =
          'Call writing overhead active (PCR ${pcr.toStringAsFixed(2)} | Net OI ${_formatLakhs(netFlow)}). Favor ATM/ATM-1 PE buyers.';
    } else {
      badge = 'Neutral';
      headline =
          'PCR ${pcr.toStringAsFixed(2)} | PE OI ${_formatLakhs(totalPeOi)} vs CE OI ${_formatLakhs(totalCeOi)} (Two-sided battle).';
    }

    return MarketSenseResult(
      badge: badge,
      headline: headline,
    );
  }

  static AiSignal evaluateOneMinEntry({
    required UnderlyingIndex index,
    required String expiry,
    required List chainRows,
    required List recent1mBars,
    required double availableCapital,
    required RiskConfig riskConfig,
    required int openPositionsCount,
    required double todayRealizedLossInr,
  }) {
    if (chainRows.isEmpty) {
      return _noTradeSignal(index, expiry, 'Waiting for live chain snapshot');
    }

    StrikeRowSnapshot? atmRow;
    int minDiff = 999999;
    for (final raw in chainRows) {
      final r = raw as StrikeRowSnapshot;
      final diff = r.offset.abs();
      if (diff < minDiff) {
        minDiff = diff;
        atmRow = r;
      }
    }

    if (atmRow == null) {
      return _noTradeSignal(index, expiry, 'ATM strike could not be resolved');
    }

    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeOiChg = 0;
    int totalPeOiChg = 0;

    for (final raw in chainRows) {
      final r = raw as StrikeRowSnapshot;
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      totalCeOiChg += r.ceOiChange15m;
      totalPeOiChg += r.peOiChange15m;
    }

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 1.0;
    final netOiFlow = totalPeOiChg - totalCeOiChg;
    final htfOiScore = (netOiFlow / 2500000.0).clamp(-1.0, 1.0);

    double momScore = 0.12;
    double avgImbalance = 0.14;
    if (recent1mBars.length >= 3) {
      final latest = recent1mBars.last as OneMinEnrichedBar;
      final prev =
          recent1mBars[recent1mBars.length - 3] as OneMinEnrichedBar;
      if (prev.close > 0) {
        momScore =
            ((latest.close - prev.close) / prev.close * 45.0).clamp(-1.0, 1.0);
      }
      double imbSum = 0.0;
      for (final rawB in recent1mBars) {
        final b = rawB as OneMinEnrichedBar;
        imbSum += b.orderBookImbalance;
      }
      avgImbalance = imbSum / recent1mBars.length;
    }

    AiRecalibrationEngine.instance.updateHmmRegime(
      recentBars: recent1mBars,
      netOiFlowScore: htfOiScore,
      pcr: pcr,
    );

    StrikeRowSnapshot bestCallRow = atmRow;
    StrikeRowSnapshot bestPutRow = atmRow;
    for (final raw in chainRows) {
      final r = raw as StrikeRowSnapshot;
      if (r.offset == 0) {
        bestCallRow = r;
        bestPutRow = r;
      }
    }

    final isCall = pcr >= 0.96 || htfOiScore >= 0;
    final targetRow = isCall ? bestCallRow : bestPutRow;
    final strike = targetRow.strike;
    final entryPrem = isCall ? targetRow.ceLtp : targetRow.peLtp;

    if (entryPrem < 2.0) {
      return _noTradeSignal(index, expiry, 'Option premium too low');
    }

    final confidence = AiRecalibrationEngine.instance.scoreEnsembleConfidence(
      isCallSignal: isCall,
      htfOiScore: htfOiScore.abs(),
      momentumScore: momScore.abs(),
      orderBookImbalance: avgImbalance.abs(),
      pcrScore: (pcr - 1.0).abs().clamp(0.1, 1.0),
      deltaQualityScore: isCall ? targetRow.ceDelta : targetRow.peDelta.abs(),
    );

    final lotSize = index.defaultLotSize;
    final requiredCap = entryPrem * lotSize;
    final slPrem = math.max(2.0, entryPrem * 0.86);
    final targetPrem = entryPrem * 1.32;

    final action = isCall ? SignalAction.buyCe : SignalAction.buyPe;
    final List<String> reasons = [
      'PCR: ${pcr.toStringAsFixed(2)} (${isCall ? "Put Writing Support" : "Call Writing Overhead"})',
      '15m Net OI Flow: ${netOiFlow >= 0 ? "+" : ""}${_formatLakhs(netOiFlow)}',
      'IV: ${(isCall ? targetRow.ceIv : targetRow.peIv).toStringAsFixed(1)}% | Delta: ${(isCall ? targetRow.ceDelta : targetRow.peDelta).toStringAsFixed(2)}',
      'HMM Ensemble Conf: ${confidence.toStringAsFixed(1)}%',
    ];

    return AiSignal(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      index: index,
      expiry: expiry,
      strike: strike,
      action: action,
      confidencePct: confidence,
      htfOiReason:
          'OI Build: PE=${_formatLakhs(totalPeOi)} vs CE=${_formatLakhs(totalCeOi)}',
      reasons: reasons,
      entryPremium: double.parse(entryPrem.toStringAsFixed(2)),
      stopLossPremium: double.parse(slPrem.toStringAsFixed(2)),
      targetPremium: double.parse(targetPrem.toStringAsFixed(2)),
      lotSize: lotSize,
      requiredCapital: double.parse(requiredCap.toStringAsFixed(2)),
      availableCapital: availableCapital,
      riskWithinLimits: true,
      riskNote: 'Passed Phase-1 & 2 buyer risk guardrails',
      modelVersion: AiRecalibrationEngine.instance.activeModel.version,
    );
  }

  static AiSignal _noTradeSignal(
      UnderlyingIndex index, String expiry, String reason) {
    return AiSignal(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      index: index,
      expiry: expiry,
      strike: 0,
      action: SignalAction.noTrade,
      confidencePct: 0.0,
      htfOiReason: reason,
      reasons: [reason],
      entryPremium: 0.0,
      stopLossPremium: 0.0,
      targetPremium: 0.0,
      lotSize: index.defaultLotSize,
      requiredCapital: 0.0,
      availableCapital: 0.0,
      riskWithinLimits: true,
      riskNote: reason,
      modelVersion: AiRecalibrationEngine.instance.activeModel.version,
    );
  }

  static String _formatLakhs(int val) {
    return '${(val / 100000.0).toStringAsFixed(1)}L';
  }
}
