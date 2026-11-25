import 'dart:collection';
import 'dart:math' as math;
import '../data/angel_ws_streamer.dart';

class MicrostructureSnapshot {
  final String token;
  final double ltp;
  final double? microPrice;
  final double? spreadBps;
  final double weightedObi; // -1.0 .. +1.0 across best 5 levels
  final double toxicityScore; // 0..100 (VPIN-inspired flow toxicity)
  final double buyAggressionPct; // 0..100
  final String pressureLabel;
  final int sampleCount;
  final int updatedAtMs;

  const MicrostructureSnapshot({
    required this.token,
    required this.ltp,
    required this.microPrice,
    required this.spreadBps,
    required this.weightedObi,
    required this.toxicityScore,
    required this.buyAggressionPct,
    required this.pressureLabel,
    required this.sampleCount,
    required this.updatedAtMs,
  });
}

class _FlowSample {
  final double signedVol;
  final double absVol;
  const _FlowSample(this.signedVol, this.absVol);
}

class MicrostructureEngine {
  static final MicrostructureEngine instance = MicrostructureEngine._();
  MicrostructureEngine._();

  static const int _windowSize = 30;
  final Map<String, Queue<_FlowSample>> _samples = {};
  final Map<String, double> _prevLtp = {};
  final Map<String, int> _prevVol = {};
  final Map<String, MicrostructureSnapshot> _latest = {};

  MicrostructureSnapshot? getSnapshot(String token) => _latest[token];

  MicrostructureSnapshot ingestTick(LiveWsTick tick) {
    final tok = tick.token;
    final prevP = _prevLtp[tok];
    final prevV = _prevVol[tok];
    _prevLtp[tok] = tick.ltp;
    if (tick.volume != null) _prevVol[tok] = tick.volume!;

    // 1. Multi-level exponentially weighted Order Book Imbalance (Best 5 levels)
    double wBid = 0.0, wAsk = 0.0;
    for (int i = 0; i < tick.bids.length; i++) {
      wBid += tick.bids[i].quantity * math.exp(-0.45 * i);
    }
    for (int i = 0; i < tick.asks.length; i++) {
      wAsk += tick.asks[i].quantity * math.exp(-0.45 * i);
    }
    if (wBid == 0 && wAsk == 0) {
      wBid = (tick.totalBuyQty ?? tick.best5BidQty.toDouble());
      wAsk = (tick.totalSellQty ?? tick.best5AskQty.toDouble());
    }
    final double obi =
        (wBid + wAsk) > 0 ? ((wBid - wAsk) / (wBid + wAsk)).clamp(-1.0, 1.0) : 0.0;

    // 2. Micro-price (size-weighted top-of-book fair price) & Spread (bps)
    double? microPrice;
    double? spreadBps;
    if (tick.bids.isNotEmpty &&
        tick.asks.isNotEmpty &&
        tick.bids.first.price > 0 &&
        tick.asks.first.price > 0) {
      final bP = tick.bids.first.price;
      final aP = tick.asks.first.price;
      final bQ = math.max(1, tick.bids.first.quantity).toDouble();
      final aQ = math.max(1, tick.asks.first.quantity).toDouble();
      microPrice = (bP * aQ + aP * bQ) / (bQ + aQ);
      final mid = (bP + aP) * 0.5;
      if (mid > 0 && aP >= bP) {
        spreadBps = ((aP - bP) / mid) * 10000.0;
      }
    }

    // 3. Lee-Ready / Tick-rule signed volume for VPIN-style toxicity
    final q = _samples.putIfAbsent(tok, () => Queue<_FlowSample>());
    final dVol = (tick.volume != null && prevV != null && tick.volume! > prevV)
        ? (tick.volume! - prevV).toDouble()
        : 1.0;

    int sign = 0;
    if (tick.bestAsk != null && tick.ltp >= tick.bestAsk!) {
      sign = 1;
    } else if (tick.bestBid != null && tick.ltp <= tick.bestBid!) {
      sign = -1;
    } else if (prevP != null && tick.ltp != prevP) {
      sign = tick.ltp > prevP ? 1 : -1;
    } else if (obi.abs() > 0.1) {
      sign = obi > 0 ? 1 : -1;
    }

    q.addLast(_FlowSample(sign * dVol, dVol));
    while (q.length > _windowSize) {
      q.removeFirst();
    }

    double sumSigned = 0.0, sumAbs = 0.0, buyVol = 0.0;
    for (final s in q) {
      sumSigned += s.signedVol;
      sumAbs += s.absVol;
      if (s.signedVol > 0) buyVol += s.absVol;
    }
    final toxicity =
        sumAbs > 0 ? ((sumSigned.abs() / sumAbs) * 100.0).clamp(0.0, 100.0) : 0.0;
    final buyAgg = sumAbs > 0 ? ((buyVol / sumAbs) * 100.0).clamp(0.0, 100.0) : 50.0;

    String label = 'BALANCED';
    if (obi >= 0.35 && buyAgg >= 60) {
      label = 'STRONG BUY FLOW';
    } else if (obi >= 0.12) {
      label = 'BUY BIAS';
    } else if (obi <= -0.35 && buyAgg <= 40) {
      label = 'STRONG SELL FLOW';
    } else if (obi <= -0.12) {
      label = 'SELL BIAS';
    }

    final snap = MicrostructureSnapshot(
      token: tok,
      ltp: tick.ltp,
      microPrice: microPrice,
      spreadBps: spreadBps,
      weightedObi: obi,
      toxicityScore: toxicity,
      buyAggressionPct: buyAgg,
      pressureLabel: label,
      sampleCount: q.length,
      updatedAtMs: tick.receivedAtMs,
    );
    _latest[tok] = snap;
    return snap;
  }
}
