import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../core/ui_haptics.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/strike_selector.dart';
import '../../engine/execution_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/mtf_strategy_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/intel_layers_panel.dart';
import '../widgets/pnl_streak_heatmap.dart';
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
    final selectedIdx = appState.selectedIndex;
    final chain = engine.optionChainRows[selectedIdx] ?? const [];
    final spot = engine.spotPrices[selectedIdx] ?? 0.0;
    final activeExpiry = engine.selectedExpiry[selectedIdx] ?? '';
    final health = engine.dataHealth;
    final hasLiveData =
        health == DataHealthStatus.live && chain.isNotEmpty && spot > 0;
    final sig = appState.activeSignal;
    final regime = appState.activeRegime;
    final mlRep = appState.sadhuMlReport;

    int totalCeOi = 0;
    int totalPeOi = 0;
    StrikeRowSnapshot? atmRow;
    for (final r in chain) {
      totalCeOi += r.ceOi;
      totalPeOi += r.peOi;
      if (r.offset == 0) atmRow = r;
    }

    final pcr = (hasLiveData && totalCeOi > 0)
        ? (totalPeOi / totalCeOi.toDouble())
        : null;
    final tYears = activeExpiry.isNotEmpty
        ? StrikeSelectionEngine.computeFractionalYearsToExpiryIst(activeExpiry)
        : 0.0;
    final surf =
        hasLiveData ? MathGreeksEngine.evaluateIvSurface(chain, spot) : null;
    final gex = hasLiveData
        ? MathGreeksEngine.computeDealerPositioning(chain, spot,
            timeYears: tYears)
        : null;
    final marketSense = MtfStrategyEngine.evaluateMarketSense(
      chainRows: chain,
      spot: spot,
      expiryIso: activeExpiry,
      dataHealth: health,
      regime: regime,
    );

    final latencyMs = (engine.dataDelaySec * 1000).round();
    final syncTimeStr = engine.lastSyncTimestampMs > 0
        ? DateFormat('HH:mm:ss').format(
            DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs))
        : '--:--:--';

    final watchlist = chain.where((r) => r.offset.abs() <= 2).toList();
    final indices = UnderlyingIndex.values;

    return RefreshIndicator(
      color: QuantTheme.accent,
      backgroundColor: QuantTheme.bgPanel,
      onRefresh: () => appState.refreshAllIntelligenceLayers(force: true),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Sadhu AI Admin Command Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: QuantTheme.bgElevated,
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: QuantTheme.accent.withOpacity(0.5)),
                      ),
                      child: const Icon(Icons.auto_graph,
                          color: QuantTheme.accent, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Sadhu AI', style: QuantTheme.heading(size: 16)),
                        Text(
                          'Admin: Sadhu AI • ${mlRep.trained ? "ML Active" : "ML Ready"}',
                          style: QuantTheme.label(size: 10),
                        ),
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
                        UiHaptics.tap();
                        if (!ExecutionEngine.liveTradingUnlocked) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              backgroundColor: QuantTheme.warning,
                              content: Text(
                                'Sadhu AI is Paper-only until Phase 2 real broker adapter & 15-day paper gates pass.',
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
            const SizedBox(height: 12),

            // 2. Feed Health Telemetry Strip
            QuantPanel(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              backgroundColor: QuantTheme.bgSecondary,
              borderColor: _healthColor(health).withOpacity(0.55),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      '${engine.connectionStatusText} (${latencyMs}ms)',
                      style: QuantTheme.mono(
                          size: 10, color: _healthColor(health)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    'Sync $syncTimeStr',
                    style: QuantTheme.mono(
                        size: 10, color: QuantTheme.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 3. LAYER 3 (MACRO): Global Indices, USD/INR, DXY, US10Y, Brent & Gold
            MacroCuesStripCard(
              snapshot: appState.macroSnapshot,
              onRefresh: () => appState.refreshMacroNow(),
            ),
            const SizedBox(height: 12),

            // 4. Responsive 2x2 Four-Index Monitoring Grid
            Row(
              children: [
                Expanded(
                    child: _indexCard(indices[0], selectedIdx, engine, health)),
                const SizedBox(width: 10),
                Expanded(
                    child: _indexCard(indices[1], selectedIdx, engine, health)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                    child: _indexCard(indices[2], selectedIdx, engine, health)),
                const SizedBox(width: 10),
                Expanded(
                    child: _indexCard(indices[3], selectedIdx, engine, health)),
              ],
            ),
            const SizedBox(height: 14),

            // 5. LAYER 1 (MINOR): Futures Basis, Heavyweight Points, 0-DTE Straddle/Gamma & 15m ORB
            MinorIntradayIntelCard(
              index: selectedIdx,
              futuresBasis: appState.activeFuturesBasis,
              contribution: appState.activeContribution,
              straddleGamma: appState.activeStraddleGamma,
              orbLevels: appState.activeOrbLevels,
              hasLiveData: hasLiveData,
            ),
            const SizedBox(height: 14),

            // 6. Real Measured Market Regime & Dealer Positioning Panel
            QuantPanel(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Measured Regime (${selectedIdx.label})',
                          style: QuantTheme.heading(size: 12.5)),
                      QuantBadge(
                        text: !hasLiveData ? 'NO DATA' : regime.regimeLabel,
                        color: !hasLiveData
                            ? QuantTheme.negative
                            : (regime.regimeLabel.contains('BULL')
                                ? QuantTheme.positive
                                : (regime.regimeLabel.contains('BEAR')
                                    ? QuantTheme.negative
                                    : QuantTheme.warning)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!hasLiveData)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'NO DATA — Connect Angel One SmartAPI in Settings to compute real regime & Greeks.',
                        style: QuantTheme.mono(
                            size: 10.5, color: QuantTheme.negative),
                      ),
                    )
                  else ...[
                    if (!regime.hasSufficientData)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: QuantTheme.bgSecondary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: QuantTheme.border),
                        ),
                        child: Text(
                          regime.summaryNote,
                          style: QuantTheme.mono(
                              size: 10, color: QuantTheme.warning),
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          RegimeArcGauge(
                            bullProb: regime.bullProb,
                            bearProb: regime.bearProb,
                            chopProb: regime.chopProb,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              children: [
                                _probRow('Bullish Trend', regime.bullProb,
                                    QuantTheme.positive),
                                const SizedBox(height: 7),
                                _probRow('Bearish Trend', regime.bearProb,
                                    QuantTheme.negative),
                                const SizedBox(height: 7),
                                _probRow('Sideways / Chop', regime.chopProb,
                                    QuantTheme.warning),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          QuantMetricCell(
                            label: 'EFF. RATIO',
                            value: regime.efficiencyRatio != null
                                ? '${(regime.efficiencyRatio! * 100).toStringAsFixed(0)}%'
                                : 'N/A',
                          ),
                          QuantMetricCell(
                            label: 'ADX',
                            value: regime.adxValue != null
                                ? regime.adxValue!.toStringAsFixed(1)
                                : 'N/A',
                            valueColor: QuantTheme.accent,
                          ),
                          QuantMetricCell(
                            label: 'RV (PCTL)',
                            value: regime.realizedVolPct != null
                                ? '${regime.realizedVolPct!.toStringAsFixed(1)}% (P${regime.volPercentile?.toStringAsFixed(0) ?? "-"})'
                                : 'N/A',
                          ),
                          QuantMetricCell(
                            label: 'VWAP Δ',
                            value: regime.vwapDistancePct != null
                                ? '${regime.vwapDistancePct! >= 0 ? "+" : ""}${regime.vwapDistancePct!.toStringAsFixed(2)}%'
                                : 'N/A',
                            valueColor: (regime.vwapDistancePct ?? 0) >= 0
                                ? QuantTheme.positive
                                : QuantTheme.negative,
                          ),
                        ],
                      ),
                    ],
                    const Divider(color: QuantTheme.border, height: 18),
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
                      ],
                    ),
                    if (gex != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Walls: Put ${gex.putWallStrike} / Call ${gex.callWallStrike} | Flip: ${gex.gammaFlipSpot?.toStringAsFixed(0) ?? "N/A"} | ATM: ${atmRow?.strike ?? "-"}',
                        style: QuantTheme.label(size: 9.5),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 7. Sadhu AI Quick Trade Intelligence
            if (sig != null)
              QuantPanel(
                padding: const EdgeInsets.all(14),
                borderColor: sig.riskWithinLimits
                    ? QuantTheme.positive
                    : QuantTheme.border,
                onTap: () {
                  UiHaptics.tap();
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
                        Text('Sadhu AI Trade Intelligence',
                            style: QuantTheme.heading(size: 12.5)),
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
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          QuantMetricCell(
                              label: 'ENTRY',
                              value: '₹${sig.entryPremium.toStringAsFixed(1)}'),
                          QuantMetricCell(
                              label: 'SL',
                              value:
                                  '₹${sig.stopLossPremium.toStringAsFixed(1)}',
                              valueColor: QuantTheme.negative),
                          QuantMetricCell(
                              label: 'TARGET',
                              value: '₹${sig.targetPremium.toStringAsFixed(1)}',
                              valueColor: QuantTheme.positive),
                          QuantMetricCell(
                              label: 'CONF.',
                              value: '${sig.confidencePct.toStringAsFixed(0)}%',
                              valueColor: QuantTheme.accent),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 6),
                      Text(
                        marketSense.headline,
                        style: QuantTheme.label(size: 9.5),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 14),

            // 8. LAYER 2 (MAJOR): Official NSE Participant-Wise OI (FII / DII / Pro / Client)
            ParticipantOiCard(
              snapshot: appState.participantOi,
              onRefresh: () => appState.refreshParticipantOiNow(),
            ),
            const SizedBox(height: 14),

            // 9. Sadhu AI Journal Coach & 28-Day P&L Streak Heatmap
            PnlStreakHeatmapCard(summary: appState.journalSummary),
            const SizedBox(height: 14),

            // 10. Compact ATM ±2 Live Watchlist
            QuantPanel(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('ATM ±2 Watchlist (${selectedIdx.label})',
                          style: QuantTheme.heading(size: 12)),
                      GestureDetector(
                        onTap: () {
                          UiHaptics.tap();
                          onNavigateTab?.call(1);
                        },
                        child: const QuantBadge(
                            text: 'Open Chain & OI →',
                            color: QuantTheme.accent),
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  if (watchlist.isEmpty)
                    Text(
                      'Connect Angel One API to load live ATM option quotes.',
                      style: QuantTheme.label(size: 10.5),
                    )
                  else
                    ...watchlist.map((r) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'CE ₹${r.ceLtp.toStringAsFixed(2)} (${r.ceOi}L)',
                                style: QuantTheme.mono(
                                    size: 10.5, color: QuantTheme.positive),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: r.offset == 0
                                      ? QuantTheme.accent
                                      : QuantTheme.bgSecondary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${r.strike}',
                                  style: QuantTheme.mono(
                                    size: 10,
                                    color: r.offset == 0
                                        ? QuantTheme.bgMain
                                        : QuantTheme.textPrimary,
                                    weight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Text(
                                'PE ₹${r.peLtp.toStringAsFixed(2)} (${r.peOi}L)',
                                style: QuantTheme.mono(
                                    size: 10.5, color: QuantTheme.negative),
                              ),
                            ],
                          ),
                        )),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 11. DEDICATED BOTTOM SECTION: Live Official News & Announcements Wire (RBI / NSE / BSE)
            LiveNewsWireCard(
              items: appState.newsItems,
              lastFetchedMs: appState.newsLastFetchedMs,
              errorNote: appState.newsErrorNote,
              onRefresh: () => appState.refreshNewsNow(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _indexCard(
    UnderlyingIndex u,
    UnderlyingIndex selectedIdx,
    DhanDataEngine engine,
    DataHealthStatus health,
  ) {
    final active = u == selectedIdx;
    final sp = engine.spotPrices[u] ?? 0.0;
    final chg = engine.spotChangePct[u] ?? 0.0;
    final exp = engine.selectedExpiry[u] ?? '';
    final hasIdxData = sp > 0 && health != DataHealthStatus.disconnected;
    final isPos = chg >= 0;

    return QuantPanel(
      padding: const EdgeInsets.all(11),
      backgroundColor: active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
      borderColor: active ? QuantTheme.accent : QuantTheme.border,
      onTap: () {
        UiHaptics.tap();
        appState.setSelectedUnderlying(u);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                u.label,
                style: QuantTheme.heading(
                  size: 10.5,
                  color: active ? QuantTheme.accent : QuantTheme.textSecondary,
                ),
              ),
              if (hasIdxData)
                Text(
                  '${isPos ? "+" : ""}${chg.toStringAsFixed(2)}%',
                  style: QuantTheme.mono(
                    size: 9.5,
                    color: isPos ? QuantTheme.positive : QuantTheme.negative,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            hasIdxData ? sp.toStringAsFixed(2) : 'NO DATA',
            style: QuantTheme.mono(
              size: 13.5,
              color: hasIdxData ? QuantTheme.textPrimary : QuantTheme.negative,
              weight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            exp.isNotEmpty ? 'Exp: $exp' : 'Exp: --',
            style: QuantTheme.label(size: 9),
          ),
        ],
      ),
    );
  }

  Widget _probRow(String label, double prob, Color col) {
    final p = prob.clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: QuantTheme.label(size: 10)),
            Text('${(p * 100).toStringAsFixed(0)}%',
                style: QuantTheme.mono(size: 10, color: col)),
          ],
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: p,
            minHeight: 4.5,
            backgroundColor: QuantTheme.bgSecondary,
            valueColor: AlwaysStoppedAnimation(col),
          ),
        ),
      ],
    );
  }
}
