import 'dart:math' as math;
import '../core/models.dart';
import 'risk_engine.dart';

class OptionLeg {
  final int strike;
  final bool isCall;
  final bool isLong;
  final double premium;
  final int quantity;

  const OptionLeg({
    required this.strike,
    required this.isCall,
    required this.isLong,
    required this.premium,
    required this.quantity,
  });

  double expiryPayoffAt(double spot) {
    final intrinsic = isCall
        ? math.max(0.0, spot - strike)
        : math.max(0.0, strike - spot);
    final raw = isLong ? (intrinsic - premium) : (premium - intrinsic);
    return raw * quantity;
  }
}

class PayoffComparisonResult {
  final String strategyName;
  final List<OptionLeg> legs;
  final double netDebitInr;
  final double estimatedFrictionInr;
  final double? maxProfitInr; // null = theoretically unlimited
  final double maxLossInr;
  final double? breakevenSpot;
  final double? rewardToRisk;
  final List<Map<String, double>> payoffCurve;

  const PayoffComparisonResult({
    required this.strategyName,
    required this.legs,
    required this.netDebitInr,
    required this.estimatedFrictionInr,
    required this.maxProfitInr,
    required this.maxLossInr,
    required this.breakevenSpot,
    required this.rewardToRisk,
    required this.payoffCurve,
  });
}

class OptionsPayoffEngine {
  /// Evaluates any multi-leg option structure at expiry after real statutory friction (0.15% STT)
  static PayoffComparisonResult evaluateStrategy({
    required String strategyName,
    required List<OptionLeg> legs,
    required double spot,
    required int strikeStep,
  }) {
    double netDebit = 0.0;
    double totalFriction = 0.0;
    int netLongCallQty = 0;

    for (final leg in legs) {
      netDebit += (leg.isLong ? 1.0 : -1.0) * leg.premium * leg.quantity;
      if (leg.isCall) {
        netLongCallQty += leg.isLong ? leg.quantity : -leg.quantity;
      }
      final costs = RiskEngine.computeRoundTripCostsAndSlippage(
        entryPremium: leg.premium,
        exitPremium: leg.premium,
        quantity: leg.quantity,
      );
      totalFriction += costs.totalFrictionInr;
    }

    final minSpot = math.max(1.0, spot - (strikeStep * 6));
    final maxSpot = spot + (strikeStep * 6);
    const int steps = 24;
    final dx = (maxSpot - minSpot) / steps;

    final curve = <Map<String, double>>[];
    double bestPnl = -double.infinity;
    double worstPnl = double.infinity;
    double? breakeven;
    double? prevSpot;
    double? prevPnl;

    for (int i = 0; i <= steps; i++) {
      final s = minSpot + (i * dx);
      double pnl = -totalFriction;
      for (final leg in legs) {
        pnl += leg.expiryPayoffAt(s);
      }
      if (pnl > bestPnl) bestPnl = pnl;
      if (pnl < worstPnl) worstPnl = pnl;

      if (prevSpot != null && prevPnl != null && breakeven == null) {
        if ((prevPnl <= 0 && pnl >= 0) ||
            (prevPnl >= 0 && pnl <= 0)) {
          final denom = (pnl - prevPnl).abs();
          if (denom > 1e-9) {
            final frac = prevPnl.abs() / denom;
            breakeven = prevSpot + frac * (s - prevSpot);
          }
        }
      }
      prevSpot = s;
      prevPnl = pnl;
      curve.add({'spot': s, 'netPnl': pnl});
    }

    final bool unlimitedUpside = netLongCallQty > 0;
    final double? maxProfit = unlimitedUpside ? null : bestPnl;
    final double maxLoss = worstPnl < 0 ? worstPnl.abs() : 0.0;
    final double? rr =
        (maxProfit != null && maxLoss > 0) ? (maxProfit / maxLoss) : null;

    return PayoffComparisonResult(
      strategyName: strategyName,
      legs: legs,
      netDebitInr: netDebit,
      estimatedFrictionInr: totalFriction,
      maxProfitInr: maxProfit,
      maxLossInr: maxLoss,
      breakevenSpot: breakeven,
      rewardToRisk: rr,
      payoffCurve: curve,
    );
  }

  /// Side-by-side comparison: Naked ATM Option vs. Vertical Debit Spread (ATM + OTM Hedge)
  /// Returns null (fail-closed) if required live strikes or premiums are missing.
  static List<PayoffComparisonResult>? compareNakedVsDebitSpread({
    required List<StrikeRowSnapshot> chainRows,
    required double spot,
    required bool isCall,
    required int strikeStep,
    int spreadWidthSteps = 2,
  }) {
    if (chainRows.isEmpty || spot <= 0 || strikeStep <= 0) return null;

    StrikeRowSnapshot? atmRow;
    StrikeRowSnapshot? hedgeRow;
    final hedgeOffset = isCall ? spreadWidthSteps : -spreadWidthSteps;

    for (final r in chainRows) {
      if (r.offset == 0) atmRow = r;
      if (r.offset == hedgeOffset) hedgeRow = r;
    }

    if (atmRow == null || hedgeRow == null || atmRow.lotSize <= 0) {
      return null;
    }

    final longPrem = isCall ? atmRow.ceLtp : atmRow.peLtp;
    final shortPrem = isCall ? hedgeRow.ceLtp : hedgeRow.peLtp;
    if (longPrem <= 0 || shortPrem <= 0) return null;

    final lot = atmRow.lotSize;
    final label = isCall ? 'CE' : 'PE';

    final naked = evaluateStrategy(
      strategyName: 'Naked Buy ${atmRow.strike} $label',
      legs: [
        OptionLeg(
          strike: atmRow.strike,
          isCall: isCall,
          isLong: true,
          premium: longPrem,
          quantity: lot,
        ),
      ],
      spot: spot,
      strikeStep: strikeStep,
    );

    final spread = evaluateStrategy(
      strategyName:
          'Debit Spread ${atmRow.strike}/${hedgeRow.strike} $label',
      legs: [
        OptionLeg(
          strike: atmRow.strike,
          isCall: isCall,
          isLong: true,
          premium: longPrem,
          quantity: lot,
        ),
        OptionLeg(
          strike: hedgeRow.strike,
          isCall: isCall,
          isLong: false,
          premium: shortPrem,
          quantity: lot,
        ),
      ],
      spot: spot,
      strikeStep: strikeStep,
    );

    return [naked, spread];
  }
}
