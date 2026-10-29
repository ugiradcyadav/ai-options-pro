import '../core/models.dart';

class StrikeSelectionEngine {
  /// Returns exact ATM strike for NIFTY 50, BANK NIFTY, or FINNIFTY
  static int computeAtmStrike(UnderlyingIndex index, double spotPrice) {
    if (spotPrice <= 0) return 0;
    final step = index.strikeStep;
    return (spotPrice / step).round() * step;
  }

  /// Returns the 5 strikes around ATM (ATM-2, ATM-1, ATM, ATM+1, ATM+2)
  /// Used by Option Chain screen and the 6 active buyer-only contracts:
  /// Calls: ATM, ATM+1, ATM+2 | Puts: ATM, ATM-1, ATM-2
  static List<int> getMonitoringStrikeBand(
    UnderlyingIndex index,
    double spotPrice,
  ) {
    final atm = computeAtmStrike(index, spotPrice);
    if (atm <= 0) return const [];
    final step = index.strikeStep;
    return [
      atm - (2 * step),
      atm - step,
      atm,
      atm + step,
      atm + (2 * step),
    ];
  }

  /// Checks whether a contract is in the strict 6-contract active signal universe
  /// Calls: ATM (0), ATM+1 (+1), ATM+2 (+2)
  /// Puts: ATM (0), ATM-1 (-1), ATM-2 (-2)
  static bool isInActiveBuyerSignalBand({
    required int strikeOffset,
    required OptionType optionType,
  }) {
    if (optionType == OptionType.ce) {
      return strikeOffset >= 0 && strikeOffset <= 2;
    } else {
      return strikeOffset <= 0 && strikeOffset >= -2;
    }
  }

  /// Calculates remaining days to expiry from YYYY-MM-DD expiry string
  static double computeDaysToExpiry(String expiryIso) {
    try {
      final parts = expiryIso.split('-');
      if (parts.length == 3) {
        final expDate = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
          15,
          30,
        );
        final diffHours =
            expDate.difference(DateTime.now()).inMinutes / 60.0;
        return (diffHours / 24.0).clamp(0.05, 60.0);
      }
    } catch (_) {}
    return 3.0;
  }
}
