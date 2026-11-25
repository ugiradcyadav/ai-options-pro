import 'dart:math' as math;
import '../core/models.dart';
import '../data/strike_selector.dart';
import 'math_greeks.dart';
import 'regime_engine.dart';
import 'risk_engine.dart';
import 'sadhu_ml_engine.dart';
import 'strategy_settings.dart';

class MarketSenseResult {
  final String badge;
  final String headline;

  const MarketSenseResult({required this.badge, required this.headline});
}

class MtfStrategyEngine {
  static const double bullishPcrThreshold = 1.05;
  static const double bearishPcrThreshold = 0.95;
  static const double maxChopRegimeProb = 0.62;

  static bool isPastEntryCutoffIst(int timestampMs) {
    final ist = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true)
        .add(const Duration(hours: 5, minutes: 30));
    return (ist.hour * 60 + ist.minute) >= (15 * 60 + 10);
  }

  static MarketSenseResult evaluateMarketSense({
    required List<StrikeRowSnapshot> chainRows,
    required double spot,
    required String expiryIso,
    required DataHealthStatus dataHealth,
    MeasuredRegimeSnapshot? regime,
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

    final atmIvStr = atmRow?.ceIv != null
        ? '${atmRow!.ceIv!.toStringAsFixed(2)}%'
        : 'N/A';
    final oiFlowStr = validOiDiffs > 0
        ? '${netOiFlowLots >= 0 ? "+" : ""}$netOiFlowLots lots'
        : 'Collecting';
    final flipStr =
        gex.gammaFlipSpot != null ? gex.gammaFlipSpot!.toStringAsFixed(0) : 'N/A';
    final ml = SadhuMlEngine.instance;

    String badge = 'Neutral';
    if (regime != null && regime.hasSufficientData) {
      if (regime.regimeLabel == 'TRENDING BULL' && pcr >= bullishPcrThreshold) {
        badge = 'Bullish';
      } else if (regime.regimeLabel == 'TRENDING BEAR' &&
          pcr <= bearishPcrThreshold) {
        badge = 'Bearish';
      } else if (regime.chopProb > maxChopRegimeProb) {
        badge = 'Chop';
      }
    } else if (pcr >= bullishPcrThreshold && netOiFlowLots > 0) {
      badge = 'Bullish';
    } else if (pcr <= bearishPcrThreshold && netOiFlowLots < 0) {
      badge = 'Bearish';
    }

    final regimeLine = regime != null
        ? '${regime.regimeLabel} | ${regime.summaryNote}'
        : 'Collecting 1m spot bars for measured regime';

    return MarketSenseResult(
      badge: badge,
      headline:
          '• Sadhu ML: ${ml.isTrained ? ml.lastReport.note : "Untrained (Rules Fallback)"}\n'
          '• Regime: $regimeLine\n'
          '• PCR: ${pcr.toStringAsFixed(2)} | ${settings.lookbackMinutes}m Net OI: $oiFlowStr | ATM IV: $atmIvStr\n'
          '• GEX: ${gex.netGexCr >= 0 ? "+" : ""}${gex.netGexCr.toStringAsFixed(2)} Cr | Flip: $flipStr | Walls: ${gex.putWallStrike}/${gex.callWallStrike} | MaxPain: ${gex.maxPainStrike}',
    );
  }

  /// Stateless SINGLE SOURCE OF TRUTH called by both live AppState and per-contract BacktestEngine
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

    // 1. Fail-closed data health, contract presence & H4 15:10 IST cut-off
    if (dataHealth != DataHealthStatus.live) {
      return _noTrade(index, expiry, nowMs,
          'NO DATA: Feed status is ${dataHealth.label} (LIVE required)');
    }
    if (chainRows.isEmpty || spot <= 0 || expiry.isEmpty) {
      return _noTrade(
          index, expiry, nowMs, 'NO DATA: Missing live spot, expiry, or chain');
    }
    if (isPastEntryCutoffIst(nowMs)) {
      return _noTrade(index, expiry, nowMs,
          'BLOCKED: Past 15:10 IST entry cut-off (15:15 forced exit)');
    }

    // 2. Pure stateless Measured Market Regime (fixes C3 global state corruption)
    final regime = RegimeEngine.evaluate(
      indexLabel: index.label,
      spotBars: recentSpotBars,
      liveSpot: spot,
    );
    if (regime.hasSufficientData && regime.chopProb > maxChopRegimeProb) {
      return _noTrade(
        index,
        expiry,
        nowMs,
        'Abstained: Measured Chop ${(regime.chopProb * 100).toStringAsFixed(0)}% > ${(maxChopRegimeProb * 100).toStringAsFixed(0)}% (${regime.summaryNote})',
      );
    }

    // 3. Resolve ATM row & aggregate real OI across full chain
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
      return _noTrade(index, expiry, nowMs, 'NO DATA: Zero total CE or PE OI');
    }

    // 4. Real signed spot momentum from recent SPOT bars
    final spotSorted = recentSpotBars
        .where((b) => b.optionType.toUpperCase() == 'SPOT' && b.close > 0)
        .toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    if (spotSorted.length < 4) {
      return _noTrade(index, expiry, nowMs,
          'WAITING: Need >= 4 real 1m SPOT bars (${spotSorted.length} stored)');
    }
    final latestSpotClose = spotSorted.last.close;
    final prevSpotClose = spotSorted[spotSorted.length - 4].close;
    final signedSpotMom = (latestSpotClose - prevSpotClose) / prevSpotClose;

    final pcr = totalPeOi / totalCeOi.toDouble();
    final netOiFlowLots = totalPeOiChg - totalCeOiChg;
    final reqOiLots = settings.oiThresholdForIndex(index);

    final bullRegimeOk =
        !regime.hasSufficientData || regime.bullProb >= regime.bearProb;
    final bearRegimeOk =
        !regime.hasSufficientData || regime.bearProb >= regime.bullProb;

    SignalAction direction = SignalAction.noTrade;
    if (pcr >= bullishPcrThreshold &&
        netOiFlowLots >= reqOiLots &&
        signedSpotMom > 0.0003 &&
        bullRegimeOk) {
      direction = SignalAction.buyCe;
    } else if (pcr <= bearishPcrThreshold &&
        netOiFlowLots <= -reqOiLots &&
        signedSpotMom < -0.0003 &&
        bearRegimeOk) {
      direction = SignalAction.buyPe;
    } else {
      return _noTrade(
        index,
        expiry,
        nowMs,
        'NO TRADE: Criteria unmet (PCR ${pcr.toStringAsFixed(2)}, ΔOI $netOiFlowLots, Mom ${(signedSpotMom * 100).toStringAsFixed(3)}%)',
      );
    }

    final isCall = direction == SignalAction.buyCe;
    final secId = isCall ? atmRow.ceSecurityId : atmRow.peSecurityId;
    final tradingSym = isCall ? atmRow.ceTradingSymbol : atmRow.peTradingSymbol;
    final entryPrem = isCall ? atmRow.ceLtp : atmRow.peLtp;
    final optIv = isCall ? atmRow.ceIv : atmRow.peIv;
    final optVol = isCall ? atmRow.ceVolume : atmRow.peVolume;
    final optOi = isCall ? atmRow.ceOi : atmRow.peOi;
    final optOiChg15 = isCall ? atmRow.ceOiChange15m : atmRow.peOiChange15m;
    final optDelta = isCall ? atmRow.ceDelta : atmRow.peDelta;
    final optTheta = isCall ? atmRow.ceTheta : atmRow.peTheta;
    final optBid = isCall ? atmRow.ceBid : atmRow.peBid;
    final optAsk = isCall ? atmRow.ceAsk : atmRow.peAsk;
    final optAskQty = isCall ? atmRow.ceAskQty : atmRow.peAskQty;
    final optImb = isCall ? atmRow.ceImbalance : atmRow.peImbalance;

    if (secId.isEmpty || entryPrem < 2.0) {
      return _noTrade(
          index, expiry, nowMs, 'BLOCKED: Contract unresolved or premium < ₹2');
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
        'FILTERED: IV (${optIv?.toStringAsFixed(2) ?? "N/A"}%) outside [${settings.minIvPct}-${settings.maxIvPct}%]',
      );
    }

    double spreadPct = 0.25;
    if (optBid != null && optAsk != null && optBid > 0 && optAsk >= optBid) {
      final mid = 0.5 * (optBid + optAsk);
      if (mid > 0) spreadPct = ((optAsk - optBid) / mid) * 100.0;
    }

    // 5. Sadhu AI ML Calibrated Probability (H1 fix: no fake hardcoded weights)
    final mlFeatures = <double>[
      signedSpotMom * (isCall ? 1.0 : -1.0) * 5.0,
      signedSpotMom,
      optImb ?? 0.0,
      (optOiChg15 ?? 0) / math.max(1, optOi).toDouble(),
      optIv / 100.0,
      optDelta.abs(),
      spreadPct / 100.0,
    ];
    final mlPred = SadhuMlEngine.instance.predict(mlFeatures);
    if (mlPred.isTrained && mlPred.calibratedProb < 0.52) {
      return _noTrade(
        index,
        expiry,
        nowMs,
        'Sadhu ML Filtered: Calibrated P(Win) ${(mlPred.calibratedProb * 100).toStringAsFixed(1)}% < 52%',
      );
    }

    final confidence = mlPred.isTrained
        ? (mlPred.calibratedProb * 100.0).clamp(1.0, 99.0).toDouble()
        : 50.0;

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
      useModelProbability: mlPred.isTrained,
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
          '${isCall ? "Bullish" : "Bearish"} • PCR ${pcr.toStringAsFixed(2)} | ${settings.lookbackMinutes}m ΔOI $netOiFlowLots lots',
      reasons: [
        mlPred.statusNote,
        'Regime: ${regime.regimeLabel} (${regime.summaryNote})',
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
      modelVersion: mlPred.isTrained
          ? 'Sadhu-ML-Boosted-v1'
          : 'Sadhu-ML-Untrained (Rules)',
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
      enforceEvGate: mlPred.isTrained,
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
      modelVersion: SadhuMlEngine.instance.isTrained
          ? 'Sadhu-ML-Boosted-v1'
          : 'Sadhu-ML-Untrained',
    );
  }
}
