import 'dart:math' as math;
import '../core/models.dart';

class DetectedTrendline {
  final int startIdx;
  final double startPrice;
  final int endIdx;
  final double endPrice;
  final double slopePerBar;
  final bool isSupport;

  const DetectedTrendline({
    required this.startIdx,
    required this.startPrice,
    required this.endIdx,
    required this.endPrice,
    required this.slopePerBar,
    required this.isSupport,
  });

  double priceAt(int idx) => startPrice + slopePerBar * (idx - startIdx);
}

class TrendlineAnalysis {
  final DetectedTrendline? supportLine;
  final DetectedTrendline? resistanceLine;
  final double? currentSupport;
  final double? currentResistance;
  final String breakoutState; // 'ABOVE_RES' | 'BELOW_SUP' | 'INSIDE_CHANNEL' | 'NO DATA'
  final double? srRoomScore; // 0..100 for 8-Signal Radar

  const TrendlineAnalysis({
    this.supportLine,
    this.resistanceLine,
    this.currentSupport,
    this.currentResistance,
    required this.breakoutState,
    this.srRoomScore,
  });

  static const empty = TrendlineAnalysis(breakoutState: 'NO DATA');
}

class TrendlineEngine {
  /// Detects pivot-based Support & Resistance trendlines on real OHLC bars
  static TrendlineAnalysis detect(List<OneMinEnrichedBar> bars,
      {int pivotWindow = 2}) {
    if (bars.length < 8) return TrendlineAnalysis.empty;

    final pivotHighs = <int>[];
    final pivotLows = <int>[];
    for (int i = pivotWindow; i < bars.length - pivotWindow; i++) {
      bool isHigh = true;
      bool isLow = true;
      for (int k = 1; k <= pivotWindow; k++) {
        if (bars[i].high < bars[i - k].high ||
            bars[i].high < bars[i + k].high) {
          isHigh = false;
        }
        if (bars[i].low > bars[i - k].low ||
            bars[i].low > bars[i + k].low) {
          isLow = false;
        }
      }
      if (isHigh) pivotHighs.add(i);
      if (isLow) pivotLows.add(i);
    }

    final lastIdx = bars.length - 1;
    final lastClose = bars.last.close;

    DetectedTrendline? supLine;
    if (pivotLows.length >= 2) {
      final i1 = pivotLows[pivotLows.length - 2];
      final i2 = pivotLows.last;
      if (i2 > i1) {
        final slope = (bars[i2].low - bars[i1].low) / (i2 - i1);
        supLine = DetectedTrendline(
          startIdx: i1,
          startPrice: bars[i1].low,
          endIdx: lastIdx,
          endPrice: bars[i1].low + slope * (lastIdx - i1),
          slopePerBar: slope,
          isSupport: true,
        );
      }
    }

    DetectedTrendline? resLine;
    if (pivotHighs.length >= 2) {
      final i1 = pivotHighs[pivotHighs.length - 2];
      final i2 = pivotHighs.last;
      if (i2 > i1) {
        final slope = (bars[i2].high - bars[i1].high) / (i2 - i1);
        resLine = DetectedTrendline(
          startIdx: i1,
          startPrice: bars[i1].high,
          endIdx: lastIdx,
          endPrice: bars[i1].high + slope * (lastIdx - i1),
          slopePerBar: slope,
          isSupport: false,
        );
      }
    }

    final curSup = supLine?.priceAt(lastIdx);
    final curRes = resLine?.priceAt(lastIdx);
    String state = 'INSIDE_CHANNEL';
    double? roomScore;

    if (curRes != null && lastClose > curRes) {
      state = 'ABOVE_RES';
      roomScore = 88.0;
    } else if (curSup != null && lastClose < curSup) {
      state = 'BELOW_SUP';
      roomScore = 15.0;
    } else if (curSup != null && curRes != null && curRes > curSup) {
      final room = (curRes - lastClose) / math.max(1e-6, curRes - curSup);
      roomScore = (room * 100.0).clamp(5.0, 95.0);
    } else if (curSup == null && curRes == null) {
      state = 'NO DATA';
    }

    return TrendlineAnalysis(
      supportLine: supLine,
      resistanceLine: resLine,
      currentSupport: curSup,
      currentResistance: curRes,
      breakoutState: state,
      srRoomScore: roomScore,
    );
  }
}
