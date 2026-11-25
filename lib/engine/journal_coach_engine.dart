import '../core/models.dart';

class DailyPnlBucket {
  final String dateKey; // YYYY-MM-DD (IST)
  final double netPnlInr;
  final int tradeCount;
  final int wins;

  const DailyPnlBucket({
    required this.dateKey,
    required this.netPnlInr,
    required this.tradeCount,
    required this.wins,
  });
}

class JournalCoachSummary {
  final int totalClosedTrades;
  final int greenDays;
  final int redDays;
  final int currentStreakDays; // +N green streak, -N red streak
  final int bestGreenStreakDays;
  final double totalNetPnlInr;
  final String bestTimeSlot;
  final String worstTimeSlot;
  final List<DailyPnlBucket> dailyBuckets;
  final List<String> coachingNotes;

  const JournalCoachSummary({
    required this.totalClosedTrades,
    required this.greenDays,
    required this.redDays,
    required this.currentStreakDays,
    required this.bestGreenStreakDays,
    required this.totalNetPnlInr,
    required this.bestTimeSlot,
    required this.worstTimeSlot,
    required this.dailyBuckets,
    required this.coachingNotes,
  });

  static const empty = JournalCoachSummary(
    totalClosedTrades: 0,
    greenDays: 0,
    redDays: 0,
    currentStreakDays: 0,
    bestGreenStreakDays: 0,
    totalNetPnlInr: 0.0,
    bestTimeSlot: 'N/A',
    worstTimeSlot: 'N/A',
    dailyBuckets: [],
    coachingNotes: ['Complete paper trades to unlock Sadhu AI Journal Coach insights.'],
  );
}

class JournalCoachEngine {
  static String _slotForIstHourMin(int h, int m) {
    final mins = h * 60 + m;
    if (mins < 600) return '09:15-10:00 (Open)';
    if (mins < 690) return '10:00-11:30 (Trend)';
    if (mins < 810) return '11:30-13:30 (Midday)';
    return '13:30-15:15 (Close)';
  }

  static JournalCoachSummary analyze(List<PositionRecord> positions) {
    final closed = positions.where((p) => !p.isOpen).toList()
      ..sort((a, b) => (a.closedAtMs ?? 0).compareTo(b.closedAtMs ?? 0));

    if (closed.isEmpty) return JournalCoachSummary.empty;

    final byDayPnl = <String, double>{};
    final byDayCnt = <String, int>{};
    final byDayWin = <String, int>{};
    final bySlotPnl = <String, double>{};
    double totalNet = 0.0;
    int maxTradesInOneDay = 0;

    for (final p in closed) {
      final ts = p.closedAtMs ?? DateTime.now().millisecondsSinceEpoch;
      final ist = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)
          .add(const Duration(hours: 5, minutes: 30));
      final dayKey =
          '${ist.year}-${ist.month.toString().padLeft(2, "0")}-${ist.day.toString().padLeft(2, "0")}';
      final pnl = p.realizedPnl;
      totalNet += pnl;

      byDayPnl[dayKey] = (byDayPnl[dayKey] ?? 0.0) + pnl;
      byDayCnt[dayKey] = (byDayCnt[dayKey] ?? 0) + 1;
      if (pnl > 0) byDayWin[dayKey] = (byDayWin[dayKey] ?? 0) + 1;
      if (byDayCnt[dayKey]! > maxTradesInOneDay) {
        maxTradesInOneDay = byDayCnt[dayKey]!;
      }

      final slot = _slotForIstHourMin(ist.hour, ist.minute);
      bySlotPnl[slot] = (bySlotPnl[slot] ?? 0.0) + pnl;
    }

    final sortedDays = byDayPnl.keys.toList()..sort();
    final buckets = <DailyPnlBucket>[];
    int greenDays = 0, redDays = 0;
    int curGreen = 0, bestGreen = 0;

    for (final k in sortedDays) {
      final pnl = byDayPnl[k]!;
      buckets.add(DailyPnlBucket(
        dateKey: k,
        netPnlInr: pnl,
        tradeCount: byDayCnt[k] ?? 0,
        wins: byDayWin[k] ?? 0,
      ));
      if (pnl >= 0) {
        greenDays++;
        curGreen++;
        if (curGreen > bestGreen) bestGreen = curGreen;
      } else {
        redDays++;
        curGreen = 0;
      }
    }

    // Current trailing streak (+ for consecutive green days, - for red)
    int streak = 0;
    if (buckets.isNotEmpty) {
      final lastPos = buckets.last.netPnlInr >= 0;
      for (int i = buckets.length - 1; i >= 0; i--) {
        final isPos = buckets[i].netPnlInr >= 0;
        if (isPos == lastPos) {
          streak += lastPos ? 1 : -1;
        } else {
          break;
        }
      }
    }

    String bestSlot = 'N/A', worstSlot = 'N/A';
    if (bySlotPnl.isNotEmpty) {
      final entries = bySlotPnl.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      bestSlot =
          '${entries.first.key} (${entries.first.value >= 0 ? "+" : ""}₹${entries.first.value.toStringAsFixed(0)})';
      worstSlot =
          '${entries.last.key} (${entries.last.value >= 0 ? "+" : ""}₹${entries.last.value.toStringAsFixed(0)})';
    }

    final notes = <String>[];
    if (maxTradesInOneDay > 6) {
      notes.add('Overtrading Alert: Max $maxTradesInOneDay trades/day detected. Cap at 4-5 high-conviction setups.');
    }
    if (streak <= -2) {
      notes.add('Drawdown Discipline: ${streak.abs()} consecutive red days. Reduce size until calibrated edge recovers.');
    } else if (streak >= 3) {
      notes.add('Strong Consistency: $streak-day green streak. Keep risk fixed — avoid size creep.');
    }
    if (bySlotPnl.isNotEmpty) {
      notes.add('Best Window: $bestSlot | Weakest Window: $worstSlot');
    }
    if (notes.isEmpty) {
      notes.add('Tracking ${closed.length} real closed trades across ${buckets.length} active days.');
    }

    return JournalCoachSummary(
      totalClosedTrades: closed.length,
      greenDays: greenDays,
      redDays: redDays,
      currentStreakDays: streak,
      bestGreenStreakDays: bestGreen,
      totalNetPnlInr: totalNet,
      bestTimeSlot: bestSlot,
      worstTimeSlot: worstSlot,
      dailyBuckets: buckets,
      coachingNotes: notes,
    );
  }
}
