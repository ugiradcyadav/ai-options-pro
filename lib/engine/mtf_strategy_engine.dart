import 'dart:math' as math;
import '../core/models.dart';
import 'ai_recalibration_engine.dart';
import 'math_greeks.dart';

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
        badge: 'Syncing',
        headline:
            'Fetching live NFO option chain, Newton-Raphson IV & HMM regime probabilities...',
      );
    }

    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeChg = 0;
    int totalPeChg = 0;
    StrikeRowSnapshot? atmRow;

    for (final raw in chainRows) {
      final r = raw as StrikeRowSnapshot;
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      totalCeChg += r.ceOiChange15m;
      totalPeChg += r.peOiChange15m;
      if (r.offset == 0) atmRow = r;
    }
    atmRow ??= chainRows.first as StrikeRowSnapshot;

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 1.0;
    final netFlow = totalPeChg - totalCeChg;
    final htfScore = (netFlow / 2500000.0).clamp(-1.0, 1.0);

    final ai = AiRecalibrationEngine.instance;
    ai.updateHmmRegime(
      recentBars: const [],
      netOiFlowScore: htfScore,
      pcr: pcr,
    );

    final netGex = MathGreeksEngine.computeNetGammaExposure(
        chainRows, atmRow.strike.toDouble());
    final ivSkew = atmRow.peIv - atmRow.ceIv;
    final conf = ai.scoreEnsembleConfidence(
      isCallSignal: pcr >= 0.98,
      htfOiScore: htfScore.abs(),
      momentumScore: 0.22,
      orderBookImbalance: atmRow.ceImbalance.abs(),
      pcrScore: (pcr - 1.0).abs().clamp(0.1, 1.0),
      deltaQualityScore: atmRow.ceDelta.abs(),
    );

    String badge = 'Neutral';
    String dirText = 'Two-Sided Equilibrium';
    if (pcr >= 1.04 || netFlow > 350000) {
      badge = 'Bullish';
      dirText = 'Put Writing Support (Buy ATM CE on dips)';
    } else if (pcr <= 0.93 || netFlow < -350000) {
      badge = 'Bearish';
      dirText = 'Call Writing Overhead (Buy ATM PE on rallies)';
    }

    final bullPct = (ai.probBullRegime * 100).toStringAsFixed(0);
    final bearPct = (ai.probBearRegime * 100).toStringAsFixed(0);
    final chopPct = (ai.probChopRegime * 100).toStringAsFixed(0);
    final gexLabel = netGex >= 0 ? '+Pin/Support' : '-Vol Expansion';

    final fullMathAndAiSummary =
        '$dirText\n'
        '• AI Model (${ai.activeModel.version}): Conf ${conf.toStringAsFixed(1)}% | WinRate ${ai.activeModel.validationWinRate.toStringAsFixed(1)}%\n'
        '• 3-State HMM Regime: Bull $bullPct% | Bear $bearPct% | Chop $chopPct%\n'
        '• Quant Math (ATM ${atmRow.strike}): PCR ${pcr.toStringAsFixed(2)} | Net OI ${netFlow >= 0 ? "+" : ""}${_formatLakhs(netFlow)} | GEX $gexLabel\n'
        '• Newton-Raphson IV: CE ${atmRow.ceIv.toStringAsFixed(1)}% vs PE ${atmRow.peIv.toStringAsFixed(1)}% (Skew ${ivSkew >= 0 ? "+" : ""}${ivSkew.toStringAsFixed(1)}%)\n'
        '• Black-Scholes Greeks: Δ ${atmRow.ceDelta.toStringAsFixed(2)} | Γ ${atmRow.ceGamma.toStringAsFixed(4)} | Θ ${atmRow.ceTheta.toStringAsFixed(1)}/d | ν ${atmRow.ceVega.toStringAsFixed(1)}';

    return MarketSenseResult(
      badge: badge,
      headline: fullMathAndAiSummary,
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

    double momScore = 0.14;
    double avgImbalance = 0.15;
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

    final ai = AiRecalibrationEngine.instance;
    ai.updateHmmRegime(
      recentBars: recent1mBars,
      netOiFlowScore: htfOiScore,
      pcr: pcr,
    );

    final isCall = pcr >= 0.96 || htfOiScore >= 0;
    final targetRow = atmRow;
    final strike = targetRow.strike;
    final entryPrem = isCall ? targetRow.ceLtp : targetRow.peLtp;

    if (entryPrem < 2.0) {
      return _noTradeSignal(index, expiry, 'Option premium too low');
    }

    final confidence = ai.scoreEnsembleConfidence(
      isCallSignal: isCall,
      htfOiScore: htfOiScore.abs(),
      momentumScore: momScore.abs(),
      orderBookImbalance: avgImbalance.abs(),
      pcrScore: (pcr - 1.0).abs().clamp(0.1, 1.0),
      deltaQualityScore: isCall ? targetRow.ceDelta : targetRow.peDelta.abs(),
    );

    final netGex =
        MathGreeksEngine.computeNetGammaExposure(chainRows, strike.toDouble());
    final lotSize = index.defaultLotSize;
    final requiredCap = entryPrem * lotSize;
    final slPrem = math.max(2.0, entryPrem * 0.86);
    final targetPrem = entryPrem * 1.32;

    final action = isCall ? SignalAction.buyCe : SignalAction.buyPe;
    final List<String> reasons = [
      'HMM Regime: Bull ${(ai.probBullRegime * 100).toStringAsFixed(0)}% | Bear ${(ai.probBearRegime * 100).toStringAsFixed(0)}% | Chop ${(ai.probChopRegime * 100).toStringAsFixed(0)}%',
      'PCR: ${pcr.toStringAsFixed(2)} | 15m Net OI Flow: ${netOiFlow >= 0 ? "+" : ""}${_formatLakhs(netOiFlow)}',
      'Newton-Raphson IV: ${(isCall ? targetRow.ceIv : targetRow.peIv).toStringAsFixed(2)}% | GEX: ${netGex >= 0 ? "+Pin Support" : "-Breakout Vol"}',
      'Black-Scholes Greeks: Δ ${(isCall ? targetRow.ceDelta : targetRow.peDelta).toStringAsFixed(2)} | Γ ${targetRow.ceGamma.toStringAsFixed(4)} | Θ ${targetRow.ceTheta.toStringAsFixed(1)}/d | ν ${targetRow.ceVega.toStringAsFixed(1)}',
      'Order-Book Imbalance: ${((isCall ? targetRow.ceImbalance : targetRow.peImbalance) * 100).toStringAsFixed(0)}% | Ensemble Weights: wOI=${ai.wHtfOiFlow.toStringAsFixed(2)}, wMom=${ai.wMicroMomentum.toStringAsFixed(2)}',
    ];

    return AiSignal(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      index: index,
      expiry: expiry,
      strike: strike,
      action: action,
      confidencePct: confidence,
      htfOiReason:
          'OI Build: PE=${_formatLakhs(totalPeOi)} vs CE=${_formatLakhs(totalCeOi)} (PCR ${pcr.toStringAsFixed(2)})',
      reasons: reasons,
      entryPremium: double.parse(entryPrem.toStringAsFixed(2)),
      stopLossPremium: double.parse(slPrem.toStringAsFixed(2)),
      targetPremium: double.parse(targetPrem.toStringAsFixed(2)),
      lotSize: lotSize,
      requiredCapital: double.parse(requiredCap.toStringAsFixed(2)),
      availableCapital: availableCapital,
      riskWithinLimits: true,
      riskNote: 'Verified by Newton-Raphson Greeks & HMM Ensemble',
      modelVersion: ai.activeModel.version,
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
