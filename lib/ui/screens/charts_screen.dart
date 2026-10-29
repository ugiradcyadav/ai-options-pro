import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../state/app_state.dart';
import '../widgets/chart_painters.dart';

class ChartsScreen extends StatefulWidget {
  final AppState appState;

  const ChartsScreen({super.key, required this.appState});

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  String _topMetric = 'OI'; // OI, Price, Volume, IV
  String _selectedTf = '5m'; // 1m, 5m, 15m, 60m

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final rows = DhanDataEngine.instance.optionChainRows[idx] ?? [];

    final ceOiList = <double>[];
    final peOiList = <double>[];
    final ceDeltaList = <double>[];
    final peDeltaList = <double>[];
    final cePremList = <double>[];
    final pePremList = <double>[];

    for (final r in rows) {
      ceOiList.add(r.ceOi / 100000.0);
      peOiList.add(r.peOi / 100000.0);
      ceDeltaList.add(r.ceOiChange5m.toDouble());
      peDeltaList.add(r.peOiChange5m.toDouble());
      cePremList.add(r.ceLtp);
      pePremList.add(r.peLtp);
    }

    if (ceOiList.length < 2) {
      ceOiList.addAll([40, 43, 45, 49, 52, 54]);
      peOiList.addAll([32, 34, 35, 36, 37, 38]);
      ceDeltaList.addAll([120, -80, 240, 310, -90, 180, 260, -50]);
      peDeltaList.addAll([-60, 140, -110, 90, 200, -120, 80, 150]);
      cePremList.addAll([95, 108, 118, 126, 134, 142]);
      pePremList.addAll([112, 102, 96, 89, 84, 79]);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Metric Selector (OI | Price | Volume | IV)
          Row(
            children: ['OI', 'Price', 'Volume', 'IV'].map((m) {
              final active = _topMetric == m;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _topMetric = m),
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
                      m,
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
          const SizedBox(height: 10),

          // Index Dropdown + Timeframe Dropdown
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101B33),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF1E325C)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<UnderlyingIndex>(
                      value: idx,
                      dropdownColor: const Color(0xFF101B33),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      items: UnderlyingIndex.values
                          .map((u) => DropdownMenuItem(
                                value: u,
                                child: Text(u.label),
                              ))
                          .toList(),
                      onChanged: (u) {
                        if (u != null) widget.appState.setSelectedUnderlying(u);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101B33),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF1E325C)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedTf,
                      dropdownColor: const Color(0xFF101B33),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      items: ['1m', '5m', '15m', '60m']
                          .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                          .toList(),
                      onChanged: (t) {
                        if (t != null) setState(() => _selectedTf = t);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Chart 1: CE & PE OI (Absolute)
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
                  'CE & PE $_topMetric (Absolute)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                DualSeriesLineChart(
                  greenSeries: ceOiList,
                  redSeries: peOiList,
                  height: 130,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Chart 2: OI Change Histogram
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
                  'OI Change ($_selectedTf Confirmation Bars)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                OiChangeHistogramChart(
                  ceDeltas: ceDeltaList,
                  peDeltas: peDeltaList,
                  height: 125,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Chart 3: Premium Trend (ATM 1m Sniper Entry Feed)
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
                  'Premium Trend (ATM 1m Entry Feed)',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                DualSeriesLineChart(
                  greenSeries: cePremList,
                  redSeries: pePremList,
                  height: 130,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Bottom Timeframe Pills (1m | 5m | 15m | 60m)
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
        ],
      ),
    );
  }
}
