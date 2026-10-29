import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../state/app_state.dart';
import '../widgets/chart_painters.dart';

class OiAnalysisScreen extends StatefulWidget {
  final AppState appState;

  const OiAnalysisScreen({super.key, required this.appState});

  @override
  State<OiAnalysisScreen> createState() => _OiAnalysisScreenState();
}

class _OiAnalysisScreenState extends State<OiAnalysisScreen> {
  String _selectedTf = '5m'; // 1m, 5m, 15m, 60m
  String _sideFilter = 'Both'; // Both, CE, PE
  String _bottomTab = 'OI'; // OI, Volume, Premium, IV & Greeks

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final rows = DhanDataEngine.instance.optionChainRows[idx] ?? [];

    int totalCeOi = 0;
    int totalPeOi = 0;
    int totalCeChg = 0;
    int totalPeChg = 0;

    final ceAbsSeries = <double>[];
    final peAbsSeries = <double>[];
    final ceChgSeries = <double>[];
    final peChgSeries = <double>[];

    for (final r in rows) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      final cChg = _selectedTf == '15m'
          ? r.ceOiChange15m
          : (_selectedTf == '60m' ? r.ceOiChange60m : r.ceOiChange5m);
      final pChg = _selectedTf == '15m'
          ? r.peOiChange15m
          : (_selectedTf == '60m' ? r.peOiChange60m : r.peOiChange5m);
      totalCeChg += cChg;
      totalPeChg += pChg;

      if (_bottomTab == 'OI') {
        ceAbsSeries.add(r.ceOi / 100000.0);
        peAbsSeries.add(r.peOi / 100000.0);
      } else if (_bottomTab == 'Volume') {
        ceAbsSeries.add(r.ceVolume / 100000.0);
        peAbsSeries.add(r.peVolume / 100000.0);
      } else if (_bottomTab == 'Premium') {
        ceAbsSeries.add(r.ceLtp);
        peAbsSeries.add(r.peLtp);
      } else {
        ceAbsSeries.add(r.ceIv);
        peAbsSeries.add(r.peIv);
      }

      ceChgSeries.add(cChg / 100000.0);
      peChgSeries.add(pChg / 100000.0);
    }

    if (ceAbsSeries.length < 2) {
      ceAbsSeries.addAll([42.0, 44.5, 46.1, 47.3, 48.2]);
      peAbsSeries.addAll([38.0, 39.2, 40.8, 41.9, 42.6]);
      ceChgSeries.addAll([1.1, 1.8, 2.2, 2.5, 2.8]);
      peChgSeries.addAll([0.8, 1.2, 1.5, 1.7, 1.9]);
    }

    final ceLakh = (totalCeOi > 0 ? totalCeOi / 100000.0 : 48.2).toStringAsFixed(1);
    final peLakh = (totalPeOi > 0 ? totalPeOi / 100000.0 : 42.6).toStringAsFixed(1);
    final ceChgLakh = (totalCeChg != 0 ? totalCeChg / 100000.0 : 2.8).toStringAsFixed(1);
    final peChgLakh = (totalPeChg != 0 ? totalPeChg / 100000.0 : 1.9).toStringAsFixed(1);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeframe Selector Buttons (1m, 5m, 15m, 60m)
          Row(
            children: ['1m', '5m', '15m', '60m'].map((tf) {
              final active = _selectedTf == tf;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _selectedTf = tf),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active
                            ? const Color(0xFF42A5F5)
                            : const Color(0xFF1E325C),
                      ),
                    ),
                    child: Text(
                      tf,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),

          // Index Selector Row
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
          const SizedBox(height: 8),

          // Both | CE | PE Toggle
          Row(
            children: ['Both', 'CE', 'PE'].map((side) {
              final active = _sideFilter == side;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _sideFilter = side),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      side,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Panel 1: Open Interest (Absolute)
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _bottomTab == 'OI'
                          ? 'Open Interest (Absolute)'
                          : '$_bottomTab Comparison (ATM±2)',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const Row(
                      children: [
                        Icon(Icons.square, color: Color(0xFF00E676), size: 10),
                        SizedBox(width: 4),
                        Text('CE  ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        Icon(Icons.square, color: Color(0xFFFF5252), size: 10),
                        SizedBox(width: 4),
                        Text('PE', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DualSeriesLineChart(
                  greenSeries: ceAbsSeries,
                  redSeries: peAbsSeries,
                  showGreen: _sideFilter != 'PE',
                  showRed: _sideFilter != 'CE',
                  rightBadgeGreen: 'CE ${ceLakh}L',
                  rightBadgeRed: 'PE ${peLakh}L',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Panel 2: OI Change (vs previous interval)
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
                Text(
                  'OI Change (vs previous $_selectedTf interval)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                DualSeriesLineChart(
                  greenSeries: ceChgSeries,
                  redSeries: peChgSeries,
                  showGreen: _sideFilter != 'PE',
                  showRed: _sideFilter != 'CE',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Summary Cards: Current OI & OI Change
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101B33),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF1E325C)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Current OI',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CE', style: TextStyle(color: Color(0xFF00E676), fontSize: 12)),
                          Text('${ceLakh}L', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('PE', style: TextStyle(color: Color(0xFFFF5252), fontSize: 12)),
                          Text('${peLakh}L', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101B33),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF1E325C)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'OI Change ($_selectedTf)',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '+${ceChgLakh}L (+6.2%)',
                        style: const TextStyle(
                          color: Color(0xFF00E676),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '+${peChgLakh}L (+4.7%)',
                        style: const TextStyle(
                          color: Color(0xFFFF5252),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Bottom Metric Switcher (OI | Volume | Premium | IV & Greeks)
          Row(
            children: ['OI', 'Volume', 'Premium', 'IV & Greeks'].map((tab) {
              final active = _bottomTab == tab;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _bottomTab = tab),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      tab,
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
        ],
      ),
    );
  }
}
