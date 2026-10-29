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

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final expiries = engine.availableExpiries[idx] ?? const ['2026-04-30'];
    final currentExp = engine.selectedExpiry[idx]?.isNotEmpty == true
        ? engine.selectedExpiry[idx]!
        : expiries.first;
    final rows = engine.optionChainRows[idx] ?? [];

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

          // Expiry Selector Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Expiry',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF101B33),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1E325C)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: expiries.contains(currentExp) ? currentExp : expiries.first,
                    dropdownColor: const Color(0xFF101B33),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
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
              final label = off == 0 ? 'ATM' : (off > 0 ? 'ATM+$off' : 'ATM$off');
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

          // Option Chain Table (ATM-2 to ATM+2)
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  decoration: const BoxDecoration(
                    color: Color(0xFF162444),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: const Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          'Strike',
                          style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Center(
                          child: Text(
                            'CE (Prem | OI)',
                            style: TextStyle(color: Color(0xFF00E676), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Center(
                          child: Text(
                            'PE (Prem | OI)',
                            style: TextStyle(color: Color(0xFFFF5252), fontSize: 12, fontWeight: FontWeight.bold),
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
                      'Syncing live option chain from Dhan...',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  )
                else
                  ...rows.map((r) {
                    final isHighlighted = r.offset == _selectedOffset;
                    return Container(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
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
                            flex: 2,
                            child: Text(
                              '${r.strike}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Column(
                              children: [
                                Text(
                                  r.ceLtp.toStringAsFixed(1),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '${(r.ceOi / 100000.0).toStringAsFixed(1)}L  IV:${r.ceIv.toStringAsFixed(1)}%',
                                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Column(
                              children: [
                                Text(
                                  r.peLtp.toStringAsFixed(1),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '${(r.peOi / 100000.0).toStringAsFixed(1)}L  IV:${r.peIv.toStringAsFixed(1)}%',
                                  style: const TextStyle(color: Colors.white54, fontSize: 10),
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

          // Strike Premium Comparison Panel
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Strike Premium Comparison (1m Live Curve)',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.horizontal_rule, color: Color(0xFFFFAB00), size: 14),
                    Text(' ATM CE  ', style: TextStyle(color: Colors.white70, fontSize: 10)),
                    Icon(Icons.horizontal_rule, color: Color(0xFF00E676), size: 14),
                    Text(' ATM PE  ', style: TextStyle(color: Colors.white70, fontSize: 10)),
                    Icon(Icons.horizontal_rule, color: Color(0xFF2979FF), size: 14),
                    Text(' ATM+1 CE  ', style: TextStyle(color: Colors.white70, fontSize: 10)),
                    Icon(Icons.horizontal_rule, color: Color(0xFFFF5252), size: 14),
                    Text(' ATM-1 PE', style: TextStyle(color: Colors.white70, fontSize: 10)),
                  ],
                ),
                SizedBox(height: 8),
                MultiStrikeComparisonChart(
                  s1: [95, 102, 108, 114, 118, 125],
                  s2: [104, 98, 94, 91, 88, 84],
                  s3: [68, 72, 77, 81, 85, 90],
                  s4: [76, 71, 66, 64, 60, 58],
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
