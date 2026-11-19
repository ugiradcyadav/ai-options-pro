import '../core/models.dart';

enum IvCellSource {
  observed('OBS'),
  interpolated('INT'),
  unavailable('N/A');

  final String shortTag;
  const IvCellSource(this.shortTag);
}

class IvGridCell {
  final int strike;
  final int offset;
  final double? ceIv;
  final IvCellSource ceSource;
  final double? peIv;
  final IvCellSource peSource;

  const IvGridCell({
    required this.strike,
    required this.offset,
    required this.ceIv,
    required this.ceSource,
    required this.peIv,
    required this.peSource,
  });
}

class IvGridSnapshot {
  final List<IvGridCell> cells;
  final int observedCount;
  final int interpolatedCount;
  final int unavailableCount;
  final int? minObservedStrike;
  final int? maxObservedStrike;

  const IvGridSnapshot({
    required this.cells,
    required this.observedCount,
    required this.interpolatedCount,
    required this.unavailableCount,
    required this.minObservedStrike,
    required this.maxObservedStrike,
  });
}

class IvGridEngine {
  /// Builds strike IV grid with explicit Observed / Interpolated labels.
  /// Strictly refuses extrapolation beyond the min/max observed strikes.
  static IvGridSnapshot buildNoExtrapolationGrid(
      List<StrikeRowSnapshot> rows) {
    if (rows.isEmpty) {
      return const IvGridSnapshot(
        cells: [],
        observedCount: 0,
        interpolatedCount: 0,
        unavailableCount: 0,
        minObservedStrike: null,
        maxObservedStrike: null,
      );
    }

    final sorted = List<StrikeRowSnapshot>.from(rows)
      ..sort((a, b) => a.strike.compareTo(b.strike));

    final ceObs = <int, double>{};
    final peObs = <int, double>{};
    for (final r in sorted) {
      if (r.ceIv != null && r.ceIv! > 0) ceObs[r.strike] = r.ceIv!;
      if (r.peIv != null && r.peIv! > 0) peObs[r.strike] = r.peIv!;
    }

    final ceObsStrikes = ceObs.keys.toList()..sort();
    final peObsStrikes = peObs.keys.toList()..sort();

    int obsCnt = 0;
    int intCnt = 0;
    int naCnt = 0;
    int? minObs;
    int? maxObs;

    final cells = <IvGridCell>[];
    for (final r in sorted) {
      final ceRes = _resolveSide(r.strike, ceObs, ceObsStrikes);
      final peRes = _resolveSide(r.strike, peObs, peObsStrikes);

      for (final src in [
        ceRes['source'] as IvCellSource,
        peRes['source'] as IvCellSource
      ]) {
        if (src == IvCellSource.observed) {
          obsCnt++;
          if (minObs == null || r.strike < minObs) minObs = r.strike;
          if (maxObs == null || r.strike > maxObs) maxObs = r.strike;
        } else if (src == IvCellSource.interpolated) {
          intCnt++;
        } else {
          naCnt++;
        }
      }

      cells.add(IvGridCell(
        strike: r.strike,
        offset: r.offset,
        ceIv: ceRes['iv'] as double?,
        ceSource: ceRes['source'] as IvCellSource,
        peIv: peRes['iv'] as double?,
        peSource: peRes['source'] as IvCellSource,
      ));
    }

    return IvGridSnapshot(
      cells: cells,
      observedCount: obsCnt,
      interpolatedCount: intCnt,
      unavailableCount: naCnt,
      minObservedStrike: minObs,
      maxObservedStrike: maxObs,
    );
  }

  static Map<String, dynamic> _resolveSide(
    int strike,
    Map<int, double> obsMap,
    List<int> sortedObsStrikes,
  ) {
    if (obsMap.containsKey(strike)) {
      return {'iv': obsMap[strike], 'source': IvCellSource.observed};
    }
    if (sortedObsStrikes.length < 2) {
      return {'iv': null, 'source': IvCellSource.unavailable};
    }
    // Strictly refuse extrapolation outside [first, last] observed strikes
    if (strike < sortedObsStrikes.first ||
        strike > sortedObsStrikes.last) {
      return {'iv': null, 'source': IvCellSource.unavailable};
    }

    int leftStrike = sortedObsStrikes.first;
    int rightStrike = sortedObsStrikes.last;
    for (int i = 0; i < sortedObsStrikes.length - 1; i++) {
      final a = sortedObsStrikes[i];
      final b = sortedObsStrikes[i + 1];
      if (strike > a && strike < b) {
        leftStrike = a;
        rightStrike = b;
        break;
      }
    }

    final span = rightStrike - leftStrike;
    if (span <= 0) {
      return {'iv': null, 'source': IvCellSource.unavailable};
    }
    final weight = (strike - leftStrike) / span.toDouble();
    final interp =
        obsMap[leftStrike]! + weight * (obsMap[rightStrike]! - obsMap[leftStrike]!);
    return {'iv': interp, 'source': IvCellSource.interpolated};
  }
}
