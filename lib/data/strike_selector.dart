import '../core/models.dart';

class StrikeSelectionEngine {
  static int computeAtmStrike(UnderlyingIndex index, double spotPrice) {
    if (spotPrice <= 0) return 0;
    final step = index.strikeStep;
    return (spotPrice / step).round() * step;
  }

  /// WP-3 & WP-7: Full option chain band (default ATM +/- 12 strikes = 25 strikes)
  static List<int> getMonitoringStrikeBand(
    UnderlyingIndex index,
    double spotPrice, {
    int radius = 12,
  }) {
    final atm = computeAtmStrike(index, spotPrice);
    if (atm <= 0) return const [];
    final step = index.strikeStep;
    final band = <int>[];
    for (int off = -radius; off <= radius; off++) {
      band.add(atm + (off * step));
    }
    return band;
  }

  /// Active buyer execution band (ATM +/- 2 strikes)
  static bool isInActiveBuyerSignalBand({
    required int strikeOffset,
    required OptionType optionType,
  }) {
    if (optionType == OptionType.ce) {
      return strikeOffset >= -1 && strikeOffset <= 2;
    } else {
      return strikeOffset >= -2 && strikeOffset <= 1;
    }
  }

  /// WP-5: Exact fractional years to 15:30 IST (explicit UTC+05:30, no device-local drift, no floor)
  static double computeFractionalYearsToExpiryIst(
    String expiryIso, {
    DateTime? nowUtc,
  }) {
    final parts = expiryIso.trim().split('-');
    if (parts.length != 3) return 0.0;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return 0.0;

    // 15:30 IST == 10:00 UTC
    final expiryUtc = DateTime.utc(year, month, day, 10, 0, 0);
    final currentUtc = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    final diffSec = expiryUtc.difference(currentUtc).inSeconds;
    if (diffSec <= 0) return 0.0;
    return diffSec / (365.0 * 24.0 * 3600.0);
  }

  static double computeDaysToExpiry(String expiryIso, {DateTime? nowUtc}) {
    return computeFractionalYearsToExpiryIst(expiryIso, nowUtc: nowUtc) * 365.0;
  }
}
