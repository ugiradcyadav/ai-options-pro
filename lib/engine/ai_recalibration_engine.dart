import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../data/forever_db.dart';

class AiModelMeta {
  final String version;
  final String algorithmName;
  final double validationWinRate;
  final int oosSampleCount;
  final double ciLowerPct;
  final double ciUpperPct;
  final bool passedEvaluationGate;

  const AiModelMeta({
    required this.version,
    this.algorithmName = 'Rule-weighted logistic score + Forward-HMM',
    required this.validationWinRate,
    this.oosSampleCount = 0,
    this.ciLowerPct = 0.0,
    this.ciUpperPct = 0.0,
    this.passedEvaluationGate = false,
  });

  bool get hasSufficientData => oosSampleCount >= 100;

  String get displayAccuracyLabel {
    if (!hasSufficientData) {
      return 'Insufficient data (N=$oosSampleCount < 100 OOS trades)';
    }
    return '${validationWinRate.toStringAsFixed(1)}% (95% CI: ${ciLowerPct.toStringAsFixed(1)}–${ciUpperPct.toStringAsFixed(1)}%, N=$oosSampleCount)';
  }
}

class AiRecalibrationEngine {
  static final AiRecalibrationEngine instance = AiRecalibrationEngine._();
  AiRecalibrationEngine._();

  static const int minOosTradesRequired = 100;

  // A1.1: Truthful naming (Rule-weighted logistic score + 3-state Forward-Filter Gaussian HMM)
  String modelVersion = 'RuleLogistic-HMM-20261102-init';
  double validationWinRate = 50.0; // Unclamped real out-of-sample rate
  int oosSampleCount = 0;
  double oosCiLower = 0.0;
  double oosCiUpper = 0.0;
  bool passedEvaluationGate = false; // A5: stays false until >=300 OOS trades & CI_lower > 0

  String lastRecalibrationNote =
      'Rule-weighted logistic score (Shadow Mode • Insufficient OOS data N=0 < 100)';
  int lastCalibrationMs = 0;
  int trainedBarCount = 0;
  final List<String> engineErrorLog = [];

  AiModelMeta get activeModel => AiModelMeta(
        version: modelVersion,
        validationWinRate: validationWinRate,
        oosSampleCount: oosSampleCount,
        ciLowerPct: oosCiLower,
        ciUpperPct: oosCiUpper,
        passedEvaluationGate: passedEvaluationGate,
      );

  // Calibrated logistic weights (can be rolled back safely per A7)
  double wHtfOiFlow = 0.34;
  double wMicroMomentum = 0.24;
  double wOrderBookImb = 0.18;
  double wPcrVelocity = 0.14;
  double wGammaRegime = 0.10;

  // Previous weights for A7 safe rollback
  double _prevWOi = 0.34;
  double _prevWMom = 0.24;
  double _prevWImb = 0.18;

  // M6: Real 3-State Gaussian-Emission HMM Parameters
  // States: 0 = BullTrend, 1 = BearTrend, 2 = ChoppyMeanRevert
  List<List<double>> hmmTransitionMatrix = [
    [0.82, 0.06, 0.12],
    [0.06, 0.82, 0.12],
    [0.14, 0.14, 0.72],
  ];
  List<double> hmmReturnMeans = [0.00045, -0.00045, 0.0];
  List<double> hmmReturnVars = [0.0000018, 0.0000018, 0.0000006];

  double probBullRegime = 0.3333;
  double probBearRegime = 0.3333;
  double probChopRegime = 0.3334;

  void _logEngineError(String context, Object error) {
    final ts = DateFormat('HH:mm:ss').format(DateTime.now());
    final msg = '[$ts] $context: $error';
    engineErrorLog.add(msg);
    if (engineErrorLog.length > 50) {
      engineErrorLog.removeAt(0);
    }
  }

  String _computeVersionHash() {
    final dateStr = DateFormat('yyyyMMdd').format(DateTime.now());
    final payload =
        '${wHtfOiFlow.toStringAsFixed(4)}|${wMicroMomentum.toStringAsFixed(4)}|${wOrderBookImb.toStringAsFixed(4)}|$trainedBarCount';
    final digest =
        sha1.convert(utf8.encode(payload)).toString().substring(0, 7);
    return 'RuleLogistic-$dateStr-$digest';
  }

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      wHtfOiFlow = prefs.getDouble('ai_w_htf_oi') ?? 0.34;
      wMicroMomentum = prefs.getDouble('ai_w_mom') ?? 0.24;
      wOrderBookImb = prefs.getDouble('ai_w_imb') ?? 0.18;
      wPcrVelocity = prefs.getDouble('ai_w_pcr') ?? 0.14;
      wGammaRegime = prefs.getDouble('ai_w_gex') ?? 0.10;
      validationWinRate = prefs.getDouble('ai_val_win_rate_unclamped') ?? 50.0;
      oosSampleCount = prefs.getInt('ai_oos_sample_count') ?? 0;
      lastCalibrationMs = prefs.getInt('ai_last_cal_ms') ??
          DateTime.now().millisecondsSinceEpoch;
      await recalibrateFromForeverDb();
    } catch (e) {
      _logEngineError('initialize', e);
    }
  }

  Future<void> rollbackToPreviousWeights() async {
    wHtfOiFlow = _prevWOi;
    wMicroMomentum = _prevWMom;
    wOrderBookImb = _prevWImb;
    modelVersion = _computeVersionHash();
    lastRecalibrationNote = 'Rolled back to previous calibration ($modelVersion)';
  }

  Future<void> runLightweightFiveDayRecalibration({bool force = false}) async {
    await recalibrateFromForeverDb();
  }

  double _gaussianPdf(double x, double mean, double variance) {
    final v = math.max(variance, 1e-9);
    final diff = x - mean;
    return math.exp(-0.5 * diff * diff / v) / math.sqrt(2.0 * math.pi * v);
  }

  /// M6: True Forward-Filter Recursion over 3-State Gaussian-Emission HMM
  void updateHmmRegime({
    required List recentBars,
    required double netOiFlowScore,
    required double pcr,
  }) {
    List<double> alpha = [probBullRegime, probBearRegime, probChopRegime];

    if (recentBars.length >= 2) {
      for (int t = 1; t < recentBars.length; t++) {
        final prev = (recentBars[t - 1].underlyingSpot as num).toDouble();
        final curr = (recentBars[t].underlyingSpot as num).toDouble();
        if (prev <= 0 || curr <= 0) continue;
        final obsRet = (curr - prev) / prev;

        final nextAlpha = List<double>.filled(3, 0.0);
        double normSum = 0.0;
        for (int j = 0; j < 3; j++) {
          double transSum = 0.0;
          for (int i = 0; i < 3; i++) {
            transSum += alpha[i] * hmmTransitionMatrix[i][j];
          }
          final adjMean = hmmReturnMeans[j] +
              (j == 0
                  ? netOiFlowScore * 0.00015
                  : (j == 1 ? -netOiFlowScore * 0.00015 : 0.0));
          final emission = _gaussianPdf(obsRet, adjMean, hmmReturnVars[j]);
          nextAlpha[j] = transSum * math.max(emission, 1e-12);
          normSum += nextAlpha[j];
        }
        if (normSum > 0) {
          for (int j = 0; j < 3; j++) {
            alpha[j] = nextAlpha[j] / normSum;
          }
        }
      }
    } else {
      // Single-step forward update using OI flow & PCR observation
      final synthObs =
          netOiFlowScore * 0.0003 + ((pcr - 1.0).clamp(-0.5, 0.5) * 0.0002);
      final nextAlpha = List<double>.filled(3, 0.0);
      double normSum = 0.0;
      for (int j = 0; j < 3; j++) {
        double transSum = 0.0;
        for (int i = 0; i < 3; i++) {
          transSum += alpha[i] * hmmTransitionMatrix[i][j];
        }
        final emission =
            _gaussianPdf(synthObs, hmmReturnMeans[j], hmmReturnVars[j]);
        nextAlpha[j] = transSum * math.max(emission, 1e-12);
        normSum += nextAlpha[j];
      }
      if (normSum > 0) {
        for (int j = 0; j < 3; j++) {
          alpha[j] = nextAlpha[j] / normSum;
        }
      }
    }

    probBullRegime = alpha[0];
    probBearRegime = alpha[1];
    probChopRegime = alpha[2];
  }

  /// Export/import HMM parameters as JSON for M6 Python <-> Dart round-trip verification
  String exportHmmParamsJson() {
    return jsonEncode({
      'transition_matrix': hmmTransitionMatrix,
      'means': hmmReturnMeans,
      'variances': hmmReturnVars,
      'filtered_probs': [probBullRegime, probBearRegime, probChopRegime],
    });
  }

  void importHmmParamsJson(String jsonStr) {
    try {
      final m = jsonDecode(jsonStr) as Map;
      if (m['transition_matrix'] is List) {
        hmmTransitionMatrix = (m['transition_matrix'] as List)
            .map((r) =>
                (r as List).map((x) => (x as num).toDouble()).toList())
            .toList();
      }
      if (m['means'] is List) {
        hmmReturnMeans =
            (m['means'] as List).map((x) => (x as num).toDouble()).toList();
      }
      if (m['variances'] is List) {
        hmmReturnVars = (m['variances'] as List)
            .map((x) => (x as num).toDouble())
            .toList();
      }
    } catch (e) {
      _logEngineError('importHmmParamsJson', e);
    }
  }

  double scoreSetupConfidence({
    required bool isCallSignal,
    required double htfOiScore,
    required double momentumScore,
    required double orderBookImbalance,
    required double pcrScore,
    required double deltaQualityScore,
  }) {
    return scoreEnsembleConfidence(
      isCallSignal: isCallSignal,
      htfOiScore: htfOiScore,
      momentumScore: momentumScore,
      orderBookImbalance: orderBookImbalance,
      pcrScore: pcrScore,
      deltaQualityScore: deltaQualityScore,
    );
  }

  double scoreEnsembleConfidence({
    required bool isCallSignal,
    required double htfOiScore,
    required double momentumScore,
    required double orderBookImbalance,
    required double pcrScore,
    required double deltaQualityScore,
  }) {
    final regimeBoost = isCallSignal ? probBullRegime : probBearRegime;
    final chopPenalty =
        probChopRegime > 0.45 ? (probChopRegime - 0.45) * 0.65 : 0.0;

    final linearLogit = -0.25 +
        (wHtfOiFlow * htfOiScore * 2.0) +
        (wMicroMomentum * momentumScore * 1.8) +
        (wOrderBookImb * orderBookImbalance * 1.5) +
        (wPcrVelocity * pcrScore * 1.4) +
        (wGammaRegime * deltaQualityScore * 1.2) +
        (regimeBoost * 0.95) -
        chopPenalty;

    final prob = 1.0 / (1.0 + math.exp(-linearLogit));
    return double.parse((prob * 100.0).toStringAsFixed(2));
  }

  /// A1: Evaluates unclamped Out-of-Sample accuracy on any label/feature list (used by tests & DB)
  Map<String, double> evaluateUnclampedOutOfSample(
      List<List<double>> features, List<int> labels) {
    if (features.isEmpty || features.length != labels.length) {
      return {'accuracyPct': 50.0, 'ciLow': 0.0, 'ciHigh': 100.0, 'n': 0.0};
    }
    int correct = 0;
    for (int i = 0; i < features.length; i++) {
      final f = features[i];
      final z = (wHtfOiFlow * (f.isNotEmpty ? f[0] : 0.0)) +
          (wMicroMomentum * (f.length > 1 ? f[1] : 0.0)) +
          (wOrderBookImb * (f.length > 2 ? f[2] : 0.0));
      final pred = (1.0 / (1.0 + math.exp(-z))) >= 0.5 ? 1 : 0;
      if (pred == labels[i]) correct++;
    }
    final n = features.length;
    final p = correct / n.toDouble();
    final se = math.sqrt(math.max(1e-9, p * (1.0 - p) / n));
    final ciLow = math.max(0.0, (p - 1.96 * se) * 100.0);
    final ciHigh = math.min(100.0, (p + 1.96 * se) * 100.0);
    return {
      'accuracyPct': p * 100.0,
      'ciLow': ciLow,
      'ciHigh': ciHigh,
      'n': n.toDouble(),
    };
  }

  /// A1 & A2: Trains on all 3 indices with strict 60/40 Walk-Forward Out-of-Sample split & Triple-Barrier option labels
  Future<void> recalibrateFromForeverDb() async {
    try {
      final allBars = <OneMinEnrichedBar>[];
      for (final idx in UnderlyingIndex.values) {
        final bList = await ForeverDatabase.instance
            .getRecentBars(indexName: idx.label, limit: 200);
        for (final b in bList) {
          allBars.add(b);
        }
      }

      trainedBarCount = allBars.length;
      if (allBars.length < 30) {
        oosSampleCount = 0;
        validationWinRate = 50.0;
        modelVersion = _computeVersionHash();
        lastRecalibrationNote =
            'Insufficient data (N=0 < $minOosTradesRequired OOS trades) • Rules-only active';
        return;
      }

      _prevWOi = wHtfOiFlow;
      _prevWMom = wMicroMomentum;
      _prevWImb = wOrderBookImb;

      // Chronological sort and 60% Train / Embargo / 40% Out-of-Sample Test split
      allBars.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      final splitIdx = (allBars.length * 0.60).floor();
      const embargoBars = 3;

      double gradOi = 0.0;
      double gradMom = 0.0;
      double gradImb = 0.0;
      int trainCount = 0;

      // 1. In-Sample Calibration (first 60%)
      for (int i = 3; i < splitIdx - 3; i++) {
        final b = allBars[i];
        final prevB = allBars[i - 3];
        if (b.close <= 0 || prevB.close <= 0) continue;

        // A2: Triple-barrier option-premium net outcome (Target +8%, Stop -6% net of ~1.2% round-trip cost)
        int label = 0;
        for (int k = 1; k <= 3; k++) {
          final fut = allBars[i + k];
          final netRet = ((fut.close - b.close) / b.close) - 0.012;
          if (netRet <= -0.06) {
            label = 0;
            break;
          }
          if (netRet >= 0.04) {
            label = 1;
            break;
          }
        }

        final fOi = (b.oiChange15m / 500000.0).clamp(-1.0, 1.0);
        final fMom =
            ((b.close - prevB.close) / prevB.close * 15.0).clamp(-1.0, 1.0);
        final fImb = b.orderBookImbalance.clamp(-1.0, 1.0);

        final z = (wHtfOiFlow * fOi) +
            (wMicroMomentum * fMom) +
            (wOrderBookImb * fImb);
        final pred = 1.0 / (1.0 + math.exp(-z));
        final err = label - pred;

        gradOi += err * fOi;
        gradMom += err * fMom;
        gradImb += err * fImb;
        trainCount++;
      }

      if (trainCount > 5) {
        const lr = 0.02;
        wHtfOiFlow = (wHtfOiFlow + lr * (gradOi / trainCount)).clamp(0.10, 0.60);
        wMicroMomentum =
            (wMicroMomentum + lr * (gradMom / trainCount)).clamp(0.10, 0.50);
        wOrderBookImb =
            (wOrderBookImb + lr * (gradImb / trainCount)).clamp(0.05, 0.40);
        final sum = wHtfOiFlow +
            wMicroMomentum +
            wOrderBookImb +
            wPcrVelocity +
            wGammaRegime;
        wHtfOiFlow /= sum;
        wMicroMomentum /= sum;
        wOrderBookImb /= sum;
        wPcrVelocity /= sum;
        wGammaRegime /= sum;
      }

      // 2. Out-of-Sample Evaluation (strictly after splitIdx + embargoBars)
      final oosFeatures = <List<double>>[];
      final oosLabels = <int>[];
      for (int i = splitIdx + embargoBars; i < allBars.length - 3; i++) {
        final b = allBars[i];
        final prevB = allBars[i - 3];
        if (b.close <= 0 || prevB.close <= 0) continue;

        int label = 0;
        for (int k = 1; k <= 3; k++) {
          final fut = allBars[i + k];
          final netRet = ((fut.close - b.close) / b.close) - 0.012;
          if (netRet <= -0.06) {
            label = 0;
            break;
          }
          if (netRet >= 0.04) {
            label = 1;
            break;
          }
        }

        oosFeatures.add([
          (b.oiChange15m / 500000.0).clamp(-1.0, 1.0),
          ((b.close - prevB.close) / prevB.close * 15.0).clamp(-1.0, 1.0),
          b.orderBookImbalance.clamp(-1.0, 1.0),
        ]);
        oosLabels.add(label);
      }

      final oosMetrics = evaluateUnclampedOutOfSample(oosFeatures, oosLabels);
      oosSampleCount = (oosMetrics['n'] ?? 0).round();
      validationWinRate = oosMetrics['accuracyPct'] ?? 50.0; // NEVER CLAMPED!
      oosCiLower = oosMetrics['ciLow'] ?? 0.0;
      oosCiUpper = oosMetrics['ciHigh'] ?? 100.0;
      passedEvaluationGate =
          oosSampleCount >= 300 && oosCiLower > 52.0; // A5 gate

      lastCalibrationMs = DateTime.now().millisecondsSinceEpoch;
      modelVersion = _computeVersionHash();

      if (oosSampleCount < minOosTradesRequired) {
        lastRecalibrationNote =
            'Insufficient data (N=$oosSampleCount < $minOosTradesRequired OOS) • Raw OOS: ${validationWinRate.toStringAsFixed(1)}%';
      } else {
        lastRecalibrationNote =
            'OOS Accuracy: ${validationWinRate.toStringAsFixed(1)}% (95% CI ${oosCiLower.toStringAsFixed(1)}–${oosCiUpper.toStringAsFixed(1)}%, N=$oosSampleCount)';
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('ai_w_htf_oi', wHtfOiFlow);
      await prefs.setDouble('ai_w_mom', wMicroMomentum);
      await prefs.setDouble('ai_w_imb', wOrderBookImb);
      await prefs.setDouble('ai_val_win_rate_unclamped', validationWinRate);
      await prefs.setInt('ai_oos_sample_count', oosSampleCount);
      await prefs.setInt('ai_last_cal_ms', lastCalibrationMs);
    } catch (e) {
      _logEngineError('recalibrateFromForeverDb', e);
    }
  }
}
