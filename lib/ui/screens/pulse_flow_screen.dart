import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../core/ui_haptics.dart';
import '../../data/angel_ws_streamer.dart';
import '../../data/constituent_flow_engine.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/flow_data_engine.dart';
import '../../data/forever_db.dart';
import '../../data/tv_screener_engine.dart';
import '../../engine/trendline_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/flow_painters.dart';

class PulseFlowScreen extends StatefulWidget {
  final AppState appState;

  const PulseFlowScreen({super.key, required this.appState});

  @override
  State<PulseFlowScreen> createState() => _PulseFlowScreenState();
}

class _PulseFlowScreenState extends State<PulseFlowScreen>
    with SingleTickerProviderStateMixin {
  String _subTab = 'Overview';
  String _scannerMode = 'GAINERS';
  bool _scannerLoading = false;
  bool _showAllConstituents = false;
  List<TvScannerStock> _scannerStocks = [];
  bool _motionPaused = false;
  ConstituentFlowItem? _selectedStock;
  List<OneMinEnrichedBar> _recentBars = [];
  late AnimationController _animCtrl;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _refreshAllFlowData(forceConstituents: true);
    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _refreshAllFlowData();
    });
  }

  @override
  void didUpdateWidget(covariant PulseFlowScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState.selectedIndex != widget.appState.selectedIndex) {
      _selectedStock = null;
      _showAllConstituents = false;
    }
    _refreshAllFlowData();
  }

  Future<void> _refreshAllFlowData({bool forceConstituents = false}) async {
    final idx = widget.appState.selectedIndex;
    await Future.wait([
      FlowDataEngine.instance.refreshSectoralFlow(),
      ConstituentFlowEngine.instance
          .refreshForIndex(idx, force: forceConstituents),
    ]);
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: idx.label,
      optionType: 'CE',
      limit: 60,
    );
    if (!mounted) return;
    setState(() {
      _recentBars = bars.reversed.toList();
    });
  }

  Future<void> _loadTvScanner({String? mode}) async {
    final targetMode = mode ?? _scannerMode;
    setState(() {
      _scannerMode = targetMode;
      _scannerLoading = true;
    });
    final res = await TvScreenerEngine.instance
        .fetchTopNseMovers(mode: targetMode, limit: 15);
    if (!mounted) return;
    setState(() {
      _scannerStocks = res;
      _scannerLoading = false;
    });
  }

  void _toggleMotion() {
    UiHaptics.tap();
    setState(() {
      _motionPaused = !_motionPaused;
      if (_motionPaused) {
        _animCtrl.stop();
      } else {
        _animCtrl.repeat();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final flow = FlowDataEngine.instance;
    final ws = AngelWsStreamer.instance;
    final constSnap = ConstituentFlowEngine.instance.getSnapshot(idx);
    final health = engine.dataHealth;
    final spot = engine.spotPrices[idx] ?? 0.0;
    final chgPct = engine.spotChangePct[idx] ?? 0.0;
    final rows =
        engine.optionChainRows[idx] ?? const <StrikeRowSnapshot>[];
    final hasLive = health == DataHealthStatus.live && spot > 0;

    // Real breadth from the active index's own constituents
    final items = constSnap?.items ?? const <ConstituentFlowItem>[];
    final advCount = items.where((e) => e.isInflow).length;
    final decCount = items.length - advCount;
    final breadthPct =
        items.isNotEmpty ? ((advCount / items.length) * 100.0).round() : null;
    final breadthColor = breadthPct == null
        ? QuantTheme.negative
        : (breadthPct >= 55
            ? QuantTheme.positive
            : (breadthPct <= 45 ? QuantTheme.negative : QuantTheme.warning));

    final vix = flow.indiaVix;
    final vixLabel = vix == null
        ? 'NO DATA'
        : (vix >= 16.0 ? 'Elevated' : (vix <= 12.5 ? 'Calm' : 'Normal'));

    final injections = flow.computeOptionCapitalInjection(idx);
    final rawRadar = flow.computeRadarAxes(
      index: idx,
      recentBars: _recentBars,
    );
    final srTrend = TrendlineEngine.detect(_recentBars);
    final radarAxes = RadarSignalAxes(
      oiScore: rawRadar.oiScore,
      optionsScore: rawRadar.optionsScore,
      vwapScore: rawRadar.vwapScore,
      volProfileScore: rawRadar.volProfileScore,
      rsiScore: rawRadar.rsiScore,
      priceActionScore: rawRadar.priceActionScore,
      vixCalmScore: rawRadar.vixCalmScore,
      srRoomScore: srTrend.srRoomScore ?? rawRadar.srRoomScore,
    );

    final lastTs = constSnap?.fetchedAtMs ?? flow.lastSectorFetchMs;
    final lastUpdStr = lastTs > 0
        ? DateFormat('HH:mm:ss')
            .format(DateTime.fromMillisecondsSinceEpoch(lastTs))
        : '--:--:--';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Top 3-Card Real Pulse Strip: Index Breadth | Active Spot | India VIX
        Row(
          children: [
            Expanded(
              child: QuantPanel(
                padding: const EdgeInsets.all(12),
                backgroundColor: QuantTheme.bgSecondary,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Breadth', style: QuantTheme.label(size: 10)),
                    const SizedBox(height: 3),
                    Text(
                      items.isNotEmpty ? '$advCount / ${items.length}' : 'NO DATA',
                      style: QuantTheme.mono(
                        size: 14,
                        color: items.isNotEmpty
                            ? QuantTheme.textPrimary
                            : QuantTheme.negative,
                        weight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      breadthPct != null ? '$breadthPct% Up ($decCount Dn)' : '--',
                      style: QuantTheme.label(size: 9.5, color: breadthColor),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: QuantPanel(
                padding: const EdgeInsets.all(12),
                backgroundColor: QuantTheme.bgSecondary,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(idx.label, style: QuantTheme.label(size: 10)),
                    const SizedBox(height: 3),
                    Text(
                      hasLive ? spot.toStringAsFixed(0) : 'NO DATA',
                      style: QuantTheme.mono(
                        size: 14,
                        color: hasLive
                            ? QuantTheme.textPrimary
                            : QuantTheme.negative,
                        weight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      hasLive
                          ? '${chgPct >= 0 ? "+" : ""}${chgPct.toStringAsFixed(2)}%'
                          : '--',
                      style: QuantTheme.mono(
                        size: 9.5,
                        color: chgPct >= 0
                            ? QuantTheme.positive
                            : QuantTheme.negative,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: QuantPanel(
                padding: const EdgeInsets.all(12),
                backgroundColor: QuantTheme.bgSecondary,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('India VIX', style: QuantTheme.label(size: 10)),
                    const SizedBox(height: 3),
                    Text(
                      vix != null ? vix.toStringAsFixed(2) : 'NO DATA',
                      style: QuantTheme.mono(
                        size: 14,
                        color: vix != null
                            ? QuantTheme.textPrimary
                            : QuantTheme.negative,
                        weight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      vixLabel,
                      style: QuantTheme.label(
                        size: 9.5,
                        color: (vix ?? 0) >= 16.0
                            ? QuantTheme.warning
                            : QuantTheme.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 2. Sub-Tabs
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              'Overview',
              'Money flow',
              'Order flow',
              'Radar',
              'Scanner',
            ].map((t) {
              final active = _subTab == t;
              return GestureDetector(
                onTap: () {
                  UiHaptics.tap();
                  setState(() => _subTab = t);
                  if (t == 'Scanner' &&
                      _scannerStocks.isEmpty &&
                      !_scannerLoading) {
                    _loadTvScanner();
                  }
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: active ? QuantTheme.accent : QuantTheme.border,
                    ),
                  ),
                  child: Text(
                    t,
                    style: QuantTheme.heading(
                      size: 10.5,
                      color: active
                          ? QuantTheme.accent
                          : QuantTheme.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),

        // 3. Live Status Strip
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            QuantBadge(
              text: ws.isConnected
                  ? 'WS LIVE • ${ws.totalTicksReceived} ticks'
                  : (health == DataHealthStatus.live
                      ? 'LIVE REST • $lastUpdStr'
                      : 'FEED ${health.label} — NO DATA'),
              color: (ws.isConnected || health == DataHealthStatus.live)
                  ? QuantTheme.positive
                  : QuantTheme.negative,
              icon: Icons.circle,
            ),
            GestureDetector(
              onTap: _toggleMotion,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: QuantTheme.bgPanel,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: QuantTheme.border),
                ),
                child: Text(
                  _motionPaused ? '▶ Resume' : '⏸ Pause',
                  style: QuantTheme.mono(
                      size: 10, color: QuantTheme.textSecondary),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        if (_subTab == 'Overview') ...[
          _buildConstituentRotationCard(idx, constSnap),
          const SizedBox(height: 12),
          _buildOptionCapitalInjectionCard(idx, injections),
        ] else if (_subTab == 'Money flow') ...[
          _buildConstituentRotationCard(idx, constSnap),
          const SizedBox(height: 12),
          _buildConstituentGridCard(idx, constSnap),
          const SizedBox(height: 12),
          _buildOptionCapitalInjectionCard(idx, injections),
        ] else if (_subTab == 'Order flow') ...[
          _buildFollowTheMoneyHubCard(flow),
          const SizedBox(height: 12),
          _buildOrderBookWallCard(idx, rows, spot),
        ] else if (_subTab == 'Radar') ...[
          _buildSignalRadarCard(idx, radarAxes, srTrend.breakoutState),
          const SizedBox(height: 12),
          _buildOptionCapitalInjectionCard(idx, injections),
        ] else ...[
          _buildTvScannerCard(),
        ],
      ],
    );
  }

  /// Real Per-Index Constituent Money Rotation (Nifty 50 / BankNifty 12 / FinNifty 20 / Sensex 30)
  Widget _buildConstituentRotationCard(
    UnderlyingIndex idx,
    IndexConstituentFlowSnapshot? snap,
  ) {
    final totalTarget =
        ConstituentFlowEngine.constituentsByIndex[idx]?.length ?? 0;
    final items = snap?.items ?? const <ConstituentFlowItem>[];
    final inflows = snap?.inflows ?? const <ConstituentFlowItem>[];
    final outflows = snap?.outflows ?? const <ConstituentFlowItem>[];
    final inCr = snap?.inflowTurnoverCr ?? 0.0;
    final outCr = snap?.outflowTurnoverCr ?? 0.0;
    final topIn = inflows.take(3).map((e) => e.symbol).join(', ');
    final topOut = outflows.take(3).map((e) => e.symbol).join(', ');

    return QuantPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Where money moved (${idx.label})',
                        style: QuantTheme.heading(size: 13)),
                    Text(
                      'Real ${items.length}/$totalTarget Index Constituents • Live Angel Quotes',
                      style: QuantTheme.label(size: 9.5),
                    ),
                  ],
                ),
              ),
              QuantBadge(
                text: '${inflows.length} IN / ${outflows.length} OUT',
                color: inflows.length >= outflows.length
                    ? QuantTheme.positive
                    : QuantTheme.negative,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  snap != null && snap.errorNote.isNotEmpty
                      ? snap.errorNote
                      : 'NO DATA — Connect Angel One API to stream real ${idx.label} constituent money flow.',
                  textAlign: TextAlign.center,
                  style: QuantTheme.mono(size: 10.5, color: QuantTheme.negative),
                ),
              ),
            )
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                QuantMetricCell(
                  label: 'INFLOW TURNOVER',
                  value: '₹${inCr.toStringAsFixed(0)} Cr',
                  valueColor: QuantTheme.positive,
                ),
                QuantMetricCell(
                  label: 'OUTFLOW TURNOVER',
                  value: '₹${outCr.toStringAsFixed(0)} Cr',
                  valueColor: QuantTheme.negative,
                ),
                QuantMetricCell(
                  label: 'NET STOCK FLOW',
                  value:
                      '${inCr >= outCr ? "+" : "-"}₹${(inCr - outCr).abs().toStringAsFixed(0)} Cr',
                  valueColor:
                      inCr >= outCr ? QuantTheme.positive : QuantTheme.negative,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 165,
              width: double.infinity,
              child: AnimatedBuilder(
                animation: _animCtrl,
                builder: (ctx, _) => CustomPaint(
                  painter: _ConstituentRotationPainter(
                    outflows: outflows.take(5).toList(),
                    inflows: inflows.take(5).toList(),
                    animValue: _animCtrl.value,
                  ),
                ),
              ),
            ),
            const Divider(color: QuantTheme.border, height: 14),
            Text(
              'Leading Inflow: ${topIn.isNotEmpty ? topIn : "None"} | Leading Outflow: ${topOut.isNotEmpty ? topOut : "None"}',
              style: QuantTheme.label(size: 10.5, color: QuantTheme.textPrimary),
            ),
          ],
        ],
      ),
    );
  }

  /// Interactive Full Constituent List (All 50 Nifty / 12 BankNifty / 20 FinNifty / 30 Sensex)
  Widget _buildConstituentGridCard(
    UnderlyingIndex idx,
    IndexConstituentFlowSnapshot? snap,
  ) {
    final items = snap?.items ?? const <ConstituentFlowItem>[];
    if (items.isEmpty) return const SizedBox.shrink();

    final visible = _showAllConstituents ? items : items.take(16).toList();

    return QuantPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${idx.label} Constituents (${items.length})',
                  style: QuantTheme.heading(size: 12)),
              if (items.length > 16)
                GestureDetector(
                  onTap: () {
                    UiHaptics.tap();
                    setState(() => _showAllConstituents = !_showAllConstituents);
                  },
                  child: QuantBadge(
                    text: _showAllConstituents
                        ? 'Show Top 16'
                        : 'Show All ${items.length}',
                    color: QuantTheme.accent,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: visible.map((st) {
              final selected = _selectedStock?.symbol == st.symbol;
              final col = st.isInflow ? QuantTheme.positive : QuantTheme.negative;
              return GestureDetector(
                onTap: () {
                  UiHaptics.tap();
                  setState(() => _selectedStock = st);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? col.withOpacity(0.18)
                        : QuantTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: selected ? col : QuantTheme.border,
                    ),
                  ),
                  child: Text(
                    '${st.symbol} ${st.changePct >= 0 ? "+" : ""}${st.changePct.toStringAsFixed(2)}%',
                    style: QuantTheme.mono(size: 9.5, color: col),
                  ),
                ),
              );
            }).toList(),
          ),
          if (_selectedStock != null) ...[
            const Divider(color: QuantTheme.border, height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: QuantTheme.bgSecondary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _selectedStock!.isInflow
                      ? QuantTheme.positive
                      : QuantTheme.negative,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_selectedStock!.symbol} • ${_selectedStock!.isInflow ? "INFLOW" : "OUTFLOW"}',
                        style: QuantTheme.heading(
                          size: 12,
                          color: _selectedStock!.isInflow
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                        ),
                      ),
                      Text(
                        '₹${_selectedStock!.ltp.toStringAsFixed(2)} (${_selectedStock!.changePct >= 0 ? "+" : ""}${_selectedStock!.changePct.toStringAsFixed(2)}%)',
                        style: QuantTheme.mono(
                          size: 11,
                          color: _selectedStock!.isInflow
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      QuantMetricCell(
                        label: 'TURNOVER',
                        value: '₹${_selectedStock!.turnoverCr.toStringAsFixed(1)} Cr',
                        valueColor: QuantTheme.accent,
                      ),
                      QuantMetricCell(
                        label: 'HIGH / LOW',
                        value:
                            '${_selectedStock!.high.toStringAsFixed(1)} / ${_selectedStock!.low.toStringAsFixed(1)}',
                      ),
                      QuantMetricCell(
                        label: 'RANGE POS',
                        value:
                            '${(_selectedStock!.rangePressure * 100).toStringAsFixed(0)}%',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTvScannerCard() {
    return QuantPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NSE Live Momentum Scanner',
                      style: QuantTheme.heading(size: 13)),
                  Text('Live Liquid Movers', style: QuantTheme.label(size: 9.5)),
                ],
              ),
              GestureDetector(
                onTap: _scannerLoading ? null : () => _loadTvScanner(),
                child: QuantBadge(
                  text: _scannerLoading ? 'Scanning...' : '↻ Refresh',
                  color: QuantTheme.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: ['GAINERS', 'LOSERS', 'VOLUME'].map((m) {
              final active = _scannerMode == m;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    UiHaptics.tap();
                    _loadTvScanner(mode: m);
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color:
                          active ? QuantTheme.accent : QuantTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      m,
                      style: QuantTheme.mono(
                        size: 9.5,
                        color: active
                            ? QuantTheme.bgMain
                            : QuantTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const Divider(color: QuantTheme.border, height: 14),
          if (_scannerLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_scannerStocks.isEmpty)
            Text(
              TvScreenerEngine.instance.lastError.isNotEmpty
                  ? TvScreenerEngine.instance.lastError
                  : 'Tap Refresh to scan top NSE liquid movers.',
              style: QuantTheme.mono(size: 11, color: QuantTheme.warning),
            )
          else
            ..._scannerStocks.map((st) {
              final isUp = st.changePct >= 0;
              final col = isUp ? QuantTheme.positive : QuantTheme.negative;
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: QuantTheme.border, width: 0.5)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(st.symbol, style: QuantTheme.heading(size: 11)),
                          Text(
                            '${st.sector} • RelVol ${st.relVolume.toStringAsFixed(1)}x • RSI ${st.rsi14?.toStringAsFixed(0) ?? "-"}',
                            overflow: TextOverflow.ellipsis,
                            style: QuantTheme.mono(
                                size: 8.5, color: QuantTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('₹${st.close.toStringAsFixed(1)}',
                            style: QuantTheme.mono(size: 11)),
                        Text(
                          '${isUp ? "+" : ""}${st.changePct.toStringAsFixed(2)}% • ${st.ratingLabel}',
                          style: QuantTheme.mono(size: 9, color: col),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildOptionCapitalInjectionCard(
    UnderlyingIndex idx,
    List<StrikeMoneyInjection> injections,
  ) {
    double ceTurnCr = 0.0, peTurnCr = 0.0;
    for (final x in injections) {
      if (x.optionType == 'CE') {
        ceTurnCr += x.turnoverCr;
      } else {
        peTurnCr += x.turnoverCr;
      }
    }

    return QuantPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Option Money Injected (${idx.label})',
                  style: QuantTheme.heading(size: 12)),
              QuantBadge(
                text: injections.isEmpty
                    ? 'NO DATA'
                    : (ceTurnCr >= peTurnCr ? 'CE HEAVY' : 'PE HEAVY'),
                color: injections.isEmpty
                    ? QuantTheme.negative
                    : (ceTurnCr >= peTurnCr
                        ? QuantTheme.positive
                        : QuantTheme.negative),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (injections.isEmpty)
            Text(
              'NO DATA — Live option chain required for real strike capital injection.',
              style: QuantTheme.mono(size: 10.5, color: QuantTheme.negative),
            )
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                QuantMetricCell(
                  label: 'CE TURNOVER',
                  value: '₹${ceTurnCr.toStringAsFixed(1)} Cr',
                  valueColor: QuantTheme.positive,
                ),
                QuantMetricCell(
                  label: 'PE TURNOVER',
                  value: '₹${peTurnCr.toStringAsFixed(1)} Cr',
                  valueColor: QuantTheme.negative,
                ),
                QuantMetricCell(
                  label: 'NET BIAS',
                  value:
                      '${(ceTurnCr - peTurnCr) >= 0 ? "CE +" : "PE +"}₹${(ceTurnCr - peTurnCr).abs().toStringAsFixed(1)} Cr',
                  valueColor: QuantTheme.accent,
                ),
              ],
            ),
            const Divider(color: QuantTheme.border, height: 14),
            ...injections.take(6).map((s) {
              final isCe = s.optionType == 'CE';
              final col = isCe ? QuantTheme.positive : QuantTheme.negative;
              final injText = s.netInjectedCr != null
                  ? '${s.netInjectedCr! >= 0 ? "+" : ""}₹${s.netInjectedCr!.toStringAsFixed(2)}Cr'
                  : '15m collecting';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        QuantBadge(
                            text: '${s.strike} ${s.optionType}', color: col),
                        const SizedBox(width: 8),
                        Text('₹${s.ltp.toStringAsFixed(1)}',
                            style: QuantTheme.mono(size: 11)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Turn ₹${s.turnoverCr.toStringAsFixed(1)}Cr',
                            style: QuantTheme.mono(
                                size: 11, color: QuantTheme.textPrimary)),
                        Text('15m Inj: $injText',
                            style: QuantTheme.mono(
                                size: 9.5, color: QuantTheme.textSecondary)),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildFollowTheMoneyHubCard(FlowDataEngine flow) {
    return QuantPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MARKET → SECTORS → ORDER FLOW',
              style: QuantTheme.mono(size: 9.5, color: QuantTheme.accent)),
          const SizedBox(height: 2),
          Text('Follow the money.', style: QuantTheme.heading(size: 15)),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('▲ ${flow.buyPressureCount} BUY PRESSURE',
                  style: QuantTheme.mono(size: 10, color: QuantTheme.positive)),
              const SizedBox(width: 12),
              Text('▼ ${flow.sellPressureCount} SELL PRESSURE',
                  style: QuantTheme.mono(size: 10, color: QuantTheme.negative)),
            ],
          ),
          const SizedBox(height: 10),
          if (!flow.hasSectorData)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  'NO DATA — Connect Angel One API to stream live order flow.',
                  textAlign: TextAlign.center,
                  style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
                ),
              ),
            )
          else
            SizedBox(
              height: 215,
              width: double.infinity,
              child: AnimatedBuilder(
                animation: _animCtrl,
                builder: (ctx, _) => CustomPaint(
                  painter: OrderFlowHubPainter(
                    sectors: flow.sectors,
                    animValue: _animCtrl.value,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOrderBookWallCard(
    UnderlyingIndex idx,
    List<StrikeRowSnapshot> rows,
    double spot,
  ) {
    int maxBidStrike = 0, maxBidScore = -1;
    int maxAskStrike = 0, maxAskScore = -1;
    for (final r in rows) {
      if (r.strike <= spot) {
        final score = r.peOi + r.peBidQty;
        if (score > maxBidScore) {
          maxBidScore = score;
          maxBidStrike = r.strike;
        }
      }
      if (r.strike >= spot) {
        final score = r.ceOi + r.ceAskQty;
        if (score > maxAskScore) {
          maxAskScore = score;
          maxAskStrike = r.strike;
        }
      }
    }

    return QuantPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Who is waiting to buy and sell',
                  style: QuantTheme.heading(size: 13)),
              const QuantBadge(
                  text: 'ORDER BOOK WALL', color: QuantTheme.accent),
            ],
          ),
          const SizedBox(height: 6),
          if (rows.isEmpty || spot <= 0)
            Text('NO DATA — Live option chain depth required.',
                style: QuantTheme.mono(size: 11, color: QuantTheme.negative))
          else ...[
            Text(
              'Biggest Put/Bid support wall at $maxBidStrike • Biggest Call/Ask resistance wall at $maxAskStrike (${idx.label}).',
              style: QuantTheme.label(size: 11, color: QuantTheme.textSecondary),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 155,
              width: double.infinity,
              child: CustomPaint(
                painter: OrderBookWallPainter(rows: rows, spot: spot),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSignalRadarCard(
      UnderlyingIndex idx, RadarSignalAxes axes, String trendState) {
    final bias = axes.overallBias;
    final col = bias == 'bullish'
        ? QuantTheme.positive
        : (bias == 'bearish' ? QuantTheme.negative : QuantTheme.warning);

    return QuantPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('8 signals at a glance (${idx.label})',
                      style: QuantTheme.heading(size: 13)),
                  Text('S/R Trendline: $trendState • 50 is neutral',
                      style: QuantTheme.label(size: 10)),
                ],
              ),
              QuantBadge(text: bias.toUpperCase(), color: col),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 245,
            width: double.infinity,
            child: CustomPaint(
              painter: SignalRadarPainter(axes: axes),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConstituentRotationPainter extends CustomPainter {
  final List<ConstituentFlowItem> outflows;
  final List<ConstituentFlowItem> inflows;
  final double animValue;

  _ConstituentRotationPainter({
    required this.outflows,
    required this.inflows,
    required this.animValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final leftX = 88.0;
    final rightX = size.width - 88.0;
    final midX = size.width * 0.5;
    final midY = size.height * 0.5;

    final maxTurn = math.max(
      1.0,
      [...outflows, ...inflows].fold<double>(
          1.0, (m, e) => math.max(m, e.turnoverCr)),
    );

    void drawList(List<ConstituentFlowItem> list, bool isLeft) {
      final n = list.length;
      if (n == 0) return;
      for (int i = 0; i < n; i++) {
        final item = list[i];
        final y = (size.height / (n + 1)) * (i + 1);
        final col = isLeft ? QuantTheme.negative : QuantTheme.positive;
        final strokeW =
            (1.2 + 2.4 * (item.turnoverCr / maxTurn)).clamp(1.2, 3.6).toDouble();

        final path = Path();
        if (isLeft) {
          path.moveTo(leftX, y);
          path.cubicTo(leftX + 35, y, midX - 25, midY, midX, midY);
        } else {
          path.moveTo(midX, midY);
          path.cubicTo(midX + 25, midY, rightX - 35, y, rightX, y);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = col.withOpacity(0.45)
            ..strokeWidth = strokeW
            ..style = PaintingStyle.stroke,
        );

        // Animated flow dot along Bezier curve
        final t = (animValue + i * 0.19) % 1.0;
        final sx = isLeft ? leftX : midX;
        final sy = isLeft ? y : midY;
        final ex = isLeft ? midX : rightX;
        final ey = isLeft ? midY : y;
        final px = sx + (ex - sx) * t;
        final py = sy + (ey - sy) * t;
        canvas.drawCircle(Offset(px, py), 2.5, Paint()..color = col);

        final lbl =
            '${item.symbol} ${item.changePct >= 0 ? "+" : ""}${item.changePct.toStringAsFixed(1)}%';
        final tp = TextPainter(
          text: TextSpan(
            text: lbl,
            style: QuantTheme.mono(size: 8.5, color: col, weight: FontWeight.w700),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 84);
        tp.paint(
          canvas,
          Offset(isLeft ? 2 : rightX + 4, y - tp.height / 2),
        );
      }
    }

    drawList(outflows, true);
    drawList(inflows, false);

    // Center hub
    canvas.drawCircle(
      Offset(midX, midY),
      15,
      Paint()..color = QuantTheme.bgElevated,
    );
    canvas.drawCircle(
      Offset(midX, midY),
      15,
      Paint()
        ..color = QuantTheme.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    final hubTp = TextPainter(
      text: TextSpan(
        text: 'FLOW',
        style: QuantTheme.mono(
            size: 7.5, color: QuantTheme.accent, weight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    hubTp.paint(canvas, Offset(midX - hubTp.width / 2, midY - hubTp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ConstituentRotationPainter oldDelegate) =>
      true;
}
