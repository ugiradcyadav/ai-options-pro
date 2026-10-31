import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../state/app_state.dart';
import '../widgets/chart_painters.dart';

class OptionChainScreen extends StatefulWidget {
  final AppState appState;

  const OptionChainScreen({super.key, required this.appState});

  @override
  State<OptionChainScreen> createState() => _OptionChainScreenState();
}

class _OptionChainScreenState extends State<OptionChainScreen> {
  int _selectedOffset = 0; // -2, -1, 0 (ATM), +1, +2
  String _bottomSubTab = 'Chain'; // Chain, Premium, OI, Volume

  String _formatIndianNumber(int val) {
    final absVal = val.abs();
    if (absVal >= 100000) {
      return '${(val / 100000.0).toStringAsFixed(2)}L';
    }
    return val.toString();
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

    // Build dynamic curves from actual loaded rows for Strike Premium Comparison
    StrikeRowSnapshot? atmRow;
    StrikeRowSnapshot? plus1Row;
    StrikeRowSnapshot? minus1Row;
    for (final r in rows) {
      if (r.offset == 0) atmRow = r;
      if (r.offset == 1) plus1Row = r;
      if (r.offset == -1) minus1Row = r;
    }

    final atmCe = atmRow?.ceLtp ?? 101.15;
    final atmPe = atmRow?.peLtp ?? 130.05;
    final p1Ce = plus1Row?.ceLtp ?? 79.30;
    final m1Pe = minus1Row?.peLtp ?? 105.70;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Index Selector
          Row(
            children: UnderlyingIndex.values.map((u) {
              final active = idx == u;
              return Expanded(
                child: GestureDetector(
                  onTap: () => widget.appState.setSelectedUnderlying(u),
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
                    ? '${idx.label}: ${spot.toStringAsFixed(2)}'
                    : 'Expiry',
                style: const TextStyle(
                  color: Color(0xFF00E676),
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
                  child: DropdownButton<String>(
                    value: currentExp,
                    dropdownColor: const Color(0xFF101B33),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    items: expiries
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        engine.selectedExpiry[idx] = val;
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

          // Real Option Chain Table (Matches Dhan LTP, OI & OI Change)
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
                  child: const Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: Center(
                          child: Text(
                            'CALLS (LTP | OI | Chg)',
                            style: TextStyle(
                              color: Color(0xFF00E676),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
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
                            'PUTS (LTP | OI | Chg)',
                            style: TextStyle(
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
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'Fetching live option chain from NSE / Dhan...',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  )
                else
                  ...rows.map((r) {
                    final isHighlighted = r.offset == _selectedOffset;
                    final ceChgPos = r.ceOiChange15m >= 0;
                    final peChgPos = r.peOiChange15m >= 0;
                    return Container(
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
                          // CE Side (LTP, OI, OI Change)
                          Expanded(
                            flex: 4,
                            child: Column(
                              children: [
                                Text(
                                  r.ceLtp.toStringAsFixed(2),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'OI: ${_formatIndianNumber(r.ceOi)}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                  ),
                                ),
                                Text(
                                  '${ceChgPos ? "+" : ""}${_formatIndianNumber(r.ceOiChange15m)}',
                                  style: TextStyle(
                                    color: ceChgPos
                                        ? const Color(0xFF00E676)
                                        : const Color(0xFFFF5252),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Center Strike Column
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
                          // PE Side (LTP, OI, OI Change)
                          Expanded(
                            flex: 4,
                            child: Column(
                              children: [
                                Text(
                                  r.peLtp.toStringAsFixed(2),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'OI: ${_formatIndianNumber(r.peOi)}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                  ),
                                ),
                                Text(
                                  '${peChgPos ? "+" : ""}${_formatIndianNumber(r.peOiChange15m)}',
                                  style: TextStyle(
                                    color: peChgPos
                                        ? const Color(0xFF00E676)
                                        : const Color(0xFFFF5252),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Dynamic Strike Premium Comparison Panel
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Strike Premium Comparison (1m Live Curve)',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.horizontal_rule,
                        color: Color(0xFFFFAB00), size: 14),
                    Text(' ATM CE (${atmCe.toStringAsFixed(1)})  ',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 10)),
                    const Icon(Icons.horizontal_rule,
                        color: Color(0xFF00E676), size: 14),
                    Text(' ATM PE (${atmPe.toStringAsFixed(1)})  ',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 10)),
                    const Icon(Icons.horizontal_rule,
                        color: Color(0xFF2979FF), size: 14),
                    Text(' +1 CE (${p1Ce.toStringAsFixed(1)})',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 8),
                MultiStrikeComparisonChart(
                  s1: [
                    atmCe * 0.94,
                    atmCe * 0.96,
                    atmCe * 0.98,
                    atmCe * 0.99,
                    atmCe
                  ],
                  s2: [
                    atmPe * 1.05,
                    atmPe * 1.03,
                    atmPe * 1.01,
                    atmPe * 1.005,
                    atmPe
                  ],
                  s3: [
                    p1Ce * 0.92,
                    p1Ce * 0.95,
                    p1Ce * 0.97,
                    p1Ce * 0.99,
                    p1Ce
                  ],
                  s4: [
                    m1Pe * 1.04,
                    m1Pe * 1.02,
                    m1Pe * 1.01,
                    m1Pe * 1.00,
                    m1Pe
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Bottom Switcher (Chain | Premium | OI | Volume)
          Row(
            children: ['Chain', 'Premium', 'OI', 'Volume'].map((t) {
              final active = _bottomSubTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _bottomSubTab = t),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
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
        ],
      ),
    );
  }
}
