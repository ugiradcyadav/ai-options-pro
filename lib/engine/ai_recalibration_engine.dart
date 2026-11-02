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
      return 'Insufficient data (N=$oosSampleCount, need 100 OOS trades)';
    }
    return '${validationWinRate.toStringAsFixed(1)}% (95% CI: ${ciLowerPct.toStringAsFixed(1)}-${ciUpperPct.toStringAsFixed(1)}%, N=$oosSampleCount)';
  }
}

class AiRecalibrationEngine {
  static final AiRecalibrationEngine instance = AiRecalibrationEngine._();
  AiRecalibrationEngine._();

  static const int minOosTradesRequired = 100;

  String modelVersion = 'RuleLogistic-HMM-20261102';
  double validationWinRate = 50.0;
  int oosSampleCount = 0;
  double oosCiLower = 0.0;
  double oosCiUpper = 0.0;
  bool passedEvaluationGate = false;

  String lastRecalibrationNote =
      'Rule-weighted logistic score (Shadow Mode • Insufficient data N=0)';
  int lastCalibrationMs = 0;
  int trainedBarCount = 0;
  final List engineErrorLog = [];

  AiModelMeta get activeModel => AiModelMeta(
        version: modelVersion,
        validationWinRate: validationWinRate,
        oosSampleCount: oosSampleCount,
        ciLowerPct: oosCiLower,
        ciUpperPct: oosCiUpper,
        passedEvaluationGate: passedEvaluationGate,
      );

  double wHtfOiFlow = 0.34;
  double wMicroMomentum = 0.24;
  double wOrderBookImb = 0.18;
  double wPcrVelocity = 0.14;
  double wGammaRegime = 0.10;

  List hmmTransitionMatrix = [
    [0.82, 0.06, 0.12],
    [0.06, 0.82, 0.12],
    [0.14, 0.14, 0.72],
  ];
  List hmmReturnMeans = [0.00045, -0.00045, 0.0];
  List hmmReturnVars = [0.0000018, 0.0000018, 0.0000006];

  double probBullRegime = 0.34;
  double probBearRegime = 0.33;
  double probChopRegime = 0.33;

  void _logEngineError(String context, Object error) {
    final ts = DateFormat('HH:mm:ss').format(DateTime.now());
    engineErrorLog.add('[$ts] $context: $error');
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

  Future initialize() async {
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

  Future runLightweightFiveDayRecalibration({bool force = false}) async {
    await recalibrateFromForeverDb();
  }

  double _gaussianPdf(double x, double mean, double variance) {
    final v = math.max(variance, 1e-9);
    final diff = x - mean;
    return math.exp(-0.5 * diff * diff / v) / math.sqrt(2.0 * math.pi * v);
  }

  void updateHmmRegime({
    required List recentBars,
    required double netOiFlowScore,
    required double pcr,
  }) {
    final List alpha = [probBullRegime, probBearRegime, probChopRegime];

    if (recentBars.length >= 2) {
      for (int t = 1; recentBars.length > t; t++) {
        final prev = (recentBars[t - 1].underlyingSpot as num).toDouble();
        final curr = (recentBars[t].underlyingSpot as num).toDouble();
        if (0 >= prev || 0 >= curr) continue;
        final obsRet = (curr - prev) / prev;

        final List nextAlpha = [0.0, 0.0, 0.0];
        double normSum = 0.0;
        for (int j = 0; 3 > j; j++) {
          double transSum = 0.0;
          for (int i = 0; 3 > i; i++) {
            final row = hmmTransitionMatrix[i] as List;
            transSum += (alpha[i] as double) * ((row[j] as num).toDouble());
          }
          final baseMean = (hmmReturnMeans[j] as num).toDouble();
          final baseVar = (hmmReturnVars[j] as num).toDouble();
          final adjMean = baseMean +
              (j == 0
                  ? netOiFlowScore * 0.00015
                  : (j == 1 ? -netOiFlowScore * 0.00015 : 0.0));
          final emission = _gaussianPdf(obsRet, adjMean, baseVar);
          nextAlpha[j] = transSum * math.max(emission, 1e-12);
          normSum += nextAlpha[j] as double;
        }
        if (normSum > 0) {
          for (int j = 0; 3 > j; j++) {
            alpha[j] = (nextAlpha[j] as double) / normSum;
          }
        }
      }
    } else {
      final synthObs =
          netOiFlowScore * 0.0003 + ((pcr - 1.0).clamp(-0.5, 0.5) * 0.0002);
      final List nextAlpha = [0.0, 0.0, 0.0];
      double normSum = 0.0;
      for (int j = 0; 3 > j; j++) {
        double transSum = 0.0;
        for (int i = 0; 3 > i; i++) {
          final row = hmmTransitionMatrix[i] as List;
          transSum += (alpha[i] as double) * ((row[j] as num).toDouble());
        }
        final emission = _gaussianPdf(
          synthObs,
          (hmmReturnMeans[j] as num).toDouble(),
          (hmmReturnVars[j] as num).toDouble(),
        );
        nextAlpha[j] = transSum * math.max(emission, 1e-12);
        normSum += nextAlpha[j] as double;
      }
      if (normSum > 0) {
        for (int j = 0; 3 > j; j++) {
          alpha[j] = (nextAlpha[j] as double) / normSum;
        }
      }
    }

    probBullRegime = alpha[0] as double;
    probBearRegime = alpha[1] as double;
    probChopRegime = alpha[2] as double;
  }

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
        hmmTransitionMatrix = m['transition_matrix'] as List;
      }
      if (m['means'] is List) {
        hmmReturnMeans = m['means'] as List;
      }
      if (m['variances'] is List) {
        hmmReturnVars = m['variances'] as List;
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

  Map evaluateUnclampedOutOfSample(List features, List labels) {
    if (features.isEmpty || features.length != labels.length) {
      return {'accuracyPct': 50.0, 'ciLow': 0.0, 'ciHigh': 100.0, 'n': 0.0};
    }
    int correct = 0;
    for (int i = 0; features.length > i; i++) {
      final f = features[i] as List;
      final f0 = f.isNotEmpty ? (f[0] as num).toDouble() : 0.0;
      final f1 = f.length > 1 ? (f[1] as num).toDouble() : 0.0;
      final f2 = f.length > 2 ? (f[2] as num).toDouble() : 0.0;
      final z = (wHtfOiFlow * f0) + (wMicroMomentum * f1) + (wOrderBookImb * f2);
      final pred = (1.0 / (1.0 + math.exp(-z))) >= 0.5 ? 1 : 0;
      if (pred == (labels[i] as int)) correct++;
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

  Future recalibrateFromForeverDb() async {
    try {
      final List allBars = [];
      for (final idx in UnderlyingIndex.values) {
        final bList = await ForeverDatabase.instance
            .getRecentBars(indexName: idx.label, limit: 200);
        allBars.addAll(bList);
      }

      trainedBarCount = allBars.length;
      if (30 > allBars.length) {
        oosSampleCount = 0;
        validationWinRate = 50.0;
        modelVersion = _computeVersionHash();
        lastRecalibrationNote =
            'Insufficient data (N=0, need $minOosTradesRequired OOS trades) • Rules-only active';
        return;
      }

      allBars.sort((a, b) => (a as OneMinEnrichedBar)
          .timestampMs
          .compareTo((b as OneMinEnrichedBar).timestampMs));
      final splitIdx = (allBars.length * 0.60).floor();
      const embargoBars = 3;

      final List oosFeatures = [];
      final List oosLabels = [];
      for (int i = splitIdx + embargoBars; allBars.length - 3 > i; i++) {
        final b = allBars[i] as OneMinEnrichedBar;
        final prevB = allBars[i - 3] as OneMinEnrichedBar;
        if (0 >= b.close || 0 >= prevB.close) continue;

        int label = 0;
        for (int k = 1; 3 >= k; k++) {
          final fut = allBars[i + k] as OneMinEnrichedBar;
          final netRet = ((fut.close - b.close) / b.close) - 0.012;
          if (-0.06 >= netRet) {
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
      oosSampleCount = ((oosMetrics['n'] ?? 0) as num).round();
      validationWinRate = ((oosMetrics['accuracyPct'] ?? 50.0) as num).toDouble();
      oosCiLower = ((oosMetrics['ciLow'] ?? 0.0) as num).toDouble();
      oosCiUpper = ((oosMetrics['ciHigh'] ?? 100.0) as num).toDouble();
      passedEvaluationGate = oosSampleCount >= 300 && oosCiLower > 52.0;

      lastCalibrationMs = DateTime.now().millisecondsSinceEpoch;
      modelVersion = _computeVersionHash();

      if (minOosTradesRequired > oosSampleCount) {
        lastRecalibrationNote =
            'Insufficient data (N=$oosSampleCount, need $minOosTradesRequired OOS) • Raw OOS: ${validationWinRate.toStringAsFixed(1)}%';
      } else {
        lastRecalibrationNote =
            'OOS Accuracy: ${validationWinRate.toStringAsFixed(1)}% (N=$oosSampleCount)';
      }
    } catch (e) {
      _logEngineError('recalibrateFromForeverDb', e);
    }
  }
}
