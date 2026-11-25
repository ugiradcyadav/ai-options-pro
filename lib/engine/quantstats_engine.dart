import 'dart:math' as math;

class QuantStatsTearSheet {
  final int totalTrades;
  final double totalReturnPct;
  final double sharpeRatio;
  final double sortinoRatio;
  final double calmarRatio;
  final double recoveryFactor;
  final double ulcerIndex;
  final double var95Inr;
  final double avgWinInr;
  final double avgLossInr;
  final double payoffRatio;
  final int maxConsecutiveWins;
  final int maxConsecutiveLosses;
  final Map<String, double> monthlyPnlInr;

  const QuantStatsTearSheet({
    required this.totalTrades,
    required this.totalReturnPct,
    required this.sharpeRatio,
    required this.sortinoRatio,
    required this.calmarRatio,
    required this.recoveryFactor,
    required this.ulcerIndex,
    required this.var95Inr,
    required this.avgWinInr,
    required this.avgLossInr,
    required this.payoffRatio,
    required this.maxConsecutiveWins,
    required this.maxConsecutiveLosses,
    required this.monthlyPnlInr,
  });

  static const empty = QuantStatsTearSheet(
    totalTrades: 0,
    totalReturnPct: 0,
    sharpeRatio: 0,
    sortinoRatio: 0,
    calmarRatio: 0,
    recoveryFactor: 0,
    ulcerIndex: 0,
    var95Inr: 0,
    avgWinInr: 0,
    avgLossInr: 0,
    payoffRatio: 0,
    maxConsecutiveWins: 0,
    maxConsecutiveLosses: 0,
    monthlyPnlInr: {},
  );
}

class QuantStatsEngine {
  /// Computes fund-grade tear-sheet metrics from real trade logs (netPnl + timestamp)
  static QuantStatsTearSheet computeFromTradeLogs({
    required List tradeLogs,
    required double startingCapitalInr,
  }) {
    if (tradeLogs.isEmpty || startingCapitalInr <= 0) {
      return QuantStatsTearSheet.empty;
    }

    final pnls = <double>[];
    final returns = <double>[];
    final monthly = <String, double>{};

    double equity = startingCapitalInr;
    double peak = startingCapitalInr;
    double maxDdInr = 0.0;
    double maxDdPct = 0.0;
    double ddSqSum = 0.0;

    double winSum = 0.0;
    double lossSumAbs = 0.0;
    int winCnt = 0;
    int lossCnt = 0;
    int curW = 0, maxW = 0;
    int curL = 0, maxL = 0;

    for (final raw in tradeLogs) {
      if (raw is! Map) continue;
      final pnl = ((raw['netPnl'] ?? 0) as num).toDouble();
      final tsMs = ((raw['exitTimeMs'] ?? raw['entryTimeMs'] ?? 0) as num).toInt();

      final prevEq = equity > 0 ? equity : startingCapitalInr;
      final r = pnl / prevEq;
      pnls.add(pnl);
      returns.add(r);

      equity += pnl;
      if (equity > peak) peak = equity;
      final ddInr = peak - equity;
      final ddPct = peak > 0 ? (ddInr / peak) * 100.0 : 0.0;
      if (ddInr > maxDdInr) maxDdInr = ddInr;
      if (ddPct > maxDdPct) maxDdPct = ddPct;
      ddSqSum += ddPct * ddPct;

      if (pnl > 0) {
        winSum += pnl;
        winCnt++;
        curW++;
        curL = 0;
        if (curW > maxW) maxW = curW;
      } else if (pnl < 0) {
        lossSumAbs += pnl.abs();
        lossCnt++;
        curL++;
        curW = 0;
        if (curL > maxL) maxL = curL;
      }

      if (tsMs > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true)
            .add(const Duration(hours: 5, minutes: 30));
        final key = '${dt.year}-${dt.month.toString().padLeft(2, "0")}';
        monthly[key] = (monthly[key] ?? 0.0) + pnl;
      }
    }

    if (returns.isEmpty) return QuantStatsTearSheet.empty;

    final n = returns.length;
    final meanR = returns.reduce((a, b) => a + b) / n;

    double varSum = 0.0;
    double downSqSum = 0.0;
    int downCnt = 0;
    for (final r in returns) {
      final d = r - meanR;
      varSum += d * d;
      if (r < 0) {
        downSqSum += r * r;
        downCnt++;
      }
    }

    final stdDev = n > 1 ? math.sqrt(varSum / (n - 1)) : 0.0;
    final downDev = downCnt > 0 ? math.sqrt(downSqSum / n) : 0.0;
    final annScale = math.sqrt(252.0);

    final sharpe = stdDev > 1e-9 ? (meanR / stdDev) * annScale : 0.0;
    final sortino = downDev > 1e-9 ? (meanR / downDev) * annScale : 0.0;

    final netPnl = equity - startingCapitalInr;
    final totalReturnPct = (netPnl / startingCapitalInr) * 100.0;
    final calmar = maxDdPct > 0.01 ? (totalReturnPct / maxDdPct) : 0.0;
    final recovery = maxDdInr > 1.0 ? (netPnl / maxDdInr) : 0.0;
    final ulcer = math.sqrt(ddSqSum / n);

    final sortedPnl = List<double>.from(pnls)..sort();
    final idx5 = ((n * 0.05).floor()).clamp(0, n - 1);
    final var95 = sortedPnl[idx5];

    final avgWin = winCnt > 0 ? winSum / winCnt : 0.0;
    final avgLoss = lossCnt > 0 ? lossSumAbs / lossCnt : 0.0;
    final payoff = avgLoss > 1e-6 ? avgWin / avgLoss : 0.0;

    return QuantStatsTearSheet(
      totalTrades: n,
      totalReturnPct: totalReturnPct,
      sharpeRatio: sharpe,
      sortinoRatio: sortino,
      calmarRatio: calmar,
      recoveryFactor: recovery,
      ulcerIndex: ulcer,
      var95Inr: var95,
      avgWinInr: avgWin,
      avgLossInr: avgLoss,
      payoffRatio: payoff,
      maxConsecutiveWins: maxW,
      maxConsecutiveLosses: maxL,
      monthlyPnlInr: monthly,
    );
  }
}
