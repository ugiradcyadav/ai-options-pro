import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../state/app_state.dart';

class OptionChainScreen extends StatefulWidget {
  final AppState appState;

  const OptionChainScreen({super.key, required this.appState});

  @override
  State<OptionChainScreen> createState() => _OptionChainScreenState();
}

class _OptionChainScreenState extends State<OptionChainScreen> {
  int _selectedOffset = 0; // -2, -1, 0, +1, +2
  String _bottomSubTab = 'Chain'; // 'Chain', 'Premium', 'OI', 'Volume', 'IV'
  int _touchedPoint = -1;
  List _intradayBars = [];

  @override
  void initState() {
    super.initState();
    _loadMinuteBars();
  }

  @override
  void didUpdateWidget(covariant OptionChainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadMinuteBars();
  }

  Future _loadMinuteBars() async {
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: widget.appState.selectedIndex.label,
      limit: 40,
    );
    if (!mounted) return;
    setState(() {
      _intradayBars = bars.reversed.toList();
    });
  }

  String _formatIndianNumber(num val) {
    final v = val.toDouble();
    if (v.abs() >= 100000) {
      return '${(v / 100000.0).toStringAsFixed(2)}L';
    }
    if (v.abs() >= 1000) {
      return '${(v / 1000.0).toStringAsFixed(1)}K';
    }
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final expiries =
        engine.availableExpiries[idx] ?? const ['2026-11-03'];
    final currentExp = (engine.selectedExpiry[idx]?.isNotEmpty == true &&
            expiries.contains(engine.selectedExpiry[idx]))
        ? engine.selectedExpiry[idx]!
        : expiries.first;
    final rows = engine.optionChainRows[idx] ?? [];
    final spot = engine.spotPrices[idx] ?? 0.0;
    final chgPct = engine.spotChangePct[idx] ?? 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Index Selector (NIFTY 50 | BANK NIFTY | FINNIFTY)
          Row(
            children: UnderlyingIndex.values.map((u) {
              final active = idx == u;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _touchedPoint = -1);
                    widget.appState.setSelectedUnderlying(u);
                    _loadMinuteBars();
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      u.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),

          // Spot Price + Expiry Selector Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                spot > 0
                    ? '${idx.label}: ${spot.toStringAsFixed(2)} (${chgPct >= 0 ? "+" : ""}${chgPct.toStringAsFixed(2)}%)'
                    : 'Syncing Index...',
                style: TextStyle(
                  color: chgPct >= 0
                      ? const Color(0xFF00E676)
                      : const Color(0xFFFF5252),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF101B33),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1E325C)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton(
                    value: currentExp,
                    dropdownColor: const Color(0xFF101B33),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    items: expiries
                        .map((e) =>
                            DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        engine.selectedExpiry[idx] = val.toString();
                        engine.fetchOptionChainSnapshot(idx);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ATM-2, ATM-1, ATM, ATM+1, ATM+2 Filter Pills
          Row(
            children: [-2, -1, 0, 1, 2].map((off) {
              final label =
                  off == 0 ? 'ATM' : (off > 0 ? 'ATM+$off' : 'ATM$off');
              final active = _selectedOffset == off;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _selectedOffset = off),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Mode Switcher (Chain | Premium | OI | Volume | IV)
          Row(
            children: ['Chain', 'Premium', 'OI', 'Volume', 'IV'].map((t) {
              final active = _bottomSubTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() {
                    _bottomSubTab = t;
                    _touchedPoint = -1;
                  }),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF2979FF)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active
                            ? const Color(0xFF2979FF)
                            : const Color(0xFF1E325C),
                      ),
                    ),
                    child: Text(
                      t,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Touch-Interactive Graph Panel (Dynamically renders Price, OI, Volume, or IV)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: rows.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                      child: Text(
                        'Fetching live option chain from broker...',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTouchTooltipBanner(rows),
                      const SizedBox(height: 10),
                      _buildTouchGraphArea(rows),
                      const SizedBox(height: 6),
                      const Center(
                        child: Text(
                          '👆 Touch or slide finger across graph for live point inspection',
                          style: TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),

          // Live Option Chain Table (Adapts columns to selected tab)
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 10,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFF162444),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: Center(
                          child: Text(
                            _headerLeftLabel(),
                            style: const TextStyle(
                              color: Color(0xFF00E676),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const Expanded(
                        flex: 2,
                        child: Center(
                          child: Text(
                            'Strike',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: Center(
                          child: Text(
                            _headerRightLabel(),
                            style: const TextStyle(
                              color: Color(0xFFFF5252),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ...rows.asMap().entries.map((entry) {
                  final rowIdx = entry.key;
                  final r = entry.value;
                  final isHighlighted =
                      r.offset == _selectedOffset || rowIdx == _touchedPoint;
                  return GestureDetector(
                    onTap: () => setState(() {
                      _selectedOffset = r.offset;
                      _touchedPoint = rowIdx;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isHighlighted
                            ? const Color(0xFF1976D2).withOpacity(0.28)
                            : Colors.transparent,
                        border: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 4,
                            child: _buildCellSide(r, isCall: true),
                          ),
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: r.offset == 0
                                      ? const Color(0xFF2979FF)
                                      : const Color(0xFF162444),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${r.strike}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: _buildCellSide(r, isCall: false),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _headerLeftLabel() {
    switch (_bottomSubTab) {
      case 'Premium':
        return 'CALL (LTP | Bid/Ask)';
      case 'OI':
        return 'CALL (OI | 15m Chg)';
      case 'Volume':
        return 'CALL (Vol | Imb)';
      case 'IV':
        return 'CALL (IV% | Δ | Θ)';
      default:
        return 'CALLS (LTP | OI | Chg)';
    }
  }

  String _headerRightLabel() {
    switch (_bottomSubTab) {
      case 'Premium':
        return 'PUT (LTP | Bid/Ask)';
      case 'OI':
        return 'PUT (OI | 15m Chg)';
      case 'Volume':
        return 'PUT (Vol | Imb)';
      case 'IV':
        return 'PUT (IV% | Δ | Θ)';
      default:
        return 'PUTS (LTP | OI | Chg)';
    }
  }

  Widget _buildCellSide(StrikeRowSnapshot r, {required bool isCall}) {
    final ltp = isCall ? r.ceLtp : r.peLtp;
    final oi = isCall ? r.ceOi : r.peOi;
    final chg = isCall ? r.ceOiChange15m : r.peOiChange15m;
    final vol = isCall ? r.ceVolume : r.peVolume;
    final iv = isCall ? r.ceIv : r.peIv;
    final delta = isCall ? r.ceDelta : r.peDelta;
    final bid = isCall ? r.ceBid : r.peBid;
    final ask = isCall ? r.ceAsk : r.peAsk;
    final imb = isCall ? r.ceImbalance : r.peImbalance;
    final chgPos = chg >= 0;

    if (_bottomSubTab == 'Premium') {
      return Column(
        children: [
          Text(
            ltp.toStringAsFixed(2),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
          Text(
            '${bid.toStringAsFixed(1)} / ${ask.toStringAsFixed(1)}',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      );
    } else if (_bottomSubTab == 'Volume') {
      return Column(
        children: [
          Text(
            _formatIndianNumber(vol),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
          Text(
            'Imb: ${(imb * 100).toStringAsFixed(0)}% | ₹${ltp.toStringAsFixed(1)}',
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 10),
          ),
        ],
      );
    } else if (_bottomSubTab == 'IV') {
      return Column(
        children: [
          Text(
            '${iv.toStringAsFixed(2)}%',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
          Text(
            'Δ ${delta.toStringAsFixed(2)} | Θ ${r.ceTheta.toStringAsFixed(1)}',
            style: const TextStyle(color: Colors.amberAccent, fontSize: 10),
          ),
        ],
      );
    }

    return Column(
      children: [
        Text(
          ltp.toStringAsFixed(2),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'OI: ${_formatIndianNumber(oi)}',
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
        Text(
          '${chgPos ? "+" : ""}${_formatIndianNumber(chg)}',
          style: TextStyle(
            color: chgPos ? const Color(0xFF00E676) : const Color(0xFFFF5252),
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildTouchTooltipBanner(List rows) {
    if ((_bottomSubTab == 'Premium' || _bottomSubTab == 'Chain') &&
        _intradayBars.isNotEmpty) {
      final bIdx = (_touchedPoint >= 0 && _touchedPoint < _intradayBars.length)
          ? _touchedPoint
          : _intradayBars.length - 1;
      final b = _intradayBars[bIdx] as OneMinEnrichedBar;
      final timeStr = DateFormat('HH:mm')
          .format(DateTime.fromMillisecondsSinceEpoch(b.timestampMs));
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Time: $timeStr (${b.strike} CE)',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('Spot: ${b.underlyingSpot.toStringAsFixed(1)}',
                style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
            Text(
                'Prem: ₹${b.close.toStringAsFixed(2)} (IV ${b.iv.toStringAsFixed(1)}%)',
                style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    }

    final sIdx = (_touchedPoint >= 0 && _touchedPoint < rows.length)
        ? _touchedPoint
        : rows.length ~/ 2;
    final r = rows[sIdx] as StrikeRowSnapshot;

    if (_bottomSubTab == 'OI') {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Strike ${r.strike}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('CE OI: ${_formatIndianNumber(r.ceOi)}',
                style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('PE OI: ${_formatIndianNumber(r.peOi)}',
                style: const TextStyle(
                    color: Color(0xFFFF5252),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    } else if (_bottomSubTab == 'Volume') {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Strike ${r.strike}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('CE Vol: ${_formatIndianNumber(r.ceVolume)}',
                style: const TextStyle(
                    color: Color(0xFF2979FF),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('PE Vol: ${_formatIndianNumber(r.peVolume)}',
                style: const TextStyle(
                    color: Color(0xFFFFAB00),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    } else {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF162444),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Strike ${r.strike}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('CE IV: ${r.ceIv.toStringAsFixed(2)}% (Δ ${r.ceDelta.toStringAsFixed(2)})',
                style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            Text('PE IV: ${r.peIv.toStringAsFixed(2)}% (Δ ${r.peDelta.toStringAsFixed(2)})',
                style: const TextStyle(
                    color: Color(0xFFFF5252),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
          ],
        ),
      );
    }
  }

  Widget _buildTouchGraphArea(List rows) {
    final isTimeMode = (_bottomSubTab == 'Premium' || _bottomSubTab == 'Chain') &&
        _intradayBars.isNotEmpty;
    final count = isTimeMode ? _intradayBars.length : rows.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        const h = 165.0;

        void onTouch(Offset pos) {
          if (count <= 0 || w <= 0) return;
          final ratio = (pos.dx / w).clamp(0.0, 0.999);
          final idx = (ratio * count).floor();
          if (idx != _touchedPoint) {
            setState(() => _touchedPoint = idx);
          }
        }

        return GestureDetector(
          onTapDown: (d) => onTouch(d.localPosition),
          onPanDown: (d) => onTouch(d.localPosition),
          onPanUpdate: (d) => onTouch(d.localPosition),
          child: SizedBox(
            width: w,
            height: h,
            child: CustomPaint(
              painter: _ChainInteractivePainter(
                subTab: _bottomSubTab,
                rows: rows,
                bars: _intradayBars,
                touchedIndex: _touchedPoint,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChainInteractivePainter extends CustomPainter {
  final String subTab;
  final List rows;
  final List bars;
  final int touchedIndex;

  _ChainInteractivePainter({
    required this.subTab,
    required this.rows,
    required this.bars,
    required this.touchedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0xFF1E325C).withOpacity(0.5)
      ..strokeWidth = 1;
    for (int i = 1; i <= 3; i++) {
      final y = size.height * (i / 4.0);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if ((subTab == 'Premium' || subTab == 'Chain') && bars.isNotEmpty) {
      _paintIntradayPremiumCurve(canvas, size);
      return;
    }

    if (rows.isEmpty) return;

    if (subTab == 'OI' || subTab == 'Volume') {
      _paintStrikeBars(canvas, size, isVolume: subTab == 'Volume');
    } else {
      _paintIvSmile(canvas, size);
    }
  }

  void _paintIntradayPremiumCurve(Canvas canvas, Size size) {
    double minP = double.infinity;
    double maxP = -double.infinity;
    for (final raw in bars) {
      final b = raw as OneMinEnrichedBar;
      if (b.low < minP) minP = b.low;
      if (b.high > maxP) maxP = b.high;
    }
    if (maxP <= minP) maxP = minP + 1.0;

    final n = bars.length;
    final stepX = size.width / math.max(1, n - 1);
    final usableH = size.height - 18.0;
    final cePath = Path();

    for (int i = 0; i < n; i++) {
      final b = bars[i] as OneMinEnrichedBar;
      final x = i * stepX;
      final y = usableH - ((b.close - minP) / (maxP - minP)) * (usableH - 12.0);
      if (i == 0) {
        cePath.moveTo(x, y);
      } else {
        cePath.lineTo(x, y);
      }

      final yH = usableH - ((b.high - minP) / (maxP - minP)) * (usableH - 12.0);
      final yL = usableH - ((b.low - minP) / (maxP - minP)) * (usableH - 12.0);
      canvas.drawLine(
        Offset(x, yH),
        Offset(x, yL),
        Paint()
          ..color = b.close >= b.open
              ? const Color(0xFF00E676).withOpacity(0.7)
              : const Color(0xFFFF5252).withOpacity(0.7)
          ..strokeWidth = 1.4,
      );
    }

    canvas.drawPath(
      cePath,
      Paint()
        ..color = const Color(0xFFFFAB00)
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke,
    );

    if (touchedIndex >= 0 && touchedIndex < n) {
      final b = bars[touchedIndex] as OneMinEnrichedBar;
      final tx = touchedIndex * stepX;
      final ty =
          usableH - ((b.close - minP) / (maxP - minP)) * (usableH - 12.0);
      canvas.drawLine(
        Offset(tx, 0),
        Offset(tx, size.height),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 1.2,
      );
      canvas.drawCircle(
          Offset(tx, ty), 4.5, Paint()..color = const Color(0xFF00E676));
    }
  }

  void _paintStrikeBars(Canvas canvas, Size size, {required bool isVolume}) {
    double maxVal = 1.0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      final v1 = (isVolume ? r.ceVolume : r.ceOi).toDouble();
      final v2 = (isVolume ? r.peVolume : r.peOi).toDouble();
      if (v1 > maxVal) maxVal = v1;
      if (v2 > maxVal) maxVal = v2;
    }

    final n = rows.length;
    final slotW = size.width / n;
    final barW = (slotW * 0.30).clamp(6.0, 24.0);
    final bottomY = size.height - 20.0;
    final usableH = bottomY - 10.0;

    for (int i = 0; i < n; i++) {
      final r = rows[i] as StrikeRowSnapshot;
      final v1 = (isVolume ? r.ceVolume : r.ceOi).toDouble();
      final v2 = (isVolume ? r.peVolume : r.peOi).toDouble();
      final h1 = (v1 / maxVal) * usableH;
      final h2 = (v2 / maxVal) * usableH;
      final cx = (i + 0.5) * slotW;

      if (i == touchedIndex) {
        canvas.drawRect(
          Rect.fromLTWH(i * slotW, 0, slotW, size.height),
          Paint()..color = Colors.white.withOpacity(0.12),
        );
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - barW - 2, bottomY - h1, barW, h1),
          const Radius.circular(4),
        ),
        Paint()
          ..color =
              isVolume ? const Color(0xFF2979FF) : const Color(0xFF00E676),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx + 2, bottomY - h2, barW, h2),
          const Radius.circular(4),
        ),
        Paint()
          ..color =
              isVolume ? const Color(0xFFFFAB00) : const Color(0xFFFF5252),
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '${r.strike}',
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, bottomY + 4));
    }
  }

  void _paintIvSmile(Canvas canvas, Size size) {
    double minIv = 100.0;
    double maxIv = 5.0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      if (r.ceIv < minIv) minIv = r.ceIv;
      if (r.peIv < minIv) minIv = r.peIv;
      if (r.ceIv > maxIv) maxIv = r.ceIv;
      if (r.peIv > maxIv) maxIv = r.peIv;
    }
    minIv -= 1.0;
    maxIv += 1.0;

    final n = rows.length;
    final slotW = size.width / n;
    final bottomY = size.height - 20.0;
    final usableH = bottomY - 12.0;
    final cePath = Path();
    final pePath = Path();

    for (int i = 0; i < n; i++) {
      final r = rows[i] as StrikeRowSnapshot;
      final cx = (i + 0.5) * slotW;
      final yCe = bottomY - ((r.ceIv - minIv) / (maxIv - minIv)) * usableH;
      final yPe = bottomY - ((r.peIv - minIv) / (maxIv - minIv)) * usableH;

      if (i == 0) {
        cePath.moveTo(cx, yCe);
        pePath.moveTo(cx, yPe);
      } else {
        cePath.lineTo(cx, yCe);
        pePath.lineTo(cx, yPe);
      }

      canvas.drawCircle(
          Offset(cx, yCe), 3.8, Paint()..color = const Color(0xFF00E676));
      canvas.drawCircle(
          Offset(cx, yPe), 3.8, Paint()..color = const Color(0xFFFF5252));

      if (i == touchedIndex) {
        canvas.drawLine(Offset(cx, 0), Offset(cx, bottomY),
            Paint()..color = Colors.white70);
      }
    }

    canvas.drawPath(
      cePath,
      Paint()
        ..color = const Color(0xFF00E676)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      pePath,
      Paint()
        ..color = const Color(0xFFFF5252)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ChainInteractivePainter oldDelegate) => true;
}
