import '../core/models.dart';
import '../data/forever_db.dart';

class LedgerAuditReport {
  final double startingCapitalInr;
  final double realizedNetPnlInr;
  final double openCostBasisInr;
  final double? openUnrealizedPnlInr; // Null if any open position has unmeasured/stale quote
  final double expectedAvailableCashInr;
  final double? expectedNavInr;
  final double discrepancyInr;
  final bool isReconciled;
  final int filledOrdersCount;
  final int partialOrdersCount;
  final int closedTradesCount;
  final int openPositionsCount;
  final double peakEquityInr;
  final double maxDrawdownInr;
  final double ongoingDrawdownInr;
  final double ongoingDrawdownPct;
  final double ongoingEpisodeHours;
  final List<String> warnings;
  final int auditedAtMs;

  const LedgerAuditReport({
    required this.startingCapitalInr,
    required this.realizedNetPnlInr,
    required this.openCostBasisInr,
    required this.openUnrealizedPnlInr,
    required this.expectedAvailableCashInr,
    required this.expectedNavInr,
    required this.discrepancyInr,
    required this.isReconciled,
    required this.filledOrdersCount,
    required this.partialOrdersCount,
    required this.closedTradesCount,
    required this.openPositionsCount,
    required this.peakEquityInr,
    required this.maxDrawdownInr,
    required this.ongoingDrawdownInr,
    required this.ongoingDrawdownPct,
    required this.ongoingEpisodeHours,
    required this.warnings,
    required this.auditedAtMs,
  });
}

class LedgerReconciler {
  /// Independently replays recorded non-legacy orders & positions from SQLite to verify
  /// cash, margin, realized P&L, NAV arithmetic, and ongoing drawdown episode depth.
  static Future<LedgerAuditReport> reconcileFromDb({
    required double startingCapitalInr,
    required Map<String, double> liveLtpBySecurityId,
    required bool isFeedLive,
  }) async {
    final orders = await ForeverDatabase.instance.getRecentOrders(limit: 500);
    final positions = await ForeverDatabase.instance.getAllPositions();
    return reconcileSnapshots(
      startingCapitalInr: startingCapitalInr,
      orders: orders,
      positions: positions,
      liveLtpBySecurityId: liveLtpBySecurityId,
      isFeedLive: isFeedLive,
    );
  }

  static LedgerAuditReport reconcileSnapshots({
    required double startingCapitalInr,
    required List<TradeOrder> orders,
    required List<PositionRecord> positions,
    required Map<String, double> liveLtpBySecurityId,
    required bool isFeedLive,
    int? nowMsOverride,
  }) {
    final nowMs = nowMsOverride ?? DateTime.now().millisecondsSinceEpoch;
    final cleanOrders = orders.where((o) => !o.legacyUnverified).toList();
    final cleanPositions =
        positions.where((p) => !p.legacyUnverified).toList();

    int filledCount = 0;
    int partialCount = 0;
    double buyFilledQtySum = 0;
    double sellFilledQtySum = 0;

    for (final o in cleanOrders) {
      final st = o.lifecycleState;
      if (st == OrderLifecycleState.filled) filledCount++;
      if (st == OrderLifecycleState.partial) partialCount++;
      if (o.filledQty > 0) {
        if (o.side.toUpperCase() == 'BUY') {
          buyFilledQtySum += o.filledQty;
        } else {
          sellFilledQtySum += o.filledQty;
        }
      }
    }

    final closedPos = cleanPositions.where((p) => !p.isOpen).toList()
      ..sort((a, b) => (a.closedAtMs ?? a.openedAtMs)
          .compareTo(b.closedAtMs ?? b.openedAtMs));
    final openPos = cleanPositions.where((p) => p.isOpen).toList();

    double realizedNetPnl = 0.0;
    double runningEq = startingCapitalInr;
    double peakEq = startingCapitalInr;
    int peakTsMs = nowMs;
    double maxDd = 0.0;

    for (final p in closedPos) {
      realizedNetPnl += p.realizedPnl;
      runningEq += p.realizedPnl;
      if (runningEq >= peakEq) {
        peakEq = runningEq;
        peakTsMs = p.closedAtMs ?? p.openedAtMs;
      } else {
        final dd = peakEq - runningEq;
        if (dd > maxDd) maxDd = dd;
      }
    }

    double openCostBasis = 0.0;
    double openQtySum = 0.0;
    double? openUnrealized = 0.0;
    final warnings = <String>[];

    for (final p in openPos) {
      openCostBasis += p.avgEntryPrice * p.quantity;
      openQtySum += p.quantity;
      final liveLtp = liveLtpBySecurityId[p.securityId];
      if (!isFeedLive || liveLtp == null || liveLtp <= 0) {
        // Keep unmeasured P&L strictly null (N/A) instead of zero
        openUnrealized = null;
      } else if (openUnrealized != null) {
        openUnrealized += (liveLtp - p.avgEntryPrice) * p.quantity;
      }
    }

    // Cross-check net open quantity against order fills
    final expectedOpenQty = buyFilledQtySum - sellFilledQtySum;
    final qtyDiscrepancy = (expectedOpenQty - openQtySum).abs();
    if (qtyDiscrepancy > 0.01 && cleanOrders.isNotEmpty) {
      warnings.add(
          'Qty mismatch: Order fills imply ${expectedOpenQty.toStringAsFixed(0)} open qty vs ${openQtySum.toStringAsFixed(0)} in positions table.');
    }
    if (openPos.isNotEmpty && openUnrealized == null) {
      warnings.add(
          'Unmeasured P&L: Live quote unavailable for open position(s); NAV held as N/A.');
    }

    final expectedCash = startingCapitalInr + realizedNetPnl - openCostBasis;
    final double? expectedNav = openUnrealized != null
        ? (startingCapitalInr + realizedNetPnl + openUnrealized)
        : null;

    // Ongoing Drawdown Episode Depth (realized + measured unrealized)
    final currentEqForDd = expectedNav ?? (startingCapitalInr + realizedNetPnl);
    final ongoingDdInr =
        peakEq > currentEqForDd ? (peakEq - currentEqForDd) : 0.0;
    final ongoingDdPct =
        peakEq > 0 ? (ongoingDdInr / peakEq) * 100.0 : 0.0;
    final episodeHours = ongoingDdInr > 0 && nowMs > peakTsMs
        ? (nowMs - peakTsMs) / 3600000.0
        : 0.0;

    return LedgerAuditReport(
      startingCapitalInr: startingCapitalInr,
      realizedNetPnlInr: realizedNetPnl,
      openCostBasisInr: openCostBasis,
      openUnrealizedPnlInr: openUnrealized,
      expectedAvailableCashInr: expectedCash,
      expectedNavInr: expectedNav,
      discrepancyInr: qtyDiscrepancy,
      isReconciled: qtyDiscrepancy < 0.01,
      filledOrdersCount: filledCount,
      partialOrdersCount: partialCount,
      closedTradesCount: closedPos.length,
      openPositionsCount: openPos.length,
      peakEquityInr: peakEq,
      maxDrawdownInr: maxDd,
      ongoingDrawdownInr: ongoingDdInr,
      ongoingDrawdownPct: ongoingDdPct,
      ongoingEpisodeHours: episodeHours,
      warnings: warnings,
      auditedAtMs: nowMs,
    );
  }
}
