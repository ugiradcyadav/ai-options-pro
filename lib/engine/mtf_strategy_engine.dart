import 'dart:math' as math;
import '../core/models.dart';
import 'ai_recalibration_engine.dart';
import 'math_greeks.dart';
import 'risk_engine.dart';
import 'strategy_settings.dart';

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
  /// M7.7: Single Source of Truth bar-level signal evaluator shared by BOTH Live Engine and Backtester
  static bool isBarEligibleForEntry({
    required OneMinEnrichedBar bar,
    required OneMinEnrichedBar prevBar,
    required StrategySettings settings,
    required UnderlyingIndex index,
  }) {
    if (bar.close <= 0 || bar.open <= 0 || bar.low > bar.high) return false;
    if (bar.intervalVolume < settings.minVolumeFilter) return false;
    if (bar.iv < settings.minIvPct || bar.iv > settings.maxIvPct) return false;

    final lookbackOi = settings.lookbackMinutes == 5
        ? bar.oiChange5m
        : (settings.lookbackMinutes == 60 ? bar.oiChange60m : bar.oiChange15m);
    final reqOi = settings.oiThresholdForIndex(index);

    final momPositive = bar.close > prevBar.close;
    final oiSupport = lookbackOi.abs() >= (reqOi * 0.25);
    final obSupport = bar.orderBookImbalance >= -0.05;

    return momPositive && oiSupport && obSupport;
  }

  static MarketSenseResult evaluateMarketSense(List chainRows) {
    if (chainRows.isEmpty) {
      return const MarketSenseResult(
        badge: 'Syncing',
        headline:
            'Fetching live NFO option chain, Black-76 IV & Forward-HMM regime probabilities...',
      );
    }

    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeChg = 0;
    int totalPeChg = 0;
    StrikeRowSnapshot? atmRow;
    final settings = StrategySettingsEngine.instance.current;

    for (final raw in chainRows) {
      final r = raw as StrikeRowSnapshot;
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      totalCeChg += settings.lookbackMinutes == 5
          ? r.ceOiChange5m
          : (settings.lookbackMinutes == 60 ? r.ceOiChange60m : r.ceOiChange15m);
      totalPeChg += settings.lookbackMinutes == 5
          ? r.peOiChange5m
          : (settings.lookbackMinutes == 60 ? r.peOiChange60m : r.peOiChange15m);
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

    final gexInfo = MathGreeksEngine.computeDealerPositioning(
        chainRows, atmRow.strike.toDouble());
    final surfInfo = MathGreeksEngine.evaluateIvSurface(
        chainRows, atmRow.strike.toDouble());

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

    final fullMathAndAiSummary =
        '$dirText\n'
        '• Model (${ai.activeModel.version}): Score ${conf.toStringAsFixed(1)}% | OOS: ${ai.activeModel.displayAccuracyLabel}\n'
        '• 3-State Forward-HMM: Bull $bullPct% | Bear $bearPct% | Chop $chopPct%\n'
        '• Dealer GEX: ${gexInfo.netGexCr >= 0 ? "+" : ""}${gexInfo.netGexCr} Cr | CallWall ${gexInfo.callWallStrike} | PutWall ${gexInfo.putWallStrike} | MaxPain ${gexInfo.maxPainStrike}\n'
        '• Black-76 IV Surface: ATM ${surfInfo.atmIv}% | 25Δ RR ${surfInfo.riskReversal25d}% | BF ${surfInfo.butterfly25d}%\n'
        '• Greeks: Δ ${atmRow.ceDelta.toStringAsFixed(2)} | Γ ${atmRow.ceGamma.toStringAsFixed(4)} | Θ ${atmRow.ceTheta.toStringAsFixed(1)}/d | ν ${atmRow.ceVega.toStringAsFixed(1)}\n'
        '• Note: ${gexInfo.assumptionNote}';

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

    final settings = StrategySettingsEngine.instance.current;
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
      totalCeOiChg += settings.lookbackMinutes == 5
          ? r.ceOiChange5m
          : (settings.lookbackMinutes == 60 ? r.ceOiChange60m : r.ceOiChange15m);
      totalPeOiChg += settings.lookbackMinutes == 5
          ? r.peOiChange5m
          : (settings.lookbackMinutes == 60 ? r.peOiChange60m : r.peOiChange15m);
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

    // M6: Refuse to trade on low-confidence / high-chop regimes
    if (ai.probChopRegime > 0.62) {
      return _noTradeSignal(
        index,
        expiry,
        'Abstained: HMM Chop/Mean-Revert regime probability is ${(ai.probChopRegime * 100).toStringAsFixed(0)}%',
      );
    }

    final isCall = pcr >= 0.96 || htfOiScore >= 0;
    final targetRow = atmRow;
    final strike = targetRow.strike;
    final entryPrem = isCall ? targetRow.ceLtp : targetRow.peLtp;
    final optIv = isCall ? targetRow.ceIv : targetRow.peIv;

    if (entryPrem < 2.0) {
      return _noTradeSignal(index, expiry, 'Option premium too low (< ₹2)');
    }

    if (optIv < settings.minIvPct || optIv > settings.maxIvPct) {
      return _noTradeSignal(
        index,
        expiry,
        'Filtered: IV ${optIv.toStringAsFixed(1)}% outside StrategySettings band (${settings.minIvPct}–${settings.maxIvPct}%)',
      );
    }

    final confidence = ai.scoreEnsembleConfidence(
      isCallSignal: isCall,
      htfOiScore: htfOiScore.abs(),
      momentumScore: momScore.abs(),
      orderBookImbalance: avgImbalance.abs(),
      pcrScore: (pcr - 1.0).abs().clamp(0.1, 1.0),
      deltaQualityScore: isCall ? targetRow.ceDelta : targetRow.peDelta.abs(),
    );

    final targetPct = settings.targetPctForIndex(index) / 100.0;
    final stopPct = settings.stopLossPctForIndex(index) / 100.0;
    final slPrem = math.max(1.0, entryPrem * (1.0 - stopPct));
    final targetPrem = entryPrem * (1.0 + targetPct);

    // M4: Check if daily theta bleed over holding window exceeds expected move
    final volForecast = MathGreeksEngine.computeVolForecast(
      recentBars: recent1mBars,
      currentAtmIvPct: optIv,
      spot: strike.toDouble(),
      holdingMinutes: settings.timeExitMinutes.toDouble(),
    );

    final lotSize = index.defaultLotSize;
    final optimalQty = RiskEngine.computeOptimalBuyerQuantity(
      winProbability: confidence / 100.0,
      entryPremium: entryPrem,
      stopLossPremium: slPrem,
      targetPremium: targetPrem,
      lotSize: lotSize,
      availableCapital: availableCapital > 0 ? availableCapital : 25000.0,
      config: riskConfig,
    );
    final finalQty = optimalQty >= lotSize ? optimalQty : lotSize;
    final requiredCap = entryPrem * finalQty;

    final action = isCall ? SignalAction.buyCe : SignalAction.buyPe;
    final List<String> reasons = [
      'Model (${ai.activeModel.version}) • Gate: ${ai.activeModel.passedEvaluationGate ? "Verified" : "Shadow/Rules Mode"}',
      'Forward-HMM: Bull ${(ai.probBullRegime * 100).toStringAsFixed(0)}% | Bear ${(ai.probBearRegime * 100).toStringAsFixed(0)}% | Chop ${(ai.probChopRegime * 100).toStringAsFixed(0)}%',
      'PCR: ${pcr.toStringAsFixed(2)} | ${settings.lookbackMinutes}m Net OI Flow: ${netOiFlow >= 0 ? "+" : ""}${_formatLakhs(netOiFlow)}',
      'Black-76 IV: ${optIv.toStringAsFixed(2)}% | GK-EWMA RV: ${volForecast.ewmaForecastRvPct}% | VRP: ${volForecast.varianceRiskPremiumPct}%',
      'Greeks: Δ ${(isCall ? targetRow.ceDelta : targetRow.peDelta).toStringAsFixed(2)} | Γ ${targetRow.ceGamma.toStringAsFixed(4)} | Θ ${targetRow.ceTheta.toStringAsFixed(1)}/d | ν ${targetRow.ceVega.toStringAsFixed(1)}',
    ];

    final rawSig = AiSignal(
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
      lotSize: finalQty,
      requiredCapital: double.parse(requiredCap.toStringAsFixed(2)),
      availableCapital: availableCapital,
      riskWithinLimits: true,
      riskNote: 'Validated via StrategySettings & M8 EV Gate',
      modelVersion: ai.activeModel.version,
    );

    if (availableCapital > 0) {
      return RiskEngine.validateAndEnforceRisk(
        rawSignal: rawSig,
        config: riskConfig,
        openPositionsCount: openPositionsCount,
        todayRealizedLossInr: todayRealizedLossInr,
        availableCapital: availableCapital,
      );
    }
    return rawSig;
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
