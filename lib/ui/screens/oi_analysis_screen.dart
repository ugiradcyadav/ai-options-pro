import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';

class OiAnalysisScreen extends StatefulWidget {
  final AppState appState;
  final bool embeddedMode;

  const OiAnalysisScreen({
    super.key,
    required this.appState,
    this.embeddedMode = false,
  });

  @override
  State<OiAnalysisScreen> createState() => _OiAnalysisScreenState();
}

class _OiAnalysisScreenState extends State<OiAnalysisScreen> {
  String _horizon = '15m'; // WP-2: Real snapshot horizons only (5m | 15m | 60m)

  int? _oiChgForHorizon(StrikeRowSnapshot r, {required bool isCall}) {
    if (_horizon == '5m') return isCall ? r.ceOiChange5m : r.peOiChange5m;
    if (_horizon == '60m') return isCall ? r.ceOiChange60m : r.peOiChange60m;
    return isCall ? r.ceOiChange15m : r.peOiChange15m;
  }

  Map<String, dynamic> _classifyBuildup(
      double priceChangePct, int? oiChange) {
    if (oiChange == null) {
      return {'label': 'Collecting $_horizon...', 'color': QuantTheme.textSecondary};
    }
    if (priceChangePct >= 0 && oiChange >= 0) {
      return {'label': 'Long Buildup', 'color': QuantTheme.positive};
    } else if (priceChangePct < 0 && oiChange >= 0) {
      return {'label': 'Short Buildup', 'color': QuantTheme.negative};
    } else if (priceChangePct >= 0 && oiChange < 0) {
      return {'label': 'Short Covering', 'color': QuantTheme.accent};
    } else {
      return {'label': 'Long Unwinding', 'color': QuantTheme.warning};
    }
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final rows = engine.optionChainRows[idx] ?? const <StrikeRowSnapshot>[];
    final chgPct = engine.spotChangePct[idx] ?? 0.0;

    if (engine.dataHealth != DataHealthStatus.live || rows.isEmpty) {
      return QuantPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              'NO DATA — Live broker connection required for real OI differencing.',
              textAlign: TextAlign.center,
              style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
            ),
          ),
        ),
      );
    }

    int totalCeOi = 0, totalPeOi = 0;
    int? totalCeChg, totalPeChg;
    for (final r in rows) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      final c = _oiChgForHorizon(r, isCall: true);
      final p = _oiChgForHorizon(r, isCall: false);
      if (c != null) totalCeChg = (totalCeChg ?? 0) + c;
      if (p != null) totalPeChg = (totalPeChg ?? 0) + p;
    }
    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 0.0;
    final displayRows = rows.where((r) => r.offset.abs() <= 5).toList();

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Real Snapshot OI Window:', style: QuantTheme.heading(size: 11)),
            Row(
              children: ['5m', '15m', '60m'].map((tf) {
                final active = _horizon == tf;
                return GestureDetector(
                  onTap: () => setState(() => _horizon = tf),
                  child: Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tf,
                      style: QuantTheme.mono(
                        size: 11,
                        color: active ? QuantTheme.bgMain : QuantTheme.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        const SizedBox(height: 10),
        QuantPanel(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              QuantMetricCell(
                label: 'TOTAL CE OI',
                value: '${totalCeOi}L',
                valueColor: QuantTheme.positive,
              ),
              QuantMetricCell(
                label: 'TOTAL PE OI',
                value: '${totalPeOi}L',
                valueColor: QuantTheme.negative,
              ),
              QuantMetricCell(
                label: 'LIVE PCR',
                value: pcr.toStringAsFixed(2),
                valueColor: QuantTheme.accent,
              ),
              QuantMetricCell(
                label: '$_horizon NET ΔOI',
                value: (totalCeChg != null && totalPeChg != null)
                    ? '${(totalPeChg - totalCeChg) >= 0 ? "+" : ""}${totalPeChg - totalCeChg}L'
                    : 'Collecting',
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        QuantPanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: QuantTheme.bgElevated,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Strike-Wise OI Heatmap & Buildup ($_horizon)',
                        style: QuantTheme.heading(size: 11)),
                    Text('Lots',
                        style: QuantTheme.mono(size: 10, color: QuantTheme.accent)),
                  ],
                ),
              ),
              ...displayRows.map((r) {
                final ceChg = _oiChgForHorizon(r, isCall: true);
                final peChg = _oiChgForHorizon(r, isCall: false);
                final ceClass = _classifyBuildup(chgPct, ceChg);
                final peClass = _classifyBuildup(-chgPct, peChg);
                return Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
                  decoration: const BoxDecoration(
                    border: Border(
                        bottom:
                            BorderSide(color: QuantTheme.border, width: 0.5)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ceChg != null
                                  ? 'CE ${ceChg >= 0 ? "+" : ""}${ceChg}L'
                                  : 'CE --',
                              style: QuantTheme.mono(
                                  size: 11, color: ceClass['color'] as Color),
                            ),
                            Text(ceClass['label'].toString(),
                                style: QuantTheme.label(
                                    size: 9, color: ceClass['color'] as Color)),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Center(
                          child: Text('${r.strike}',
                              style: QuantTheme.mono(
                                  size: 11, weight: FontWeight.w800)),
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              peChg != null
                                  ? 'PE ${peChg >= 0 ? "+" : ""}${peChg}L'
                                  : 'PE --',
                              style: QuantTheme.mono(
                                  size: 11, color: peClass['color'] as Color),
                            ),
                            Text(peClass['label'].toString(),
                                style: QuantTheme.label(
                                    size: 9, color: peClass['color'] as Color)),
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
      ],
    );

    if (widget.embeddedMode) return content;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: content,
    );
  }
}
