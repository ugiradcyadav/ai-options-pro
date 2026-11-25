import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/angel_ws_streamer.dart';
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
  List<TvScannerStock> _scannerStocks = [];
  bool _motionPaused = false;
  SectorFlowSnapshot? _selectedSector;
  List<OneMinEnrichedBar> _recentBars = [];
  late AnimationController _animCtrl;
  Timer? _sectorTimer;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _refreshAllFlowData();
    _sectorTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _refreshAllFlowData();
    });
  }

  Future<void> _refreshAllFlowData() async {
    await FlowDataEngine.instance.refreshSectoralFlow();
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: widget.appState.selectedIndex.label,
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
    _sectorTimer?.cancel();
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final flow = FlowDataEngine.instance;
    final ws = AngelWsStreamer.instance;
    final health = engine.dataHealth;
    final spot = engine.spotPrices[idx] ?? 0.0;
    final chgPct = engine.spotChangePct[idx] ?? 0.0;
    final rows =
        engine.optionChainRows[idx] ?? const <StrikeRowSnapshot>[];
    final hasLive = health == DataHealthStatus.live && spot > 0;

    final mood = flow.marketMoodScore;
    final moodLabel = mood == null
        ? 'NO DATA'
        : (mood >= 60 ? 'Risk-on' : (mood <= 40 ? 'Risk-off' : 'Neutral'));
    final moodColor = mood == null
        ? QuantTheme.negative
        : (mood >= 60
            ? QuantTheme.positive
            : (mood <= 40 ? QuantTheme.negative : QuantTheme.warning));

    final vix = flow.indiaVix;
    final vixLabel = vix == null
        ? 'NO DATA'
        : (vix >= 16.0 ? 'Elevated' : (vix <= 12.5 ? 'Calm' : 'Normal'));

    final inflows = flow.sectors.where((s) => s.isInflow).toList();
    final outflows = flow.sectors.where((s) => !s.isInflow).toList()
      ..sort((a, b) => a.changePct.compareTo(b.changePct));

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

    final lastUpdStr = flow.lastSectorFetchMs > 0
        ? DateFormat('HH:mm:ss')
            .format(DateTime.fromMillisecondsSinceEpoch(flow.lastSectorFetchMs))
        : '--:--:--';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: QuantPanel(
                padding: const EdgeInsets.all(10),
                backgroundColor: QuantTheme.bgSecondary,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mood', style: QuantTheme.label(size: 10)),
                    const SizedBox(height: 3),
                    Text(
                      mood != null ? '$mood/100' : 'NO DATA',
                      style: QuantTheme.mono(
                        size: 15,
                        color: mood != null
                            ? QuantTheme.textPrimary
                            : QuantTheme.negative,
                        weight: FontWeight.w800,
                      ),
                    ),
                    Text(moodLabel,
                        style: QuantTheme.label(size: 10, color: moodColor)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: QuantPanel(
                padding: const EdgeInsets.all(10),
                backgroundColor: QuantTheme.bgSecondary,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(idx.label, style: QuantTheme.label(size: 10)),
                    const SizedBox(height: 3),
                    Text(
                      hasLive ? spot.toStringAsFixed(0) : 'NO DATA',
                      style: QuantTheme.mono(
                        size: 15,
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
                        size: 10,
                        color: chgPct >= 0
                            ? QuantTheme.positive
                            : QuantTheme.negative,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: QuantPanel(
                padding: const EdgeInsets.all(10),
                backgroundColor: QuantTheme.bgSecondary,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('India VIX', style: QuantTheme.label(size: 10)),
                    const SizedBox(height: 3),
                    Text(
                      vix != null ? vix.toStringAsFixed(2) : 'NO DATA',
                      style: QuantTheme.mono(
                        size: 15,
                        color: vix != null
                            ? QuantTheme.textPrimary
                            : QuantTheme.negative,
                        weight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      vixLabel,
                      style: QuantTheme.label(
                        size: 10,
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
        const SizedBox(height: 10),
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
                  setState(() => _subTab = t);
                  if (t == 'Scanner' && _scannerStocks.isEmpty && !_scannerLoading) {
                    _loadTvScanner();
                  }
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 5),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
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
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: QuantTheme.bgPanel,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: QuantTheme.border),
                ),
                child: Text(
                  _motionPaused ? '▶ Resume motion' : '⏸ Pause motion',
                  style: QuantTheme.mono(
                      size: 10, color: QuantTheme.textSecondary),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_subTab == 'Overview') ...[
          _buildMoneyRotationCard(inflows, outflows, flow.hasSectorData),
          const SizedBox(height: 10),
          _buildOptionCapitalInjectionCard(idx, injections),
        ] else if (_subTab == 'Money flow') ...[
          _buildMoneyRotationCard(inflows, outflows, flow.hasSectorData),
          const SizedBox(height: 10),
          _buildSectorBreakdownList(flow.sectors),
          const SizedBox(height: 10),
          _buildOptionCapitalInjectionCard(idx, injections),
        ] else if (_subTab == 'Order flow') ...[
          _buildFollowTheMoneyHubCard(flow),
          const SizedBox(height: 10),
          _buildOrderBookWallCard(idx, rows, spot),
        ] else if (_subTab == 'Radar') ...[
          _buildSignalRadarCard(idx, radarAxes, srTrend.breakoutState),
          const SizedBox(height: 10),
          _buildOptionCapitalInjectionCard(idx, injections),
        ] else ...[
          _buildTvScannerCard(),
        ],
      ],
    );
  }

  Widget _buildTvScannerCard() {
    return QuantPanel(
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
                  Text('Powered by TradingView India Screener',
                      style: QuantTheme.label(size: 9.5)),
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
                  onTap: () => _loadTvScanner(mode: m),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 6),
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
                padding: const EdgeInsets.symmetric(vertical: 6),
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
                          Text(st.symbol,
                              style: QuantTheme.heading(size: 11)),
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

  Widget _buildMoneyRotationCard(
    List<SectorFlowSnapshot> inflows,
    List<SectorFlowSnapshot> outflows,
    bool hasSectorData,
  ) {
    final topIn = inflows.take(2).map((s) => s.name).join(' & ');
    final topOut = outflows.take(2).map((s) => s.name).join(' & ');

    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Where money moved today',
                      style: QuantTheme.heading(size: 13)),
                  Text('Real NSE Sectoral Rotation (Angel SmartAPI)',
                      style: QuantTheme.label(size: 10)),
                ],
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
          if (!hasSectorData)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'NO DATA — Connect Angel One API to stream real sectoral money rotation.',
                  textAlign: TextAlign.center,
                  style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 155,
              width: double.infinity,
              child: AnimatedBuilder(
                animation: _animCtrl,
                builder: (ctx, _) => CustomPaint(
                  painter: MoneyRotationPainter(
                    outflows: outflows,
                    inflows: inflows,
                    animValue: _animCtrl.value,
                  ),
                ),
              ),
            ),
            const Divider(color: QuantTheme.border, height: 14),
            Text(
              'Money rotating ${topIn.isNotEmpty ? "into $topIn" : "selectively"}${topOut.isNotEmpty ? ", out of $topOut" : ""}. Tap any sector below to inspect.',
              style: QuantTheme.label(size: 11, color: QuantTheme.textPrimary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectorBreakdownList(List<SectorFlowSnapshot> sectors) {
    if (sectors.isEmpty) return const SizedBox.shrink();
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sector Inflow / Outflow Details',
              style: QuantTheme.heading(size: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: sectors.map((s) {
              final selected = _selectedSector?.name == s.name;
              final col = s.isInflow ? QuantTheme.positive : QuantTheme.negative;
              return GestureDetector(
                onTap: () => setState(() => _selectedSector = s),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
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
                    '${s.name} ${s.changePct >= 0 ? "+" : ""}${s.changePct.toStringAsFixed(2)}%',
                    style: QuantTheme.mono(size: 10, color: col),
                  ),
                ),
              );
            }).toList(),
          ),
          if (_selectedSector != null) ...[
            const Divider(color: QuantTheme.border, height: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: QuantTheme.bgSecondary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _selectedSector!.isInflow
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
                        '${_selectedSector!.name} • ${_selectedSector!.isInflow ? "money entering" : "money leaving"}',
                        style: QuantTheme.heading(
                          size: 12,
                          color: _selectedSector!.isInflow
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                        ),
                      ),
                      Text(
                        '${_selectedSector!.changePct >= 0 ? "+" : ""}${_selectedSector!.changePct.toStringAsFixed(2)}%',
                        style: QuantTheme.mono(
                          size: 12,
                          color: _selectedSector!.isInflow
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      QuantMetricCell(
                        label: 'LTP',
                        value: _selectedSector!.ltp.toStringAsFixed(1),
                      ),
                      QuantMetricCell(
                        label: 'DAY HIGH / LOW',
                        value:
                            '${_selectedSector!.high.toStringAsFixed(0)} / ${_selectedSector!.low.toStringAsFixed(0)}',
                      ),
                      QuantMetricCell(
                        label: 'BUY PRESSURE',
                        value:
                            '${(_selectedSector!.rangePressure * 100).toStringAsFixed(0)}%',
                        valueColor: QuantTheme.accent,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Where Option Money Is Injected (${idx.label})',
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
              'NO DATA — Live option chain required to calculate real strike capital injection.',
              style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
            )
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                QuantMetricCell(
                  label: 'CE TURNOVER (ATM±4)',
                  value: '₹${ceTurnCr.toStringAsFixed(1)} Cr',
                  valueColor: QuantTheme.positive,
                ),
                QuantMetricCell(
                  label: 'PE TURNOVER (ATM±4)',
                  value: '₹${peTurnCr.toStringAsFixed(1)} Cr',
                  valueColor: QuantTheme.negative,
                ),
                QuantMetricCell(
                  label: 'NET FLOW BIAS',
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
                  style:
                      QuantTheme.mono(size: 10, color: QuantTheme.positive)),
              const SizedBox(width: 12),
              Text('▼ ${flow.sellPressureCount} SELL PRESSURE',
                  style:
                      QuantTheme.mono(size: 10, color: QuantTheme.negative)),
            ],
          ),
          const SizedBox(height: 10),
          if (!flow.hasSectorData)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  'NO DATA — Connect Angel One API to visualize live sectoral order flow.',
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
