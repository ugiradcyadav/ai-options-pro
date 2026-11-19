import 'dart:math' as math;
import '../core/models.dart';
import '../data/strike_selector.dart';
import 'ai_recalibration_engine.dart';
import 'math_greeks.dart';
import 'risk_engine.dart';
import 'strategy_settings.dart';

class MarketSenseResult {
  final String badge;
  final String headline;

  const MarketSenseResult({required this.badge, required this.headline});
}

class MtfStrategyEngine {
  // Documented symmetric directional thresholds (WP-8)
  static const double bullishPcrThreshold = 1.05;
  static const double bearishPcrThreshold = 0.95;
  static const double maxChopRegimeProb = 0.62;

  static MarketSenseResult evaluateMarketSense({
    required List<StrikeRowSnapshot> chainRows,
    required double spot,
    required String expiryIso,
    required DataHealthStatus dataHealth,
  }) {
    if (dataHealth != DataHealthStatus.live || chainRows.isEmpty || spot <= 0) {
      return const MarketSenseResult(
        badge: 'NO DATA',
        headline:
            'NO DATA — Broker feed disconnected or stale (>5s). Signals & orders are blocked.',
      );
    }

    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeChg = 0;
    int totalPeChg = 0;
    int validOiDiffs = 0;
    StrikeRowSnapshot? atmRow;
    final settings = StrategySettingsEngine.instance.current;

    for (final r in chainRows) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      final cChg = settings.lookbackMinutes == 5
          ? r.ceOiChange5m
          : (settings.lookbackMinutes == 60 ? r.ceOiChange60m : r.ceOiChange15m);
      final pChg = settings.lookbackMinutes == 5
          ? r.peOiChange5m
          : (settings.lookbackMinutes == 60 ? r.peOiChange60m : r.peOiChange15m);
      if (cChg != null && pChg != null) {
        totalCeChg += cChg;
        totalPeChg += pChg;
        validOiDiffs++;
      }
      if (r.offset == 0) atmRow = r;
    }

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 0.0;
    final netOiFlowLots = totalPeChg - totalCeChg;
    final tYears =
        StrikeSelectionEngine.computeFractionalYearsToExpiryIst(expiryIso);
    final gex = MathGreeksEngine.computeDealerPositioning(
      chainRows,
      spot,
      timeYears: tYears,
    );
    final surf = MathGreeksEngine.evaluateIvSurface(chainRows, spot);
    final ai = AiRecalibrationEngine.instance;

    String badge = 'Neutral';
    String dirText = 'No directional edge (PCR & OI flow neutral)';
    if (validOiDiffs > 0 &&
        pcr >= bullishPcrThreshold &&
        netOiFlowLots > 0) {
      badge = 'Bullish';
      dirText = 'Symmetric Bullish Bias (Put OI build > Call OI build)';
    } else if (validOiDiffs > 0 &&
        pcr > 0 &&
        pcr <= bearishPcrThreshold &&
        netOiFlowLots < 0) {
      badge = 'Bearish';
      dirText = 'Symmetric Bearish Bias (Call OI build > Put OI build)';
    }

    final oiFlowStr = validOiDiffs > 0
        ? '${netOiFlowLots >= 0 ? "+" : ""}$netOiFlowLots lots'
        : 'Collecting ${settings.lookbackMinutes}m history';
    final atmIvStr =
        surf.atmIv != null ? '${surf.atmIv!.toStringAsFixed(2)}%' : 'N/A';
    final flipStr = gex.gammaFlipSpot != null
        ? gex.gammaFlipSpot!.toStringAsFixed(1)
        : 'N/A';

    return MarketSenseResult(
      badge: badge,
      headline: '$dirText\n'
          '• Model: ${ai.activeModel.version} | Gate A5: ${ai.activeModel.passedEvaluationGate ? "PASSED" : "Rules-Only"}\n'
          '• HMM: Bull ${(ai.probBullRegime * 100).toStringAsFixed(0)}% | Bear ${(ai.probBearRegime * 100).toStringAsFixed(0)}% | Chop ${(ai.probChopRegime * 100).toStringAsFixed(0)}%\n'
          '• PCR: ${pcr.toStringAsFixed(2)} | ${settings.lookbackMinutes}m Net OI: $oiFlowStr | ATM IV: $atmIvStr\n'
          '• GEX: ${gex.netGexCr >= 0 ? "+" : ""}${gex.netGexCr.toStringAsFixed(2)} Cr | Flip: $flipStr | Walls: ${gex.putWallStrike}/${gex.callWallStrike} | MaxPain: ${gex.maxPainStrike}\n'
          '• Note: ${gex.assumptionNote}',
    );
  }

  /// WP-8: SINGLE SOURCE OF TRUTH strategy function called by BOTH live engine and backtester
  static AiSignal evaluateEntry({
    required UnderlyingIndex index,
    required String expiry,
    required double spot,
    required DataHealthStatus dataHealth,
    required List<StrikeRowSnapshot> chainRows,
    required List<OneMinEnrichedBar> recentSpotBars,
    required double? availableCapital,
    required RiskConfig riskConfig,
    required int openPositionsCount,
    required double todayNetRealizedPnlIst,
    required double openPositionsRiskInr,
    StrategySettings? settingsOverride,
    int? timestampMsOverride,
  }) {
    final nowMs = timestampMsOverride ?? DateTime.now().millisecondsSinceEpoch;
    final settings = settingsOverride ?? StrategySettingsEngine.instance.current;
    final ai = AiRecalibrationEngine.instance;

    // 1. Fail-closed data health & contract presence checks
    if (dataHealth != DataHealthStatus.live) {
      return _noTrade(index, expiry, nowMs,
          'NO DATA: Feed status is ${dataHealth.label} (LIVE required)');
    }
    if (chainRows.isEmpty || spot <= 0 || expiry.isEmpty) {
      return _noTrade(
          index, expiry, nowMs, 'NO DATA: Missing live spot, expiry, or chain');
    }

    // Update HMM strictly on new SPOT bars
    ai.updateHmmRegime(recentSpotBars: recentSpotBars);

    if (ai.probChopRegime > maxChopRegimeProb) {
      return _noTrade(
        index,
        expiry,
        nowMs,
        'Abstained: HMM Chop regime probability ${(ai.probChopRegime * 100).toStringAsFixed(0)}% > ${(maxChopRegimeProb * 100).toStringAsFixed(0)}%',
      );
    }

    // 2. Resolve ATM strike row from real chain
    StrikeRowSnapshot? atmRow;
    int minDiff = 999999;
    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeOiChg = 0;
    int totalPeOiChg = 0;
    int validOiDiffRows = 0;

    for (final r in chainRows) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      final ceChg = settings.lookbackMinutes == 5
          ? r.ceOiChange5m
          : (settings.lookbackMinutes == 60 ? r.ceOiChange60m : r.ceOiChange15m);
      final peChg = settings.lookbackMinutes == 5
          ? r.peOiChange5m
          : (settings.lookbackMinutes == 60 ? r.peOiChange60m : r.peOiChange15m);
      if (ceChg != null && peChg != null) {
        totalCeOiChg += ceChg;
        totalPeOiChg += peChg;
        validOiDiffRows++;
      }
      if (r.offset.abs() < minDiff) {
        minDiff = r.offset.abs();
        atmRow = r;
      }
    }

    if (atmRow == null || atmRow.lotSize <= 0) {
      return _noTrade(
          index, expiry, nowMs, 'BLOCKED: ATM strike or master lotSize missing');
    }

    if (validOiDiffRows == 0) {
      return _noTrade(
        index,
        expiry,
        nowMs,
        'WAITING: Collecting real ${settings.lookbackMinutes}m OI snapshot history',
      );
    }

    if (totalCeOi <= 0 || totalPeOi <= 0) {
      return _noTrade(index, expiry, nowMs, 'NO DATA: Zero total option OI');
    }

    // 3. Compute real signed spot momentum from recent SPOT bars (no placeholder constants)
    final spotSorted = recentSpotBars
        .where((b) => b.optionType.toUpperCase() == 'SPOT' && b.close > 0)
        .toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    if (spotSorted.length < 4) {
      return _noTrade(index, expiry, nowMs,
          'WAITING: Need >= 4 real 1m SPOT bars for momentum (${spotSorted.length} stored)');
    }
    final latestSpotClose = spotSorted.last.close;
    final prevSpotClose = spotSorted[spotSorted.length - 4].close;
    final signedSpotMom = (latestSpotClose - prevSpotClose) / prevSpotClose;

    final pcr = totalPeOi / totalCeOi.toDouble();
    final netOiFlowLots = totalPeOiChg - totalCeOiChg;
    final totalOiLots = (totalCeOi + totalPeOi).toDouble();
    final signedOiRatio = (netOiFlowLots / totalOiLots).clamp(-1.0, 1.0);
    final reqOiLots = settings.oiThresholdForIndex(index);

    // 4. WP-8 Symmetric Bullish / Bearish / No-Trade Rules
    SignalAction direction = SignalAction.noTrade;
    if (pcr >= bullishPcrThreshold &&
        netOiFlowLots >= reqOiLots &&
        signedSpotMom > 0.0003 &&
        ai.probBullRegime > ai.probBearRegime) {
      direction = SignalAction.buyCe;
    } else if (pcr <= bearishPcrThreshold &&
        netOiFlowLots <= -reqOiLots &&
        signedSpotMom < -0.0003 &&
        ai.probBearRegime > ai.probBullRegime) {
      direction = SignalAction.buyPe;
    } else {
      return _noTrade(
        index,
        expiry,
        nowMs,
        'NO TRADE: Symmetric criteria not met (PCR ${pcr.toStringAsFixed(2)}, ΔOI $netOiFlowLots lots, Mom ${(signedSpotMom * 100).toStringAsFixed(3)}%)',
      );
    }

    final isCall = direction == SignalAction.buyCe;
    final secId = isCall ? atmRow.ceSecurityId : atmRow.peSecurityId;
    final tradingSym =
        isCall ? atmRow.ceTradingSymbol : atmRow.peTradingSymbol;
    final entryPrem = isCall ? atmRow.ceLtp : atmRow.peLtp;
    final optIv = isCall ? atmRow.ceIv : atmRow.peIv;
    final optVol = isCall ? atmRow.ceVolume : atmRow.peVolume;
    final optDelta = isCall ? atmRow.ceDelta : atmRow.peDelta;
    final optTheta = isCall ? atmRow.ceTheta : atmRow.peTheta;
    final optBid = isCall ? atmRow.ceBid : atmRow.peBid;
    final optAsk = isCall ? atmRow.ceAsk : atmRow.peAsk;
    final optAskQty = isCall ? atmRow.ceAskQty : atmRow.peAskQty;
    final optImb = isCall ? atmRow.ceImbalance : atmRow.peImbalance;

    if (secId.isEmpty || entryPrem < 2.0) {
      return _noTrade(index, expiry, nowMs,
          'BLOCKED: Contract unresolved or premium < ₹2');
    }

    if (optVol < settings.minVolumeFilter) {
      return _noTrade(index, expiry, nowMs,
          'FILTERED: Volume ($optVol) < min filter (${settings.minVolumeFilter})');
    }

    if (optIv == null ||
        optIv < settings.minIvPct ||
        optIv > settings.maxIvPct) {
      return _noTrade(
        index,
        expiry,
        nowMs,
        'FILTERED: IV (${optIv?.toStringAsFixed(2) ?? "N/A"}%) outside [${settings.minIvPct}–${settings.maxIvPct}%]',
      );
    }

    // 5. WP-8: Wire in volForecast — reject trade if holding-window theta decay exceeds expected favorable move
    final volForecast = MathGreeksEngine.computeVolForecast(
      recentSpotBars: spotSorted,
      currentAtmIvPct: optIv,
      spot: spot,
      holdingMinutes: settings.timeExitMinutes.toDouble(),
    );
    if (volForecast.expectedMovePoints != null && optTheta < 0) {
      final expectedOptMove =
          optDelta.abs() * volForecast.expectedMovePoints!;
      final holdingThetaLoss =
          optTheta.abs() * (settings.timeExitMinutes / (24.0 * 60.0));
      if (holdingThetaLoss > expectedOptMove) {
        return _noTrade(
          index,
          expiry,
          nowMs,
          'FILTERED: Theta decay (₹${holdingThetaLoss.toStringAsFixed(2)}) > expected favorable move (₹${expectedOptMove.toStringAsFixed(2)})',
        );
      }
    }

    // 6. Signed shadow score & Gate-A5-aware position sizing
    final confidence = ai.scoreEnsembleConfidence(
      isCallSignal: isCall,
      signedOiScore: signedOiRatio,
      signedMomentumScore: (signedSpotMom * 100.0).clamp(-1.0, 1.0),
      signedOrderBookImbalance: optImb ?? 0.0,
      signedPcrBias: (pcr - 1.0).clamp(-1.0, 1.0),
      deltaAbsQuality: optDelta.abs(),
    );

    final targetPct = settings.targetPctForIndex(index) / 100.0;
    final stopPct = settings.stopLossPctForIndex(index) / 100.0;
    final slPrem = math.max(0.50, entryPrem * (1.0 - stopPct));
    final targetPrem = entryPrem * (1.0 + targetPct);

    final qty = RiskEngine.computeOptimalBuyerQuantity(
      winProbability: confidence / 100.0,
      entryPremium: entryPrem,
      stopLossPremium: slPrem,
      targetPremium: targetPrem,
      lotSize: atmRow.lotSize,
      availableCapital: availableCapital,
      config: riskConfig,
      useModelProbability: ai.activeModel.passedEvaluationGate,
    );

    final rawSig = AiSignal(
      timestampMs: nowMs,
      index: index,
      expiry: expiry,
      securityId: secId,
      tradingSymbol: tradingSym,
      strike: atmRow.strike,
      action: direction,
      confidencePct: confidence,
      htfOiReason:
          'Symmetric ${isCall ? "Bullish" : "Bearish"} • PCR ${pcr.toStringAsFixed(2)} | ${settings.lookbackMinutes}m ΔOI $netOiFlowLots lots',
      reasons: [
        'Mode: ${ai.activeModel.passedEvaluationGate ? "Verified Model" : "Rules-Only (Gate A5 pending)"}',
        'Forward-HMM: Bull ${(ai.probBullRegime * 100).toStringAsFixed(0)}% | Bear ${(ai.probBearRegime * 100).toStringAsFixed(0)}% | Chop ${(ai.probChopRegime * 100).toStringAsFixed(0)}%',
        'Black-76 IV: ${optIv.toStringAsFixed(2)}% | Δ ${optDelta.toStringAsFixed(3)} | Θ ${optTheta.toStringAsFixed(2)}/d',
      ],
      entryPremium: entryPrem,
      stopLossPremium: slPrem,
      targetPremium: targetPrem,
      lotSize: atmRow.lotSize,
      quantity: qty,
      requiredCapital: entryPrem * qty,
      availableCapital: availableCapital ?? 0.0,
      strategyPassed: true,
      riskWithinLimits: false,
      riskNote: 'Pending Risk Gate',
      modelVersion: ai.activeModel.version,
    );

    return RiskEngine.validateAndEnforceRisk(
      rawSignal: rawSig,
      config: riskConfig,
      openPositionsCount: openPositionsCount,
      todayNetRealizedPnlIst: todayNetRealizedPnlIst,
      openPositionsRiskInr: openPositionsRiskInr,
      availableCapital: availableCapital,
      bidPrice: optBid,
      askPrice: optAsk,
      topAskQty: optAskQty,
      enforceEvGate: ai.activeModel.passedEvaluationGate,
    );
  }

  static AiSignal _noTrade(
      UnderlyingIndex index, String expiry, int tsMs, String reason) {
    return AiSignal(
      timestampMs: tsMs,
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
      lotSize: 0,
      quantity: 0,
      requiredCapital: 0.0,
      availableCapital: 0.0,
      strategyPassed: false,
      riskWithinLimits: false,
      riskNote: reason,
      modelVersion: AiRecalibrationEngine.instance.activeModel.version,
    );
  }
}
