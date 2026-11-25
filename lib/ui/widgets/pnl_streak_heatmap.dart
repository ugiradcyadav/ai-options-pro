import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../engine/journal_coach_engine.dart';
import '../theme/quant_theme.dart';

class PnlStreakHeatmapCard extends StatelessWidget {
  final JournalCoachSummary summary;

  const PnlStreakHeatmapCard({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final streak = summary.currentStreakDays;
    final streakColor = streak > 0
        ? QuantTheme.positive
        : (streak < 0 ? QuantTheme.negative : QuantTheme.textSecondary);
    final streakText = streak > 0
        ? '+$streak DAY GREEN'
        : (streak < 0 ? '${streak.abs()} DAY RED' : '0 DAY STREAK');

    // Last 28 trading day cells (4 rows x 7 cols)
    final recent = summary.dailyBuckets.length > 28
        ? summary.dailyBuckets.sublist(summary.dailyBuckets.length - 28)
        : summary.dailyBuckets;
    double maxAbs = 1.0;
    for (final b in recent) {
      maxAbs = math.max(maxAbs, b.netPnlInr.abs());
    }

    return QuantPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sadhu AI Journal Coach & Streak',
                      style: QuantTheme.heading(size: 13)),
                  Text(
                    '${summary.greenDays}W / ${summary.redDays}L days • Best streak: ${summary.bestGreenStreakDays}d',
                    style: QuantTheme.label(size: 10),
                  ),
                ],
              ),
              QuantBadge(text: streakText, color: streakColor),
            ],
          ),
          const SizedBox(height: 12),
          if (recent.isEmpty)
            Text(
              'No closed sessions yet — completed paper/live trades will populate this 28-day P&L heatmap.',
              style: QuantTheme.label(size: 10.5),
            )
          else
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: List.generate(28, (i) {
                final offset = 28 - recent.length;
                if (i < offset) {
                  return Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: QuantTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: QuantTheme.border, width: 0.6),
                    ),
                  );
                }
                final b = recent[i - offset];
                final intensity =
                    (0.30 + 0.70 * (b.netPnlInr.abs() / maxAbs)).clamp(0.3, 1.0);
                final baseCol = b.netPnlInr >= 0
                    ? QuantTheme.positive
                    : QuantTheme.negative;
                return Tooltip(
                  message:
                      '${b.dateKey}: ${b.netPnlInr >= 0 ? "+" : ""}₹${b.netPnlInr.toStringAsFixed(0)} (${b.tradeCount}t)',
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: baseCol.withOpacity(intensity),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                );
              }),
            ),
          const Divider(color: QuantTheme.border, height: 18),
          ...summary.coachingNotes.map((note) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $note',
                    style: QuantTheme.label(
                        size: 10.5, color: QuantTheme.textPrimary)),
              )),
        ],
      ),
    );
  }
}
