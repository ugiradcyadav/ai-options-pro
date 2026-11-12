import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/mtf_strategy_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/v2_control_dialogs.dart';
import 'signal_details_screen.dart';

class HomeScreen extends StatelessWidget {
  final AppState appState;
  final void Function(int)? onNavigateTab;

  const HomeScreen({
    super.key,
    required this.appState,
    this.onNavigateTab,
  });

  @override
  Widget build(BuildContext context) {
    final engine = DhanDataEngine.instance;
    final ai = AiRecalibrationEngine.instance;
    final selectedIdx = appState.selectedIndex;
    final chain = engine.optionChainRows[selectedIdx] ?? [];
    final spot = engine.spotPrices[selectedIdx] ?? 0.0;
    final activeExpiry = engine.selectedExpiry[selectedIdx] ?? 'Nearest';
    final sig = appState.activeSignal;

    int totalCeOi = 0;
    int totalPeOi = 0;
    StrikeRowSnapshot? atmRow;
    for (final r in chain) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      if (r.offset == 0) atmRow = r;
    }
    if (atmRow == null && chain.isNotEmpty) {
      atmRow = chain[chain.length ~/ 2];
    }

    final pcr = totalCeOi > 0 ? (totalPeOi / totalCeOi.toDouble()) : 1.0;
    final vix = atmRow != null ? (0.5 * (atmRow.ceIv + atmRow.peIv)) : 14.85;
    final gex = MathGreeksEngine.computeDealerPositioning(
      chain,
      spot > 0 ? spot : (atmRow?.strike.toDouble() ?? 23050.0),
      lotSize: selectedIdx.defaultLotSize,
    );
    final marketSense = MtfStrategyEngine.evaluateMarketSense(chain);

    final latencyMs = (engine.dataDelaySec * 1000).round();
    final syncTimeStr = engine.lastSyncTimestampMs > 0
        ? DateFormat('HH:mm:ss').format(
            DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs))
        : '--:--:--';
    final ageSec = engine.lastSyncTimestampMs > 0
        ? ((DateTime.now().millisecondsSinceEpoch - engine.lastSyncTimestampMs) /
                1000.0)
            .clamp(0.0, 999.0)
        : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Top Command Header Bar
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
                      Text('Quant Trading Terminal',
                          style: QuantTheme.label(size: 10)),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  GestureDetector(
                    onTap: () async {
                      if (!appState.isLiveMode) {
                        final ok =
                            await V2ControlDialogs.confirmSwitchToLive(context);
                        if (ok == true) appState.toggleTradingMode(true);
                      } else {
                        appState.toggleTradingMode(false);
                      }
                    },
                    child: QuantBadge(
                      text: appState.isLiveMode ? 'LIVE' : 'PAPER',
                      color: appState.isLiveMode
                          ? QuantTheme.negative
                          : QuantTheme.positive,
                      icon: Icons.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => onNavigateTab?.call(4),
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: QuantTheme.bgPanel,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: QuantTheme.border),
                      ),
                      child: const Icon(Icons.settings_outlined,
                          color: QuantTheme.textSecondary, size: 17),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 2. Connection Status, Feed Health, Freshness & AI Engine Telemetry Strip
          QuantPanel(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            backgroundColor: QuantTheme.bgSecondary,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.fiber_manual_record,
                      size: 10,
                      color: engine.isConnected
                          ? QuantTheme.positive
                          : QuantTheme.warning,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${engine.connectionStatusText} • ${latencyMs}ms',
                      style: QuantTheme.mono(
                        size: 11,
                        color: engine.isConnected
                            ? QuantTheme.positive
                            : QuantTheme.warning,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Sync $syncTimeStr (${ageSec.toStringAsFixed(1)}s) | ${ai.activeModel.passedEvaluationGate ? "AI Gate OK" : "Shadow/Rules"}',
                  style: QuantTheme.mono(size: 10, color: QuantTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 3. Three-Index Monitoring Strip (NIFTY 50 | BANK NIFTY | FINNIFTY)
          Row(
            children: UnderlyingIndex.values.map((u) {
              final active = u == selectedIdx;
              final sp = engine.spotPrices[u] ?? 0.0;
              final chg = engine.spotChangePct[u] ?? 0.0;
              final isPos = chg >= 0;
              final exp = engine.selectedExpiry[u] ?? '';
              return Expanded(
                child: QuantPanel(
                  margin: EdgeInsets.only(
                    right: u != UnderlyingIndex.finNifty ? 6 : 0,
                  ),
                  padding: const EdgeInsets.all(9),
                  backgroundColor:
                      active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
                  borderColor:
                      active ? QuantTheme.accent : QuantTheme.border,
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
                        sp > 0 ? sp.toStringAsFixed(2) : 'Syncing...',
                        style: QuantTheme.mono(
                          size: 13,
                          color: QuantTheme.textPrimary,
                          weight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${isPos ? "+" : ""}${chg.toStringAsFixed(2)}% ${isPos ? "▲" : "▼"}',
                        style: QuantTheme.mono(
                          size: 10,
                          color: isPos
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                        ),
                      ),
                      if (exp.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Exp: $exp',
                          style: QuantTheme.label(size: 9),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),

          // 4. Market Regime Analysis Panel (Gauge + Bull/Bear/Chop + PCR, VIX, GEX, MaxPain & Walls)
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
                      color: marketSense.badge == 'Bullish'
                          ? QuantTheme.positive
                          : (marketSense.badge == 'Bearish'
                              ? QuantTheme.negative
                              : QuantTheme.warning),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
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
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                      value: pcr.toStringAsFixed(2),
                      valueColor: pcr >= 1.0
                          ? QuantTheme.positive
                          : QuantTheme.negative,
                    ),
                    QuantMetricCell(
                      label: 'ATM IV / VIX',
                      value: '${vix.toStringAsFixed(2)}%',
                      valueColor: QuantTheme.accent,
                    ),
                    QuantMetricCell(
                      label: 'NET GEX',
                      value:
                          '${gex.netGexCr >= 0 ? "+" : ""}${gex.netGexCr.toStringAsFixed(1)}Cr',
                      valueColor: gex.netGexCr >= 0
                          ? QuantTheme.positive
                          : QuantTheme.warning,
                    ),
                    QuantMetricCell(
                      label: 'MAX PAIN',
                      value: '${gex.maxPainStrike}',
                    ),
                    QuantMetricCell(
                      label: 'PUT / CALL WALL',
                      value: '${gex.putWallStrike}/${gex.callWallStrike}',
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '* ${gex.assumptionNote} ATM: ${atmRow?.strike ?? "-"} | Exp: $activeExpiry',
                  style: QuantTheme.label(size: 9),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 5. Quick Trade Intelligence Panel (Tappable -> SignalDetailsScreen)
          if (sig != null)
            QuantPanel(
              borderColor: sig.action != SignalAction.noTrade
                  ? QuantTheme.positive.withOpacity(0.7)
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
                      Row(
                        children: [
                          const Icon(Icons.bolt,
                              color: QuantTheme.positive, size: 16),
                          const SizedBox(width: 4),
                          Text('Quick Trade Intelligence',
                              style: QuantTheme.heading(size: 12)),
                        ],
                      ),
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
                        ? '${sig.index.label} ${sig.strike} ${sig.action == SignalAction.buyCe ? "CE" : "PE"} • Exp: ${sig.expiry}'
                        : '${sig.index.label} • ${sig.riskNote}',
                    style: QuantTheme.mono(size: 12, color: QuantTheme.accent),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      QuantMetricCell(
                        label: 'ENTRY',
                        value: '₹${sig.entryPremium.toStringAsFixed(2)}',
                      ),
                      QuantMetricCell(
                        label: 'STOP LOSS',
                        value: '₹${sig.stopLossPremium.toStringAsFixed(2)}',
                        valueColor: QuantTheme.negative,
                      ),
                      QuantMetricCell(
                        label: 'TARGET',
                        value: '₹${sig.targetPremium.toStringAsFixed(2)}',
                        valueColor: QuantTheme.positive,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: QuantTheme.bgElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: QuantTheme.border),
                        ),
                        child: Column(
                          children: [
                            Text('CONF', style: QuantTheme.label(size: 9)),
                            Text(
                              '${sig.confidencePct.toStringAsFixed(0)}%',
                              style: QuantTheme.mono(
                                size: 13,
                                color: QuantTheme.positive,
                                weight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),

          // 6. Compact Market Intelligence Insights Panel
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.lightbulb_outline,
                            color: QuantTheme.warning, size: 15),
                        const SizedBox(width: 6),
                        Text('Institutional Telemetry & Insights',
                            style: QuantTheme.heading(size: 12)),
                      ],
                    ),
                    GestureDetector(
                      onTap: () => onNavigateTab?.call(2),
                      child: Text('View Signals →',
                          style: QuantTheme.label(
                              size: 11, color: QuantTheme.accent)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  marketSense.headline,
                  style: QuantTheme.mono(
                    size: 11,
                    color: QuantTheme.textSecondary,
                    weight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 7. ATM ±2 Strike Watchlist Panel
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('ATM ±2 Strike Watchlist (${selectedIdx.label})',
                        style: QuantTheme.heading(size: 12)),
                    GestureDetector(
                      onTap: () => onNavigateTab?.call(1),
                      child: Text('Open Market Workspace →',
                          style: QuantTheme.label(
                              size: 11, color: QuantTheme.accent)),
                    ),
                  ],
                ),
                const Divider(color: QuantTheme.border, height: 14),
                if (chain.isEmpty)
                  Text('Syncing live option chain strikes...',
                      style: QuantTheme.label(size: 11))
                else
                  ...chain.map((r) {
                    final isAtm = r.offset == 0;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 6),
                      decoration: BoxDecoration(
                        color: isAtm
                            ? QuantTheme.bgElevated.withOpacity(0.7)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'CE ₹${r.ceLtp.toStringAsFixed(2)} (${QuantTheme.fmtLakhs(r.ceOi)})',
                            style: QuantTheme.mono(
                                size: 11, color: QuantTheme.positive),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: isAtm
                                  ? QuantTheme.accent.withOpacity(0.2)
                                  : QuantTheme.bgSecondary,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: isAtm
                                    ? QuantTheme.accent
                                    : QuantTheme.border,
                              ),
                            ),
                            child: Text(
                              '${r.strike}${isAtm ? " ATM" : ""}',
                              style: QuantTheme.mono(
                                size: 11,
                                color: isAtm
                                    ? QuantTheme.accent
                                    : QuantTheme.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            'PE ₹${r.peLtp.toStringAsFixed(2)} (${QuantTheme.fmtLakhs(r.peOi)})',
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
          const SizedBox(height: 10),

          // 8. Quick Actions Strip
          Row(
            children: [
              _quickBtn('Market & OI', Icons.candlestick_chart,
                  () => onNavigateTab?.call(1)),
              const SizedBox(width: 6),
              _quickBtn('Signals Center', Icons.radar,
                  () => onNavigateTab?.call(2)),
              const SizedBox(width: 6),
              _quickBtn('Orders & Risk', Icons.account_balance_wallet_outlined,
                  () => onNavigateTab?.call(3)),
              const SizedBox(width: 6),
              _quickBtn('Lab & Backtest', Icons.science_outlined,
                  () => onNavigateTab?.call(4)),
            ],
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

  Widget _quickBtn(String title, IconData icon, VoidCallback onTap) {
    return Expanded(
      child: QuantPanel(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        onTap: onTap,
        child: Column(
          children: [
            Icon(icon, color: QuantTheme.accent, size: 18),
            const SizedBox(height: 4),
            Text(
              title,
              textAlign: TextAlign.center,
              style: QuantTheme.label(size: 10, color: QuantTheme.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
