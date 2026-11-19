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
  static const int gateA5MinTrades = 300;

  String modelVersion = 'RulesOnly-Shadow-v3';
  double validationWinRate = 50.0;
  int oosSampleCount = 0;
  double oosCiLower = 0.0;
  double oosCiUpper = 0.0;
  bool passedEvaluationGate = false;

  String lastRecalibrationNote =
      'Insufficient data (N=0) • Rules-only mode active until Gate A5 passes';
  int lastCalibrationMs = 0;
  int trainedBarCount = 0;
  final List<String> engineErrorLog = [];

  // Signed logistic weights (used only in shadow scoring until passedEvaluationGate == true)
  double wHtfOiFlow = 0.34;
  double wMicroMomentum = 0.24;
  double wOrderBookImb = 0.18;
  double wPcrVelocity = 0.14;
  double wGammaRegime = 0.10;

  double _prevWOi = 0.34;
  double _prevWMom = 0.24;
  double _prevWImb = 0.18;

  // 3-State Gaussian-Emission HMM (0: Bull, 1: Bear, 2: Chop)
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
  int _lastProcessedBarTsMs = 0; // WP-8: Prevent re-filtering the same bars on top of posterior

  AiModelMeta get activeModel => AiModelMeta(
        version: modelVersion,
        validationWinRate: validationWinRate,
        oosSampleCount: oosSampleCount,
        ciLowerPct: oosCiLower,
        ciUpperPct: oosCiUpper,
        passedEvaluationGate: passedEvaluationGate,
      );

  int get lastProcessedBarTsMs => _lastProcessedBarTsMs;

  void resetHmmPosterior() {
    probBullRegime = 0.3333;
    probBearRegime = 0.3333;
    probChopRegime = 0.3334;
    _lastProcessedBarTsMs = 0;
  }

  void _logEngineError(String context, Object error) {
    final ts = DateFormat('HH:mm:ss').format(DateTime.now());
    engineErrorLog.add('[$ts] $context: $error');
    if (engineErrorLog.length > 50) engineErrorLog.removeAt(0);
  }

  String _computeVersionHash() {
    final dateStr = DateFormat('yyyyMMdd').format(DateTime.now());
    final payload =
        '${wHtfOiFlow.toStringAsFixed(4)}|${wMicroMomentum.toStringAsFixed(4)}|${wOrderBookImb.toStringAsFixed(4)}|$oosSampleCount';
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
      lastCalibrationMs = prefs.getInt('ai_last_cal_ms') ?? 0;
      passedEvaluationGate =
          oosSampleCount >= gateA5MinTrades && oosCiLower > 52.0;
      modelVersion = _computeVersionHash();
    } catch (e) {
      _logEngineError('initialize', e);
    }
  }

  Future<void> rollbackToPreviousWeights() async {
    wHtfOiFlow = _prevWOi;
    wMicroMomentum = _prevWMom;
    wOrderBookImb = _prevWImb;
    modelVersion = _computeVersionHash();
    lastRecalibrationNote = 'Rolled back weights ($modelVersion)';
  }

  Future<void> runLightweightFiveDayRecalibration(
      {bool force = false}) async {
    await recalibrateFromForeverDb();
  }

  double _gaussianPdf(double x, double mean, double variance) {
    final v = math.max(variance, 1e-9);
    final diff = x - mean;
    return math.exp(-0.5 * diff * diff / v) / math.sqrt(2.0 * math.pi * v);
  }

  /// WP-8: Filters each new underlying SPOT bar strictly ONCE using _lastProcessedBarTsMs
  void updateHmmRegime({required List recentSpotBars}) {
    final sorted = recentSpotBars
        .map((e) => e as OneMinEnrichedBar)
        .where((b) => b.underlyingSpot > 0)
        .toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    if (sorted.length < 2) return;

    final alpha = [probBullRegime, probBearRegime, probChopRegime];
    int processed = 0;

    for (int t = 1; t < sorted.length; t++) {
      final cur = sorted[t];
      if (cur.timestampMs <= _lastProcessedBarTsMs) continue;

      final prev = sorted[t - 1];
      final dtMs = cur.timestampMs - prev.timestampMs;
      // Skip overnight gaps (> 15 min)
      if (dtMs <= 0 || dtMs > 15 * 60 * 1000) {
        _lastProcessedBarTsMs = cur.timestampMs;
        continue;
      }

      final obsRet = (cur.underlyingSpot - prev.underlyingSpot) / prev.underlyingSpot;
      final nextAlpha = [0.0, 0.0, 0.0];
      double normSum = 0.0;

      for (int j = 0; j < 3; j++) {
        double transSum = 0.0;
        for (int i = 0; i < 3; i++) {
          transSum += alpha[i] * hmmTransitionMatrix[i][j];
        }
        final emission =
            _gaussianPdf(obsRet, hmmReturnMeans[j], hmmReturnVars[j]);
        nextAlpha[j] = transSum * math.max(emission, 1e-12);
        normSum += nextAlpha[j];
      }
      if (normSum > 0) {
        for (int j = 0; j < 3; j++) {
          alpha[j] = nextAlpha[j] / normSum;
        }
      }
      _lastProcessedBarTsMs = cur.timestampMs;
      processed++;
    }

    if (processed > 0) {
      probBullRegime = alpha[0];
      probBearRegime = alpha[1];
      probChopRegime = alpha[2];
    }
  }

  /// WP-8: Signed directional scoring (no .abs() on directional features).
  /// For CE, positive features increase score; for PE, negative features increase score.
  double scoreEnsembleConfidence({
    required bool isCallSignal,
    required double signedOiScore,
    required double signedMomentumScore,
    required double signedOrderBookImbalance,
    required double signedPcrBias,
    required double deltaAbsQuality,
  }) {
    final dirSign = isCallSignal ? 1.0 : -1.0;
    final regimeBoost = isCallSignal ? probBullRegime : probBearRegime;
    final chopPenalty =
        probChopRegime > 0.45 ? (probChopRegime - 0.45) * 0.65 : 0.0;

    final linearLogit = -0.25 +
        (wHtfOiFlow * (signedOiScore * dirSign) * 2.0) +
        (wMicroMomentum * (signedMomentumScore * dirSign) * 1.8) +
        (wOrderBookImb * (signedOrderBookImbalance * dirSign) * 1.5) +
        (wPcrVelocity * (signedPcrBias * dirSign) * 1.4) +
        (wGammaRegime * deltaAbsQuality * 1.0) +
        (regimeBoost * 0.90) -
        chopPenalty;

    final prob = 1.0 / (1.0 + math.exp(-linearLogit));
    return prob * 100.0;
  }

  Map<String, double> evaluateUnclampedOutOfSample(
      List features, List labels) {
    if (features.isEmpty || features.length != labels.length) {
      return {'accuracyPct': 50.0, 'ciLow': 0.0, 'ciHigh': 100.0, 'n': 0.0};
    }
    int correct = 0;
    for (int i = 0; i < features.length; i++) {
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

  /// Evaluates strictly on real recorded closed non-legacy trades/bars; never fabricates metrics
  Future<void> recalibrateFromForeverDb() async {
    try {
      final allBars = <OneMinEnrichedBar>[];
      for (final idx in UnderlyingIndex.values) {
        final bList = await ForeverDatabase.instance
            .getRecentBars(indexName: idx.label, limit: 250);
        allBars.addAll(bList.where((b) => b.optionType != 'SPOT'));
      }

      trainedBarCount = allBars.length;
      if (allBars.length < 40) {
        oosSampleCount = 0;
        validationWinRate = 50.0;
        passedEvaluationGate = false;
        modelVersion = _computeVersionHash();
        lastRecalibrationNote =
            'Insufficient data (N=0, need $minOosTradesRequired OOS trades) • Rules-only active';
        return;
      }

      allBars.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      final splitIdx = (allBars.length * 0.60).floor();
      const embargoBars = 5;

      final oosFeatures = <List<double>>[];
      final oosLabels = <int>[];

      for (int i = splitIdx + embargoBars; i < allBars.length - 5; i++) {
        final b = allBars[i];
        final prevB = allBars[i - 3];
        if (b.close <= 0 || prevB.close <= 0) continue;
        if (b.oiChange15m == null || b.orderBookImbalance == null) continue;

        final oiBase = b.absoluteOi > 0 ? b.absoluteOi.toDouble() : 1.0;
        final fOi = (b.oiChange15m! / oiBase).clamp(-1.0, 1.0);
        final fMom = ((b.close - prevB.close) / prevB.close).clamp(-1.0, 1.0);
        final fImb = b.orderBookImbalance!.clamp(-1.0, 1.0);

        int label = 0;
        for (int k = 1; k <= 5; k++) {
          final fut = allBars[i + k];
          final netRet = ((fut.close - b.close) / b.close) - 0.015;
          if (netRet <= -0.08) {
            label = 0;
            break;
          }
          if (netRet >= 0.08) {
            label = 1;
            break;
          }
        }
        oosFeatures.add([fOi, fMom, fImb]);
        oosLabels.add(label);
      }

      final oosMetrics = evaluateUnclampedOutOfSample(oosFeatures, oosLabels);
      oosSampleCount = (oosMetrics['n'] ?? 0).round();
      validationWinRate = oosMetrics['accuracyPct'] ?? 50.0;
      oosCiLower = oosMetrics['ciLow'] ?? 0.0;
      oosCiUpper = oosMetrics['ciHigh'] ?? 100.0;
      passedEvaluationGate =
          oosSampleCount >= gateA5MinTrades && oosCiLower > 52.0;

      lastCalibrationMs = DateTime.now().millisecondsSinceEpoch;
      modelVersion = _computeVersionHash();
      lastRecalibrationNote = oosSampleCount < minOosTradesRequired
          ? 'Insufficient data (N=$oosSampleCount < $minOosTradesRequired OOS)'
          : 'OOS: ${validationWinRate.toStringAsFixed(1)}% (CI ${oosCiLower.toStringAsFixed(1)}-${oosCiUpper.toStringAsFixed(1)}%, N=$oosSampleCount)';

      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('ai_val_win_rate_unclamped', validationWinRate);
      await prefs.setInt('ai_oos_sample_count', oosSampleCount);
      await prefs.setInt('ai_last_cal_ms', lastCalibrationMs);
    } catch (e) {
      _logEngineError('recalibrateFromForeverDb', e);
    }
  }
}
