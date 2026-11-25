import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/strike_selector.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/execution_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/mtf_strategy_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import 'signal_details_screen.dart';

class HomeScreen extends StatelessWidget {
  final AppState appState;
  final void Function(int)? onNavigateTab;

  const HomeScreen({
    super.key,
    required this.appState,
    this.onNavigateTab,
  });

  Color _healthColor(DataHealthStatus status) {
    if (status == DataHealthStatus.live) return QuantTheme.positive;
    if (status == DataHealthStatus.delayed) return QuantTheme.warning;
    return QuantTheme.negative;
  }

  @override
  Widget build(BuildContext context) {
    final engine = DhanDataEngine.instance;
    final ai = AiRecalibrationEngine.instance;
    final selectedIdx = appState.selectedIndex;
    final chain = engine.optionChainRows[selectedIdx] ?? const [];
    final spot = engine.spotPrices[selectedIdx] ?? 0.0;
    final activeExpiry = engine.selectedExpiry[selectedIdx] ?? '';
    final health = engine.dataHealth;
    final hasLiveData =
        health == DataHealthStatus.live && chain.isNotEmpty && spot > 0;
    final sig = appState.activeSignal;

    int totalCeOi = 0;
    int totalPeOi = 0;
    StrikeRowSnapshot? atmRow;
    for (final r in chain) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      if (r.offset == 0) atmRow = r;
    }

    final pcr =
        (hasLiveData && totalCeOi > 0) ? (totalPeOi / totalCeOi.toDouble()) : null;
    final tYears = activeExpiry.isNotEmpty
        ? StrikeSelectionEngine.computeFractionalYearsToExpiryIst(activeExpiry)
        : 0.0;
    final surf = hasLiveData
        ? MathGreeksEngine.evaluateIvSurface(chain, spot)
        : null;
    final gex = hasLiveData
        ? MathGreeksEngine.computeDealerPositioning(chain, spot, timeYears: tYears)
        : null;
    final marketSense = MtfStrategyEngine.evaluateMarketSense(
      chainRows: chain,
      spot: spot,
      expiryIso: activeExpiry,
      dataHealth: health,
    );

    final latencyMs = (engine.dataDelaySec * 1000).round();
    final syncTimeStr = engine.lastSyncTimestampMs > 0
        ? DateFormat('HH:mm:ss').format(
            DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs))
        : '--:--:--';

    // Watchlist shows ATM +/- 2 slice from the full chain
    final watchlist = chain.where((r) => r.offset.abs() <= 2).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Command Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: QuantTheme.bgElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: QuantTheme.border),
                    ),
                    child: const Icon(Icons.stacked_line_chart,
                        color: QuantTheme.accent, size: 18),
                  ),
                  const SizedBox(width: 9),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AI Options Pro', style: QuantTheme.heading(size: 15)),
                      Text('On-Device Quant Terminal (750ms)',
                          style: QuantTheme.label(size: 10)),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  QuantBadge(
                    text: health.label,
                    color: _healthColor(health),
                    icon: Icons.circle,
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      if (!ExecutionEngine.liveTradingUnlocked) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            backgroundColor: QuantTheme.warning,
                            content: Text(
                              'LIVE mode is locked until 15 real-data paper trading days & static-IP rules are verified.',
                            ),
                          ),
                        );
                      }
                    },
                    child: const QuantBadge(
                      text: 'PAPER',
                      color: QuantTheme.positive,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 2. Feed Health Telemetry Strip
          QuantPanel(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            backgroundColor: QuantTheme.bgSecondary,
            borderColor: _healthColor(health).withOpacity(0.6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '${engine.connectionStatusText} (${latencyMs}ms)',
                    style: QuantTheme.mono(size: 10, color: _healthColor(health)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  'Sync $syncTimeStr',
                  style: QuantTheme.mono(size: 10, color: QuantTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 3. Three-Index Monitoring Strip
          Row(
            children: UnderlyingIndex.values.map((u) {
              final active = u == selectedIdx;
              final sp = engine.spotPrices[u] ?? 0.0;
              final chg = engine.spotChangePct[u] ?? 0.0;
              final exp = engine.selectedExpiry[u] ?? '';
              final hasIdxData = sp > 0 && health != DataHealthStatus.disconnected;
              final isPos = chg >= 0;

              return Expanded(
                child: QuantPanel(
                  margin: EdgeInsets.only(
                      right: u != UnderlyingIndex.values.last ? 6 : 0),
                  padding: const EdgeInsets.all(9),
                  backgroundColor:
                      active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
                  borderColor: active ? QuantTheme.accent : QuantTheme.border,
                  onTap: () => appState.setSelectedUnderlying(u),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        u.label,
                        style: QuantTheme.heading(
                          size: 10,
                          color: active
                              ? QuantTheme.accent
                              : QuantTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasIdxData ? sp.toStringAsFixed(2) : 'NO DATA',
                        style: QuantTheme.mono(
                          size: 12,
                          color: hasIdxData
                              ? QuantTheme.textPrimary
                              : QuantTheme.negative,
                          weight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasIdxData
                            ? '${isPos ? "+" : ""}${chg.toStringAsFixed(2)}% ${isPos ? "▲" : "▼"}'
                            : '--',
                        style: QuantTheme.mono(
                          size: 10,
                          color: hasIdxData
                              ? (isPos ? QuantTheme.positive : QuantTheme.negative)
                              : QuantTheme.textSecondary,
                        ),
                      ),
                      Text(
                        exp.isNotEmpty ? 'Exp: $exp' : 'Exp: --',
                        style: QuantTheme.label(size: 9),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),

          // 4. Market Regime & Dealer Positioning Panel
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Market Regime Analysis (${selectedIdx.label})',
                        style: QuantTheme.heading(size: 12)),
                    QuantBadge(
                      text: marketSense.badge.toUpperCase(),
                      color: !hasLiveData
                          ? QuantTheme.negative
                          : (marketSense.badge == 'Bullish'
                              ? QuantTheme.positive
                              : (marketSense.badge == 'Bearish'
                                  ? QuantTheme.negative
                                  : QuantTheme.warning)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (!hasLiveData)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      'NO DATA — Connect Angel One or Dhan broker API in Settings to stream real exchange quotes.',
                      style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      RegimeArcGauge(
                        bullProb: ai.probBullRegime,
                        bearProb: ai.probBearRegime,
                        chopProb: ai.probChopRegime,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          children: [
                            _probRow('Bullish Regime', ai.probBullRegime,
                                QuantTheme.positive),
                            const SizedBox(height: 6),
                            _probRow('Bearish Regime', ai.probBearRegime,
                                QuantTheme.negative),
                            const SizedBox(height: 6),
                            _probRow('Sideways / Chop', ai.probChopRegime,
                                QuantTheme.warning),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      QuantMetricCell(
                        label: 'LIVE PCR',
                        value: pcr != null ? pcr.toStringAsFixed(2) : 'N/A',
                        valueColor: QuantTheme.accent,
                      ),
                      QuantMetricCell(
                        label: 'ATM IV',
                        value: surf?.atmIv != null
                            ? '${surf!.atmIv!.toStringAsFixed(2)}%'
                            : 'N/A',
                        valueColor: QuantTheme.accent,
                      ),
                      QuantMetricCell(
                        label: 'NET GEX',
                        value: gex != null
                            ? '${gex.netGexCr >= 0 ? "+" : ""}${gex.netGexCr.toStringAsFixed(2)}Cr'
                            : 'N/A',
                      ),
                      QuantMetricCell(
                        label: 'MAX PAIN',
                        value: gex != null && gex.maxPainStrike > 0
                            ? '${gex.maxPainStrike}'
                            : 'N/A',
                      ),
                      QuantMetricCell(
                        label: 'PUT/CALL WALL',
                        value: gex != null
                            ? '${gex.putWallStrike}/${gex.callWallStrike}'
                            : 'N/A',
                      ),
                    ],
                  ),
                  if (gex != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '* ${gex.assumptionNote} Flip: ${gex.gammaFlipSpot?.toStringAsFixed(1) ?? "N/A"} | ATM: ${atmRow?.strike ?? "-"}',
                      style: QuantTheme.label(size: 9),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 5. Quick Trade Intelligence
          if (sig != null)
            QuantPanel(
              borderColor: sig.riskWithinLimits
                  ? QuantTheme.positive
                  : QuantTheme.border,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SignalDetailsScreen(
                      appState: appState,
                      signal: sig,
                    ),
                  ),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Quick Trade Intelligence',
                          style: QuantTheme.heading(size: 12)),
                      QuantBadge(
                        text: sig.action.label,
                        color: sig.action == SignalAction.buyCe
                            ? QuantTheme.positive
                            : (sig.action == SignalAction.buyPe
                                ? QuantTheme.negative
                                : QuantTheme.warning),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    sig.strike > 0
                        ? '${sig.tradingSymbol.isNotEmpty ? sig.tradingSymbol : "${sig.index.label} ${sig.strike}"} • Qty ${sig.quantity}'
                        : sig.riskNote,
                    style: QuantTheme.mono(size: 11, color: QuantTheme.accent),
                  ),
                  if (sig.strike > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        QuantMetricCell(
                            label: 'ENTRY',
                            value: '₹${sig.entryPremium.toStringAsFixed(2)}'),
                        QuantMetricCell(
                            label: 'STOP LOSS',
                            value: '₹${sig.stopLossPremium.toStringAsFixed(2)}',
                            valueColor: QuantTheme.negative),
                        QuantMetricCell(
                            label: 'TARGET',
                            value: '₹${sig.targetPremium.toStringAsFixed(2)}',
                            valueColor: QuantTheme.positive),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 10),

          // 6. Market Intelligence Insights
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Institutional Telemetry',
                    style: QuantTheme.heading(size: 12)),
                const SizedBox(height: 6),
                Text(
                  marketSense.headline,
                  style: QuantTheme.mono(
                      size: 10, color: QuantTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 7. ATM ±2 Watchlist
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('ATM ±2 Watchlist (${selectedIdx.label})',
                        style: QuantTheme.heading(size: 12)),
                    GestureDetector(
                      onTap: () => onNavigateTab?.call(1),
                      child: Text('Market Workspace →',
                          style: QuantTheme.label(
                              size: 11, color: QuantTheme.accent)),
                    ),
                  ],
                ),
                const Divider(color: QuantTheme.border, height: 14),
                if (!hasLiveData || watchlist.isEmpty)
                  Text('NO DATA — Awaiting live broker option chain.',
                      style: QuantTheme.label(size: 11))
                else
                  ...watchlist.map((r) {
                    final isAtm = r.offset == 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'CE ₹${r.ceLtp.toStringAsFixed(2)} (${r.ceOi}L)',
                            style: QuantTheme.mono(
                                size: 11, color: QuantTheme.positive),
                          ),
                          Text(
                            '${r.strike}${isAtm ? " ATM" : ""}',
                            style: QuantTheme.mono(
                              size: 11,
                              color: isAtm
                                  ? QuantTheme.accent
                                  : QuantTheme.textPrimary,
                            ),
                          ),
                          Text(
                            'PE ₹${r.peLtp.toStringAsFixed(2)} (${r.peOi}L)',
                            style: QuantTheme.mono(
                                size: 11, color: QuantTheme.negative),
                          ),
                        ],
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

  Widget _probRow(String label, double prob, Color color) {
    final pct = (prob * 100.0).clamp(0.0, 100.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: QuantTheme.label(size: 10)),
            Text('${pct.toStringAsFixed(1)}%',
                style: QuantTheme.mono(size: 11, color: color)),
          ],
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (pct / 100.0).clamp(0.02, 1.0),
            minHeight: 5,
            backgroundColor: QuantTheme.bgSecondary,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}
