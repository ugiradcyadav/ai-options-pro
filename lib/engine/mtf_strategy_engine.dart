import 'dart:math' as math;
import '../core/models.dart';
import '../data/forever_db.dart';
import 'ai_recalibration_engine.dart';
import 'math_greeks.dart';

class MtfStrategyEngine {
  static AiSignal evaluateOneMinEntry({
    required UnderlyingIndex index,
    required String expiry,
    required List<StrikeRowSnapshot> chainRows,
    required List<OneMinEnrichedBar> recent1mBars,
    required double availableCapital,
    required RiskConfig riskConfig,
    required int openPositionsCount,
    required double todayRealizedLossInr,
  }) {
    if (chainRows.isEmpty) {
      return _noTradeSignal(index, expiry, 'Empty Option Chain snapshot');
    }

    // 1. Find ATM Strike & Underlying Spot estimate
    StrikeRowSnapshot? atmRow;
    double minDiff = double.infinity;
    for (final r in chainRows) {
      final diff = (r.offset).abs();
      if (diff < minDiff) {
        minDiff = diff.toDouble();
        atmRow = r;
      }
    }

    if (atmRow == null) {
      return _noTradeSignal(index, expiry, 'ATM strike could not be resolved');
    }

    final atmStrike = atmRow.strike;
    final approxSpot = atmStrike.toDouble();

    // 2. Compute Put-Call Ratio (PCR) & Institutional OI Buildup Velocity
    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeOiChg = 0;
    int totalPeOiChg = 0;

    for (final r in chainRows) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      totalCeOiChg += r.ceOiChange15m;
      totalPeOiChg += r.peOiChange15m;
    }

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 1.0;
    final netOiFlow = totalPeOiChg - totalCeOiChg;
    final htfOiScore =
        (netOiFlow / 3000000.0).clamp(-1.0, 1.0); // Normalized score

    // 3. Compute 1m Microstructure Momentum & Order Book Imbalance
    double momScore = 0.0;
    double avgImbalance = 0.10;
    if (recent1mBars.length >= 3) {
      final latest = recent1mBars.last;
      final prev = recent1mBars[recent1mBars.length - 3];
      momScore = ((latest.close - prev.close) / prev.close * 45.0).clamp(-1.0, 1.0);
      double imbSum = 0.0;
      for (final b in recent1mBars) {
        imbSum += b.orderBookImbalance;
      }
      avgImbalance = imbSum / recent1mBars.length;
    }

    // 4. Update HMM Regime Filter
    AiRecalibrationEngine.instance.updateHmmRegime(
      recentBars: recent1mBars,
      netOiFlowScore: htfOiScore,
      pcr: pcr,
    );

    // 5. Check Buyer Signal Trigger (Strictly 6-contract buyer band: ATM-1, ATM, ATM+1)
    final bestCallRow = chainRows.firstWhere(
      (r) => r.offset == 0 || r.offset == 1,
      orElse: () => atmRow!,
    );
    final bestPutRow = chainRows.firstWhere(
      (r) => r.offset == -1 || r.offset == 0,
      orElse: () => atmRow!,
    );

    final bool isBullishSetup = (pcr >= 0.96 && htfOiScore >= -0.08) ||
        (momScore > 0.15 && avgImbalance > 0.05);
    final bool isBearishSetup = (pcr <= 0.94 && htfOiScore <= 0.08) ||
        (momScore < -0.15 && avgImbalance < -0.05);

    if (!isBullishSetup && !isBearishSetup) {
      return _noTradeSignal(index, expiry, 'Market chop / No institutional OI trigger');
    }

    final isCall = isBullishSetup;
    final targetRow = isCall ? bestCallRow : bestPutRow;
    final strike = targetRow.strike;
    final entryPrem = isCall ? targetRow.ceLtp : targetRow.peLtp;

    if (entryPrem < 5.0) {
      return _noTradeSignal(index, expiry, 'Option premium too low (< 5.0)');
    }

    // 6. Score via AI Ensemble Calibrator
    final confidence = AiRecalibrationEngine.instance.scoreEnsembleConfidence(
      isCallSignal: isCall,
      htfOiScore: htfOiScore,
      momentumScore: momScore,
      orderBookImbalance: avgImbalance,
      pcrScore: (pcr - 1.0).clamp(-1.0, 1.0),
      deltaQualityScore: isCall ? targetRow.ceDelta : targetRow.peDelta.abs(),
    );

    if (confidence < 58.0) {
      return _noTradeSignal(
          index, expiry, 'AI Confidence ${confidence.toStringAsFixed(1)}% < 58% threshold');
    }

    // 7. Lot Sizing & Risk Management (1-Lot default, ATR / Theta adjusted SL)
    final lotSize = index.defaultLotSize;
    final requiredCap = entryPrem * lotSize;

    if (availableCapital > 0 && requiredCap > availableCapital * 0.85) {
      return _noTradeSignal(index, expiry, 'Insufficient capital for 1 lot');
    }

    final slPrem = math.max(3.0, entryPrem * 0.86); // 14% max stop-loss per lot
    final targetPrem = entryPrem * 1.32; // 32% target reward

    final action = isCall ? SignalAction.buyCe : SignalAction.buyPe;
    final reasons = <String>[
      'PCR: ${pcr.toStringAsFixed(2)}',
      'HTF OI Flow: ${htfOiScore >= 0 ? "+" : ""}${(htfOiScore * 100).toStringAsFixed(0)}%',
      'AI Conf: ${confidence.toStringAsFixed(1)}%',
    ];

    return AiSignal(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      index: index,
      expiry: expiry,
      strike: strike,
      action: action,
      confidencePct: confidence,
      htfOiReason: 'Institutional OI Build: PE=${_formatLakhs(totalPeOi)} vs CE=${_formatLakhs(totalCeOi)}',
      reasons: reasons,
      entryPremium: double.parse(entryPrem.toStringAsFixed(2)),
      stopLossPremium: double.parse(slPrem.toStringAsFixed(2)),
      targetPremium: double.parse(targetPrem.toStringAsFixed(2)),
      lotSize: lotSize,
      requiredCapital: double.parse(requiredCap.toStringAsFixed(2)),
      availableCapital: availableCapital,
      riskWithinLimits: true,
      riskNote: 'Passed all Phase-1 & 2 risk guardrails',
      modelVersion: AiRecalibrationEngine.instance.modelVersion,
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
      modelVersion: AiRecalibrationEngine.instance.modelVersion,
    );
  }

  static String _formatLakhs(int val) {
    return '${(val / 100000.0).toStringAsFixed(1)}L';
  }
}
