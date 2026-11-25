import 'dart:isolate';
import 'dart:math' as math;

class MonteCarloReport {
  final int simulations;
  final int tradesPerPath;
  final double startingCapitalInr;
  final double p5EndingEquityInr;
  final double p50EndingEquityInr;
  final double p95EndingEquityInr;
  final double p50MaxDdPct;
  final double p95MaxDdPct;
  final double worstMaxDdPct;
  final double riskOfRuinPct;
  final double profitablePathsPct;
  final bool passesGate;
  final List<int> ddHistogramBuckets;
  final List<List<double>> sampleEquityPaths;
  final List<double> medianEquityPath;

  const MonteCarloReport({
    required this.simulations,
    required this.tradesPerPath,
    required this.startingCapitalInr,
    required this.p5EndingEquityInr,
    required this.p50EndingEquityInr,
    required this.p95EndingEquityInr,
    required this.p50MaxDdPct,
    required this.p95MaxDdPct,
    required this.worstMaxDdPct,
    required this.riskOfRuinPct,
    required this.profitablePathsPct,
    required this.passesGate,
    required this.ddHistogramBuckets,
    required this.sampleEquityPaths,
    required this.medianEquityPath,
  });

  static const empty = MonteCarloReport(
    simulations: 0,
    tradesPerPath: 0,
    startingCapitalInr: 0,
    p5EndingEquityInr: 0,
    p50EndingEquityInr: 0,
    p95EndingEquityInr: 0,
    p50MaxDdPct: 0,
    p95MaxDdPct: 0,
    worstMaxDdPct: 0,
    riskOfRuinPct: 0,
    profitablePathsPct: 0,
    passesGate: false,
    ddHistogramBuckets: [],
    sampleEquityPaths: [],
    medianEquityPath: [],
  );
}

class MonteCarloEngine {
  /// Runs 10,000 bootstrap futures inside a background Isolate so UI never janks
  static Future<MonteCarloReport> runAsync({
    required List<double> tradePnls,
    required double startingCapitalInr,
    int simulations = 10000,
    double ruinDrawdownPct = 20.0,
    double maxAllowedP95DdPct = 15.0,
    int seed = 20261126,
  }) async {
    if (tradePnls.length < 5 || startingCapitalInr <= 0) {
      return MonteCarloReport.empty;
    }
    return Isolate.run(() => runSync(
          tradePnls: tradePnls,
          startingCapitalInr: startingCapitalInr,
          simulations: simulations,
          ruinDrawdownPct: ruinDrawdownPct,
          maxAllowedP95DdPct: maxAllowedP95DdPct,
          seed: seed,
        ));
  }

  static MonteCarloReport runSync({
    required List<double> tradePnls,
    required double startingCapitalInr,
    int simulations = 10000,
    double ruinDrawdownPct = 20.0,
    double maxAllowedP95DdPct = 15.0,
    int seed = 20261126,
  }) {
    final n = tradePnls.length;
    if (n < 5 || startingCapitalInr <= 0 || simulations <= 0) {
      return MonteCarloReport.empty;
    }

    final rng = math.Random(seed);
    final finalEquities = List<double>.filled(simulations, 0.0);
    final maxDds = List<double>.filled(simulations, 0.0);
    final samplePaths = <List<double>>[];
    final sumAtStep = List<double>.filled(n + 1, 0.0);

    int ruinedCount = 0;
    int profitableCount = 0;

    for (int s = 0; s < simulations; s++) {
      double eq = startingCapitalInr;
      double peak = startingCapitalInr;
      double maxDdPct = 0.0;
      final keepPath = s < 24;
      final path = keepPath ? <double>[eq] : null;
      sumAtStep[0] += eq;

      for (int t = 0; t < n; t++) {
        // Bootstrap resampling with replacement
        final pnl = tradePnls[rng.nextInt(n)];
        eq += pnl;
        if (eq > peak) peak = eq;
        final ddPct = peak > 0 ? ((peak - eq) / peak) * 100.0 : 0.0;
        if (ddPct > maxDdPct) maxDdPct = ddPct;
        sumAtStep[t + 1] += eq;
        if (keepPath) path!.add(eq);
      }

      finalEquities[s] = eq;
      maxDds[s] = maxDdPct;
      if (maxDdPct >= ruinDrawdownPct || eq <= 0) ruinedCount++;
      if (eq > startingCapitalInr) profitableCount++;
      if (keepPath) samplePaths.add(path!);
    }

    finalEquities.sort();
    maxDds.sort();

    double pctOf(List<double> sorted, double q) {
      final idx = ((sorted.length - 1) * q).round().clamp(0, sorted.length - 1).toInt();
      return sorted[idx];
    }

    final p5Eq = pctOf(finalEquities, 0.05);
    final p50Eq = pctOf(finalEquities, 0.50);
    final p95Eq = pctOf(finalEquities, 0.95);
    final p50Dd = pctOf(maxDds, 0.50);
    final p95Dd = pctOf(maxDds, 0.95);
    final worstDd = maxDds.last;
    final ruinPct = (ruinedCount / simulations) * 100.0;
    final profPct = (profitableCount / simulations) * 100.0;

    // 10-bucket drawdown histogram
    final buckets = List<int>.filled(10, 0);
    final maxBucketVal = math.max(1.0, worstDd);
    for (final d in maxDds) {
      final b = ((d / maxBucketVal) * 9.999).floor().clamp(0, 9).toInt();
      buckets[b]++;
    }

    final medianPath = List<double>.generate(
      n + 1,
      (i) => sumAtStep[i] / simulations,
    );

    final passes = p95Dd < maxAllowedP95DdPct &&
        ruinPct < 1.0 &&
        p5Eq > startingCapitalInr;

    return MonteCarloReport(
      simulations: simulations,
      tradesPerPath: n,
      startingCapitalInr: startingCapitalInr,
      p5EndingEquityInr: p5Eq,
      p50EndingEquityInr: p50Eq,
      p95EndingEquityInr: p95Eq,
      p50MaxDdPct: p50Dd,
      p95MaxDdPct: p95Dd,
      worstMaxDdPct: worstDd,
      riskOfRuinPct: ruinPct,
      profitablePathsPct: profPct,
      passesGate: passes,
      ddHistogramBuckets: buckets,
      sampleEquityPaths: samplePaths,
      medianEquityPath: medianPath,
    );
  }
}
