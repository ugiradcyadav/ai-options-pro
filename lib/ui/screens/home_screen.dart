import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../core/ui_haptics.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../data/strike_selector.dart';
import '../../engine/execution_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/mtf_strategy_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/intel_layers_panel.dart';
import '../widgets/pnl_streak_heatmap.dart';
import 'signal_details_screen.dart';

class HomeScreen extends StatefulWidget {
  final AppState appState;
  final void Function(int)? onNavigateTab;

  const HomeScreen({
    super.key,
    required this.appState,
    this.onNavigateTab,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<UnderlyingIndex, List<double>> _sparkSeries = {};
  int _lastSparkSyncMs = 0;

  Color _healthColor(DataHealthStatus status) {
    if (status == DataHealthStatus.live) return QuantTheme.positive;
    if (status == DataHealthStatus.delayed) return QuantTheme.warning;
    return QuantTheme.negative;
  }

  Future<void> _refreshSparklinesIfNeeded() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSparkSyncMs < 25000) return;
    _lastSparkSyncMs = nowMs;
    bool changed = false;
    for (final u in UnderlyingIndex.values) {
      try {
        final bars = await ForeverDatabase.instance.getRecentBars(
          indexName: u.label,
          optionType: 'SPOT',
          limit: 24,
        );
        final pts = bars
            .where((b) => b.close > 0)
            .map((b) => b.close)
            .toList();
        if (pts.length >= 2) {
          _sparkSeries[u] = pts;
          changed = true;
        }
      } catch (_) {}
    }
    if (changed && mounted) setState(() => {});
  }

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    final engine = DhanDataEngine.instance;
    final selectedIdx = appState.selectedIndex;
    final chain = engine.optionChainRows[selectedIdx] ?? const [];
    final spot = engine.spotPrices[selectedIdx] ?? 0.0;
    final activeExpiry = engine.selectedExpiry[selectedIdx] ?? '';
    final health = engine.dataHealth;
    final hasSpotData = health != DataHealthStatus.disconnected && spot > 0;
    final hasLiveData = hasSpotData && chain.isNotEmpty;
    final sig = appState.activeSignal;
    final regime = appState.activeRegime;
    final mlRep = appState.sadhuMlReport;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSparkSyncMs >= 25000) {
      Future.microtask(_refreshSparklinesIfNeeded);
    }

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
      color: QuantTheme.headerNavy,
      backgroundColor: QuantTheme.bgPanel,
      onRefresh: () async {
        _lastSparkSyncMs = 0;
        await appState.refreshAllIntelligenceLayers(force: true);
        await _refreshSparklinesIfNeeded();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Sadhu AI Navy Command Header with Blended Founder Portrait & Avatar
            _buildNavyFounderHeader(context, health, mlRep.trained),
            const SizedBox(height: 12),

            // 2. Feed Health Telemetry Strip
            QuantPanel(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              backgroundColor: QuantTheme.bgPanel,
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

            // 4. Responsive 2x2 Four-Index Grid with Live Intraday Sparklines
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

            // 5. LAYER 1 (MINOR): Futures Basis, 0-DTE Straddle Decay, Depth Ladder, Heavyweights & ORB
            MinorIntradayIntelCard(
              index: selectedIdx,
              futuresBasis: appState.activeFuturesBasis,
              contribution: appState.activeContribution,
              straddleGamma: appState.activeStraddleGamma,
              orbLevels: appState.activeOrbLevels,
              chainRows: chain,
              straddleHistory:
                  appState.straddleSeriesMap[selectedIdx] ?? const [],
              hasLiveData: hasSpotData,
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
                        text: !hasSpotData ? 'NO DATA' : regime.regimeLabel,
                        color: !hasSpotData
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
                  if (!hasSpotData)
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
                          color: QuantTheme.bgMain,
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
                                      ? QuantTheme.headerNavy
                                      : QuantTheme.bgMain,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${r.strike}',
                                  style: QuantTheme.mono(
                                    size: 10,
                                    color: r.offset == 0
                                        ? Colors.white
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

            // 11. DEDICATED BOTTOM SECTION: Official Announcements Wire (RBI / NSE / BSE)
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

  Widget _buildNavyFounderHeader(
    BuildContext context,
    DataHealthStatus health,
    bool mlTrained,
  ) {
    final hCol = _healthColor(health);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: QuantTheme.headerNavy,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: QuantTheme.headerNavySoft, width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F0F1E36),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Soft right-side photo blend inside deep navy command bar
          Positioned.fill(
            child: Row(
              children: [
                const Expanded(flex: 4, child: SizedBox.shrink()),
                Expanded(
                  flex: 6,
                  child: Opacity(
                    opacity: 0.36,
                    child: Image.asset(
                      'assets/images/sadhu_founder.png',
                      fit: BoxFit.cover,
                      alignment: const Alignment(0.15, -0.35),
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Left-to-right navy gradient fade so foreground text & badges stay sharp
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    QuantTheme.headerNavy,
                    Color(0xE60F1E36),
                    Color(0x660F1E36),
                  ],
                  stops: [0.0, 0.52, 1.0],
                ),
              ),
            ),
          ),
          // Foreground Header Content
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: QuantTheme.positive.withOpacity(0.85),
                            width: 1.6),
                        color: QuantTheme.headerNavySoft,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.asset(
                        'assets/images/sadhu_founder.png',
                        fit: BoxFit.cover,
                        alignment: const Alignment(0.15, -0.35),
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.auto_graph,
                            color: Colors.white,
                            size: 18),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Sadhu AI',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                          ),
                        ),
                        Text(
                          'Admin • ${mlTrained ? "ML Active" : "ML Ready"}',
                          style: const TextStyle(
                            color: Color(0xFFCBD5E1),
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Row(
                  children: [
                    QuantBadge(
                      text: health.label,
                      color: hCol,
                      icon: Icons.circle,
                      darkSurface: true,
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        UiHaptics.tap();
                        if (!ExecutionEngine.liveTradingUnlocked) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              backgroundColor: QuantTheme.headerNavy,
                              content: Text(
                                'Sadhu AI is Paper-only until Phase 2 real broker adapter & 15-day paper gates pass.',
                              ),
                            ),
                          );
                        }
                      },
                      child: const QuantBadge(
                        text: 'PAPER',
                        color: Color(0xFF34D399),
                        darkSurface: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
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
    final sparkPts = _sparkSeries[u] ?? const <double>[];

    return QuantPanel(
      padding: const EdgeInsets.all(11),
      backgroundColor: active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
      borderColor: active ? QuantTheme.headerNavy : QuantTheme.border,
      onTap: () {
        UiHaptics.tap();
        widget.appState.setSelectedUnderlying(u);
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
                  color:
                      active ? QuantTheme.headerNavy : QuantTheme.textSecondary,
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  hasIdxData ? sp.toStringAsFixed(2) : 'NO DATA',
                  style: QuantTheme.mono(
                    size: 13,
                    color:
                        hasIdxData ? QuantTheme.textPrimary : QuantTheme.negative,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
              if (sparkPts.length >= 2)
                SizedBox(
                  width: 44,
                  height: 20,
                  child: CustomPaint(
                    painter: MiniSeriesPainter(
                      values: sparkPts,
                      color: isPos ? QuantTheme.positive : QuantTheme.negative,
                    ),
                  ),
                ),
            ],
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
            backgroundColor: QuantTheme.bgMain,
            valueColor: AlwaysStoppedAnimation(col),
          ),
        ),
      ],
    );
  }
}
