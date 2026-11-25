import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class BoostedStump {
  final int featureIndex;
  final double threshold;
  final int polarity; // +1 if x >= threshold predicts positive, else -1
  final double weight;

  const BoostedStump({
    required this.featureIndex,
    required this.threshold,
    required this.polarity,
    required this.weight,
  });

  double predictMargin(List<double> x) {
    if (featureIndex < 0 || featureIndex >= x.length) return 0.0;
    final pred = (x[featureIndex] >= threshold ? 1 : -1) * polarity;
    return pred * weight;
  }

  Map<String, dynamic> toJson() => {
        'f': featureIndex,
        't': threshold,
        'p': polarity,
        'w': weight,
      };

  factory BoostedStump.fromJson(Map<String, dynamic> m) => BoostedStump(
        featureIndex: (m['f'] as num).toInt(),
        threshold: (m['t'] as num).toDouble(),
        polarity: (m['p'] as num).toInt(),
        weight: (m['w'] as num).toDouble(),
      );
}

class SadhuMlPrediction {
  final bool isTrained;
  final double calibratedProb; // 0..1 calibrated via Platt scaling
  final double rawMargin;
  final String statusNote;

  const SadhuMlPrediction({
    required this.isTrained,
    required this.calibratedProb,
    required this.rawMargin,
    required this.statusNote,
  });
}

class SadhuMlTrainingReport {
  final bool trained;
  final int trainSamples;
  final int calSamples;
  final int oosSamples;
  final double oosAccuracyPct;
  final double oosBrierScore;
  final int stumpCount;
  final String trainedAtIso;
  final String note;

  const SadhuMlTrainingReport({
    required this.trained,
    required this.trainSamples,
    required this.calSamples,
    required this.oosSamples,
    required this.oosAccuracyPct,
    required this.oosBrierScore,
    required this.stumpCount,
    required this.trainedAtIso,
    required this.note,
  });

  static const untrained = SadhuMlTrainingReport(
    trained: false,
    trainSamples: 0,
    calSamples: 0,
    oosSamples: 0,
    oosAccuracyPct: 0.0,
    oosBrierScore: 0.25,
    stumpCount: 0,
    trainedAtIso: '',
    note: 'UNTRAINED — Collecting real per-contract bars (min 40 non-overlapping samples).',
  );
}

/// Sadhu AI Trainable ML Engine: Boosted Decision Stumps + Purged Embargo Split + Platt Calibration
class SadhuMlEngine {
  static final SadhuMlEngine instance = SadhuMlEngine._();
  SadhuMlEngine._();

  static const int minTotalSamples = 40;
  static const int embargoGap = 5;

  List<BoostedStump> _stumps = [];
  double _plattA = 1.0;
  double _plattB = 0.0;
  SadhuMlTrainingReport lastReport = SadhuMlTrainingReport.untrained;

  bool get isTrained => _stumps.isNotEmpty && lastReport.trained;

  static double _sigmoid(double z) {
    final c = z.clamp(-25.0, 25.0).toDouble();
    return 1.0 / (1.0 + math.exp(-c));
  }

  double _rawScore(List<double> features) {
    double s = 0.0;
    for (final st in _stumps) {
      s += st.predictMargin(features);
    }
    return s;
  }

  /// Stateless inference (safe to call inside backtests without mutating global state)
  SadhuMlPrediction predict(List<double> features) {
    if (!isTrained) {
      return const SadhuMlPrediction(
        isTrained: false,
        calibratedProb: 0.50,
        rawMargin: 0.0,
        statusNote: 'Sadhu ML Untrained — waiting for real dataset.',
      );
    }
    final margin = _rawScore(features);
    final prob = _sigmoid(_plattA * margin + _plattB);
    return SadhuMlPrediction(
      isTrained: true,
      calibratedProb: prob,
      rawMargin: margin,
      statusNote:
          'Sadhu ML (${_stumps.length} stumps • Brier ${lastReport.oosBrierScore.toStringAsFixed(3)})',
    );
  }

  /// Trains boosted stumps chronologically with purged embargo + Platt calibration
  SadhuMlTrainingReport trainOnRealDataset({
    required List<List<double>> features,
    required List<int> labels, // 1 = positive target hit, 0 = otherwise
    int maxRounds = 24,
    double shrinkage = 0.35,
  }) {
    final n = math.min(features.length, labels.length);
    if (n < minTotalSamples) {
      lastReport = SadhuMlTrainingReport(
        trained: false,
        trainSamples: 0,
        calSamples: 0,
        oosSamples: 0,
        oosAccuracyPct: 0.0,
        oosBrierScore: 0.25,
        stumpCount: 0,
        trainedAtIso: '',
        note: 'Need $minTotalSamples real samples to train Sadhu ML (have $n).',
      );
      return lastReport;
    }

    final trainEnd = (n * 0.65).floor();
    final calStart = math.min(n - 10, trainEnd + embargoGap);
    final calEnd = math.min(n - 5, calStart + ((n - calStart) * 0.5).floor());
    final oosStart = math.min(n - 2, calEnd + embargoGap);

    if (trainEnd < 20 || calEnd <= calStart + 3 || oosStart >= n - 1) {
      lastReport = SadhuMlTrainingReport.untrained;
      return lastReport;
    }

    final xTrain = features.sublist(0, trainEnd);
    final yTrain = labels.sublist(0, trainEnd);
    final xCal = features.sublist(calStart, calEnd);
    final yCal = labels.sublist(calStart, calEnd);
    final xOos = features.sublist(oosStart, n);
    final yOos = labels.sublist(oosStart, n);

    final numFeat = xTrain.first.length;
    final sampleW = List<double>.filled(xTrain.length, 1.0 / xTrain.length);
    final learned = <BoostedStump>[];

    for (int round = 0; round < maxRounds; round++) {
      int bestFeat = 0;
      double bestThresh = 0.0;
      int bestPol = 1;
      double bestErr = 1.0;

      for (int f = 0; f < numFeat; f++) {
        final colVals = xTrain.map((r) => r[f]).toList()..sort();
        // Evaluate quantile candidate thresholds for fast on-device training
        for (int q = 1; q <= 9; q++) {
          final idx = ((colVals.length - 1) * (q / 10.0)).round();
          final thr = colVals[idx];

          for (final pol in [1, -1]) {
            double err = 0.0;
            for (int i = 0; i < xTrain.length; i++) {
              final pred = ((xTrain[i][f] >= thr ? 1 : -1) * pol) > 0 ? 1 : 0;
              if (pred != yTrain[i]) err += sampleW[i];
            }
            if (err < bestErr) {
              bestErr = err;
              bestFeat = f;
              bestThresh = thr;
              bestPol = pol;
            }
          }
        }
      }

      if (bestErr >= 0.495) break;
      final clippedErr = bestErr.clamp(1e-5, 0.495).toDouble();
      final alpha = shrinkage * 0.5 * math.log((1.0 - clippedErr) / clippedErr);

      final stump = BoostedStump(
        featureIndex: bestFeat,
        threshold: bestThresh,
        polarity: bestPol,
        weight: alpha,
      );
      learned.add(stump);

      double wSum = 0.0;
      for (int i = 0; i < xTrain.length; i++) {
        final ySigned = yTrain[i] == 1 ? 1.0 : -1.0;
        final predSigned = ((xTrain[i][bestFeat] >= bestThresh ? 1 : -1) * bestPol).toDouble();
        sampleW[i] *= math.exp(-alpha * ySigned * predSigned);
        wSum += sampleW[i];
      }
      if (wSum > 0) {
        for (int i = 0; i < sampleW.length; i++) {
          sampleW[i] /= wSum;
        }
      }
    }

    if (learned.isEmpty) {
      lastReport = SadhuMlTrainingReport.untrained;
      return lastReport;
    }

    _stumps = learned;

    // Platt scaling calibration on held-out calibration window via L2-regularized GD
    double a = 1.0, b = 0.0;
    final calMargins = xCal.map(_rawScore).toList();
    const lr = 0.08;
    const l2 = 0.02;
    for (int ep = 0; ep < 80; ep++) {
      double gA = 0.0, gB = 0.0;
      for (int i = 0; i < calMargins.length; i++) {
        final p = _sigmoid(a * calMargins[i] + b);
        final diff = p - yCal[i].toDouble();
        gA += diff * calMargins[i];
        gB += diff;
      }
      a -= lr * ((gA / calMargins.length) + l2 * a);
      b -= lr * ((gB / calMargins.length) + l2 * b);
    }
    _plattA = a.clamp(0.1, 5.0).toDouble();
    _plattB = b.clamp(-3.0, 3.0).toDouble();

    // Unclamped OOS Evaluation (Accuracy + Brier Score)
    int correct = 0;
    double brierSum = 0.0;
    for (int i = 0; i < xOos.length; i++) {
      final p = _sigmoid(_plattA * _rawScore(xOos[i]) + _plattB);
      final pred = p >= 0.5 ? 1 : 0;
      if (pred == yOos[i]) correct++;
      final d = p - yOos[i].toDouble();
      brierSum += d * d;
    }

    final accPct = (correct / xOos.length) * 100.0;
    final brier = brierSum / xOos.length;
    final nowIso = DateTime.now().toUtc().toIso8601String();

    lastReport = SadhuMlTrainingReport(
      trained: true,
      trainSamples: xTrain.length,
      calSamples: xCal.length,
      oosSamples: xOos.length,
      oosAccuracyPct: accPct,
      oosBrierScore: brier,
      stumpCount: _stumps.length,
      trainedAtIso: nowIso,
      note:
          'Trained ${_stumps.length} stumps | OOS ${accPct.toStringAsFixed(1)}% | Brier ${brier.toStringAsFixed(3)}',
    );
    return lastReport;
  }

  Future<void> saveModelToDisk() async {
    if (!isTrained) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(join(dir.path, 'sadhu_ml_model_v1.json'));
      await f.writeAsString(jsonEncode({
        'plattA': _plattA,
        'plattB': _plattB,
        'stumps': _stumps.map((s) => s.toJson()).toList(),
        'oosAcc': lastReport.oosAccuracyPct,
        'brier': lastReport.oosBrierScore,
        'trainN': lastReport.trainSamples,
        'calN': lastReport.calSamples,
        'oosN': lastReport.oosSamples,
        'trainedAt': lastReport.trainedAtIso,
      }));
    } catch (_) {}
  }

  Future<bool> loadModelFromDisk() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(join(dir.path, 'sadhu_ml_model_v1.json'));
      if (!await f.exists()) return false;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final rawStumps = m['stumps'] as List? ?? [];
      if (rawStumps.isEmpty) return false;
      _stumps = rawStumps
          .map((e) => BoostedStump.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      _plattA = ((m['plattA'] ?? 1.0) as num).toDouble();
      _plattB = ((m['plattB'] ?? 0.0) as num).toDouble();
      final acc = ((m['oosAcc'] ?? 0.0) as num).toDouble();
      final brier = ((m['brier'] ?? 0.25) as num).toDouble();
      lastReport = SadhuMlTrainingReport(
        trained: true,
        trainSamples: ((m['trainN'] ?? 0) as num).toInt(),
        calSamples: ((m['calN'] ?? 0) as num).toInt(),
        oosSamples: ((m['oosN'] ?? 0) as num).toInt(),
        oosAccuracyPct: acc,
        oosBrierScore: brier,
        stumpCount: _stumps.length,
        trainedAtIso: (m['trainedAt'] ?? '').toString(),
        note: 'Loaded Sadhu ML (${_stumps.length} stumps • Brier ${brier.toStringAsFixed(3)})',
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
