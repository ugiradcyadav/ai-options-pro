import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/angel_ws_streamer.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/iv_grid_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/microstructure_engine.dart';
import '../../engine/options_payoff_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/pro_kline_chart.dart';
import 'oi_analysis_screen.dart';
import 'pulse_flow_screen.dart';

class OptionChainScreen extends StatefulWidget {
  final AppState appState;
  final String initialWorkspaceTab;

  const OptionChainScreen({
    super.key,
    required this.appState,
    this.initialWorkspaceTab = 'Pulse & Flow',
  });

  @override
  State<OptionChainScreen> createState() => _OptionChainScreenState();
}

class _OptionChainScreenState extends State<OptionChainScreen> {
  late String _workspaceTab;
  String _chartTf = '1m';
  bool _compareSpotVsOption = true;
  bool _payoffIsCall = true;
  int _selectedOffset = 0;
  int _touchedIdx = -1;
  List<OneMinEnrichedBar> _intradayBars = [];
  List<OneMinEnrichedBar> _spotBars = [];

  @override
  void initState() {
    super.initState();
    _workspaceTab = widget.initialWorkspaceTab;
    _loadMinuteBars();
  }

  @override
  void didUpdateWidget(covariant OptionChainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadMinuteBars();
  }

  Future<void> _loadMinuteBars() async {
    final idxLabel = widget.appState.selectedIndex.label;
    final optBars = await ForeverDatabase.instance.getRecentBars(
      indexName: idxLabel,
      optionType: 'CE',
      limit: 120,
    );
    final spotBars = await ForeverDatabase.instance.getRecentBars(
      indexName: idxLabel,
      optionType: 'SPOT',
      limit: 120,
    );
    if (!mounted) return;
    setState(() {
      _intradayBars = optBars.reversed.toList();
      _spotBars = spotBars.reversed.toList();
    });
  }

  List<OneMinEnrichedBar> _aggregateBars(
      List<OneMinEnrichedBar> raw, int bucketMins) {
    if (bucketMins <= 1 || raw.length < 2) return raw;
    final out = <OneMinEnrichedBar>[];
    final bucketMs = bucketMins * 60000;
    for (final b in raw) {
      final key = (b.timestampMs ~/ bucketMs) * bucketMs;
      if (out.isEmpty || out.last.timestampMs != key) {
        out.add(OneMinEnrichedBar(
          timestampMs: key,
          contractId: b.contractId,
          indexName: b.indexName,
          expiry: b.expiry,
          strike: b.strike,
          optionType: b.optionType,
          strikeOffset: b.strikeOffset,
          underlyingSpot: b.underlyingSpot,
          open: b.open,
          high: b.high,
          low: b.low,
          close: b.close,
          intervalVolume: b.intervalVolume,
          absoluteOi: b.absoluteOi,
          delta: b.delta,
          gamma: b.gamma,
          theta: b.theta,
          vega: b.vega,
        ));
      } else {
        final prev = out.last;
        out[out.length - 1] = OneMinEnrichedBar(
          timestampMs: key,
          contractId: prev.contractId,
          indexName: prev.indexName,
          expiry: prev.expiry,
          strike: prev.strike,
          optionType: prev.optionType,
          strikeOffset: prev.strikeOffset,
          underlyingSpot: b.underlyingSpot,
          open: prev.open,
          high: b.high > prev.high ? b.high : prev.high,
          low: b.low < prev.low ? b.low : prev.low,
          close: b.close,
          intervalVolume: prev.intervalVolume + b.intervalVolume,
          absoluteOi: b.absoluteOi,
          delta: b.delta,
          gamma: b.gamma,
          theta: b.theta,
          vega: b.vega,
        );
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final expiries = engine.availableExpiries[idx] ?? const <String>[];
    final currentExp = (engine.selectedExpiry[idx]?.isNotEmpty == true &&
            expiries.contains(engine.selectedExpiry[idx]))
        ? engine.selectedExpiry[idx]!
        : (expiries.isNotEmpty ? expiries.first : '');
    final rows =
        engine.optionChainRows[idx] ?? const <StrikeRowSnapshot>[];
    final spot = engine.spotPrices[idx] ?? 0.0;
    final chgPct = engine.spotChangePct[idx] ?? 0.0;
    final health = engine.dataHealth;
    final hasLiveData =
        health == DataHealthStatus.live && spot > 0 && rows.isNotEmpty;
    final isPos = chgPct >= 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                'Pulse & Flow',
                'Charts',
                'Option Chain',
                'OI Analysis',
                'IV & Greeks',
                'Liquidity',
              ].map((tab) {
                final active = _workspaceTab == tab;
                return GestureDetector(
                  onTap: () => setState(() {
                    _workspaceTab = tab;
                    _touchedIdx = -1;
                  }),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? QuantTheme.accent : QuantTheme.border,
                      ),
                    ),
                    child: Text(
                      tab,
                      style: QuantTheme.heading(
                        size: 11,
                        color:
                            active ? QuantTheme.bgMain : QuantTheme.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 10),
          QuantPanel(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            backgroundColor: QuantTheme.bgSecondary,
            child: Column(
              children: [
                Row(
                  children: UnderlyingIndex.values.map((u) {
                    final active = u == idx;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _touchedIdx = -1);
                          widget.appState.setSelectedUnderlying(u);
                          _loadMinuteBars();
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: active
                                ? QuantTheme.bgElevated
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color:
                                  active ? QuantTheme.accent : QuantTheme.border,
                            ),
                          ),
                          child: Text(
                            u.label.replaceAll(' 50', ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: QuantTheme.heading(
                              size: 9.5,
                              color: active
                                  ? QuantTheme.accent
                                  : QuantTheme.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text(
                          hasLiveData ? spot.toStringAsFixed(2) : 'NO DATA',
                          style: QuantTheme.mono(
                            size: 16,
                            color: hasLiveData
                                ? QuantTheme.textPrimary
                                : QuantTheme.negative,
                            weight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (hasLiveData)
                          Text(
                            '${isPos ? "+" : ""}${chgPct.toStringAsFixed(2)}% ${isPos ? "▲" : "▼"}',
                            style: QuantTheme.mono(
                              size: 11,
                              color: isPos
                                  ? QuantTheme.positive
                                  : QuantTheme.negative,
                            ),
                          ),
                      ],
                    ),
                    if (expiries.isEmpty)
                      const QuantBadge(
                        text: 'EXPIRY: NO DATA',
                        color: QuantTheme.negative,
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 2),
                        decoration: BoxDecoration(
                          color: QuantTheme.bgPanel,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: QuantTheme.border),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: currentExp,
                            isDense: true,
                            dropdownColor: QuantTheme.bgPanel,
                            style: QuantTheme.mono(
                                size: 11, color: QuantTheme.accent),
                            items: expiries
                                .map((e) => DropdownMenuItem<String>(
                                      value: e,
                                      child: Text('Exp: $e'),
                                    ))
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
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (_workspaceTab == 'Pulse & Flow')
            PulseFlowScreen(appState: widget.appState)
          else if (_workspaceTab == 'Charts')
            _buildChartsWorkspace(idx, rows, spot)
          else if (_workspaceTab == 'OI Analysis')
            OiAnalysisScreen(appState: widget.appState, embeddedMode: true)
          else if (_workspaceTab == 'IV & Greeks')
            _buildIvAndGreeksWorkspace(idx, rows, spot)
          else if (_workspaceTab == 'Liquidity')
            _buildLiquidityWorkspace(idx, rows)
          else
            _buildOptionChainWorkspace(idx, rows, hasLiveData),
        ],
      ),
    );
  }

  Widget _buildChartsWorkspace(
      UnderlyingIndex idx, List<StrikeRowSnapshot> rows, double spot) {
    final tfMins = _chartTf == '15m' ? 15 : (_chartTf == '5m' ? 5 : 1);
    final barsToPlot = _aggregateBars(_intradayBars, tfMins);

    double? atmCeLtp;
    for (final r in rows) {
      if (r.offset == 0 && r.ceLtp > 0) {
        atmCeLtp = r.ceLtp;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: ['1m', '5m', '15m'].map((tf) {
                final active = _chartTf == tf;
                return GestureDetector(
                  onTap: () => setState(() => _chartTf = tf),
                  child: Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tf,
                      style: QuantTheme.mono(
                        size: 10,
                        color: active
                            ? QuantTheme.bgMain
                            : QuantTheme.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            GestureDetector(
              onTap: () => setState(
                  () => _compareSpotVsOption = !_compareSpotVsOption),
              child: QuantBadge(
                text: _compareSpotVsOption ? 'SPOT + OPT' : 'OPTION ONLY',
                color: QuantTheme.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ProKLineChart(
          bars: barsToPlot,
          liveLtp: atmCeLtp,
          showSpotOverlay: _compareSpotVsOption,
        ),
      ],
    );
  }

  Widget _buildOptionChainWorkspace(UnderlyingIndex idx,
      List<StrikeRowSnapshot> rows, bool hasLiveData) {
    if (!hasLiveData || rows.isEmpty) {
      return QuantPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              'NO DATA — Connect broker API to load live ATM ±12 Option Chain.',
              textAlign: TextAlign.center,
              style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
            ),
          ),
        ),
      );
    }

    int? sumCe5, sumCe15, sumCe60, sumPe5, sumPe15, sumPe60;
    for (final r in rows) {
      if (r.ceOiChange5m != null) sumCe5 = (sumCe5 ?? 0) + r.ceOiChange5m!;
      if (r.ceOiChange15m != null) sumCe15 = (sumCe15 ?? 0) + r.ceOiChange15m!;
      if (r.ceOiChange60m != null) sumCe60 = (sumCe60 ?? 0) + r.ceOiChange60m!;
      if (r.peOiChange5m != null) sumPe5 = (sumPe5 ?? 0) + r.peOiChange5m!;
      if (r.peOiChange15m != null) sumPe15 = (sumPe15 ?? 0) + r.peOiChange15m!;
      if (r.peOiChange60m != null) sumPe60 = (sumPe60 ?? 0) + r.peOiChange60m!;
    }
    String fmtOptDiff(int? v) =>
        v == null ? 'Collecting' : '${v >= 0 ? "+" : ""}$v lots';
    final displayRows = rows.where((r) => r.offset.abs() <= 5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuantPanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                decoration: const BoxDecoration(
                  color: QuantTheme.bgElevated,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text('CALLS (LTP | OI Lots | 15m Δ)',
                          textAlign: TextAlign.center,
                          style: QuantTheme.heading(
                              size: 9, color: QuantTheme.positive)),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text('STRIKE',
                          textAlign: TextAlign.center,
                          style: QuantTheme.heading(size: 9)),
                    ),
                    Expanded(
                      flex: 4,
                      child: Text('PUTS (LTP | OI Lots | 15m Δ)',
                          textAlign: TextAlign.center,
                          style: QuantTheme.heading(
                              size: 9, color: QuantTheme.negative)),
                    ),
                  ],
                ),
              ),
              ...displayRows.asMap().entries.map((entry) {
                final i = entry.key;
                final r = entry.value;
                final isAtm = r.offset == 0;
                final isSel = r.offset == _selectedOffset || i == _touchedIdx;
                final ceBidAsk = (r.ceBid != null && r.ceAsk != null)
                    ? '${r.ceBid!.toStringAsFixed(1)}/${r.ceAsk!.toStringAsFixed(1)}'
                    : '--/--';
                final peBidAsk = (r.peBid != null && r.peAsk != null)
                    ? '${r.peBid!.toStringAsFixed(1)}/${r.peAsk!.toStringAsFixed(1)}'
                    : '--/--';
                return GestureDetector(
                  onTap: () => setState(() {
                    _selectedOffset = r.offset;
                    _touchedIdx = i;
                  }),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
                    decoration: BoxDecoration(
                      color: isSel
                          ? QuantTheme.bgElevated.withOpacity(0.75)
                          : Colors.transparent,
                      border: const Border(
                          bottom:
                              BorderSide(color: QuantTheme.border, width: 0.6)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.ceLtp.toStringAsFixed(2),
                                      style: QuantTheme.mono(
                                          size: 11, weight: FontWeight.w800)),
                                  Text(ceBidAsk,
                                      style: QuantTheme.mono(
                                          size: 8,
                                          color: QuantTheme.textSecondary)),
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('${r.ceOi}L',
                                      style: QuantTheme.mono(
                                          size: 10,
                                          color: QuantTheme.textSecondary)),
                                  Text(
                                    r.ceOiChange15m != null
                                        ? '${r.ceOiChange15m! >= 0 ? "+" : ""}${r.ceOiChange15m}'
                                        : '--',
                                    style: QuantTheme.mono(
                                      size: 9,
                                      color: (r.ceOiChange15m ?? 0) >= 0
                                          ? QuantTheme.positive
                                          : QuantTheme.negative,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 3),
                              decoration: BoxDecoration(
                                color: isAtm
                                    ? QuantTheme.accent
                                    : QuantTheme.bgSecondary,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    '${r.strike}',
                                    style: QuantTheme.mono(
                                      size: 10,
                                      color: isAtm
                                          ? QuantTheme.bgMain
                                          : QuantTheme.textPrimary,
                                      weight: FontWeight.w800,
                                    ),
                                  ),
                                  Text(
                                    r.ceIv != null
                                        ? '${r.ceIv!.toStringAsFixed(1)}%'
                                        : 'N/A',
                                    style: QuantTheme.mono(
                                      size: 8,
                                      color: isAtm
                                          ? QuantTheme.bgMain
                                          : QuantTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.peLtp.toStringAsFixed(2),
                                      style: QuantTheme.mono(
                                          size: 11, weight: FontWeight.w800)),
                                  Text(peBidAsk,
                                      style: QuantTheme.mono(
                                          size: 8,
                                          color: QuantTheme.textSecondary)),
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('${r.peOi}L',
                                      style: QuantTheme.mono(
                                          size: 10,
                                          color: QuantTheme.textSecondary)),
                                  Text(
                                    r.peOiChange15m != null
                                        ? '${r.peOiChange15m! >= 0 ? "+" : ""}${r.peOiChange15m}'
                                        : '--',
                                    style: QuantTheme.mono(
                                      size: 9,
                                      color: (r.peOiChange15m ?? 0) >= 0
                                          ? QuantTheme.positive
                                          : QuantTheme.negative,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 10),
        QuantPanel(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('REAL CALL ΔOI (5m / 15m / 60m)',
                        style: QuantTheme.heading(
                            size: 9, color: QuantTheme.positive)),
                    const SizedBox(height: 4),
                    Text(
                      '5m: ${fmtOptDiff(sumCe5)}\n15m: ${fmtOptDiff(sumCe15)}\n60m: ${fmtOptDiff(sumCe60)}',
                      style:
                          QuantTheme.mono(size: 10, color: QuantTheme.positive),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('REAL PUT ΔOI (5m / 15m / 60m)',
                        style: QuantTheme.heading(
                            size: 9, color: QuantTheme.negative)),
                    const SizedBox(height: 4),
                    Text(
                      '5m: ${fmtOptDiff(sumPe5)}\n15m: ${fmtOptDiff(sumPe15)}\n60m: ${fmtOptDiff(sumPe60)}',
                      style:
                          QuantTheme.mono(size: 10, color: QuantTheme.negative),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIvAndGreeksWorkspace(
      UnderlyingIndex idx, List<StrikeRowSnapshot> rows, double spot) {
    if (rows.isEmpty || spot <= 0) {
      return QuantPanel(
        child: Text(
            'NO DATA — Connect broker API to compute Black-76 IV, Greeks & Payoff.',
            style: QuantTheme.mono(size: 11, color: QuantTheme.negative)),
      );
    }

    final surf = MathGreeksEngine.evaluateIvSurface(rows, spot);
    final rv = MathGreeksEngine.computeVolForecast(
      recentSpotBars: _spotBars,
      currentAtmIvPct: surf.atmIv,
      spot: spot,
      holdingMinutes: 15.0,
    );
    final ivGrid = IvGridEngine.buildNoExtrapolationGrid(rows);
    final cellByStrike = <int, IvGridCell>{
      for (final c in ivGrid.cells) c.strike: c
    };
    final comparisons = OptionsPayoffEngine.compareNakedVsDebitSpread(
      chainRows: rows,
      spot: spot,
      isCall: _payoffIsCall,
      strikeStep: idx.strikeStep,
    );
    final displayRows = rows.where((r) => r.offset.abs() <= 5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Options Lab: Naked vs. Debit Spread',
                      style: QuantTheme.heading(size: 12)),
                  Row(
                    children: [true, false].map((isCe) {
                      final active = _payoffIsCall == isCe;
                      return GestureDetector(
                        onTap: () => setState(() => _payoffIsCall = isCe),
                        child: Container(
                          margin: const EdgeInsets.only(left: 5),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: active
                                ? (isCe
                                    ? QuantTheme.positive
                                    : QuantTheme.negative)
                                : QuantTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            isCe ? 'CALL' : 'PUT',
                            style: QuantTheme.mono(
                              size: 9.5,
                              color: active
                                  ? QuantTheme.bgMain
                                  : QuantTheme.textSecondary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              const Divider(color: QuantTheme.border, height: 14),
              if (comparisons == null)
                Text('Awaiting live ATM + OTM quotes to compare payoff.',
                    style: QuantTheme.label(size: 11))
              else
                Row(
                  children: comparisons.map((c) {
                    return Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: QuantTheme.bgSecondary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: QuantTheme.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.strategyName,
                                style: QuantTheme.heading(
                                    size: 10, color: QuantTheme.accent)),
                            const SizedBox(height: 5),
                            Text(
                                'Net Debit: ₹${c.netDebitInr.toStringAsFixed(0)}',
                                style: QuantTheme.mono(size: 10)),
                            Text(
                                'Max Profit: ${c.maxProfitInr != null ? "₹${c.maxProfitInr!.toStringAsFixed(0)}" : "Unlimited"}',
                                style: QuantTheme.mono(
                                    size: 10, color: QuantTheme.positive)),
                            Text(
                                'Max Loss: ₹${c.maxLossInr.toStringAsFixed(0)}',
                                style: QuantTheme.mono(
                                    size: 10, color: QuantTheme.negative)),
                            Text(
                                'Breakeven: ${c.breakevenSpot?.toStringAsFixed(1) ?? "N/A"}',
                                style: QuantTheme.mono(
                                    size: 9.5,
                                    color: QuantTheme.textSecondary)),
                            Text(
                                'Friction: ₹${c.estimatedFrictionInr.toStringAsFixed(0)}',
                                style: QuantTheme.mono(
                                    size: 9, color: QuantTheme.warning)),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Black-76 Surface & No-Extrapolation IV Grid',
                      style: QuantTheme.heading(size: 11)),
                  QuantBadge(
                    text:
                        'OBS:${ivGrid.observedCount} INT:${ivGrid.interpolatedCount}',
                    color: QuantTheme.accent,
                  ),
                ],
              ),
              const Divider(color: QuantTheme.border, height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  QuantMetricCell(
                      label: 'ATM IV',
                      value: surf.atmIv != null
                          ? '${surf.atmIv!.toStringAsFixed(2)}%'
                          : 'N/A',
                      valueColor: QuantTheme.accent),
                  QuantMetricCell(
                      label: '25Δ RR',
                      value: surf.riskReversal25d != null
                          ? '${surf.riskReversal25d!.toStringAsFixed(2)}%'
                          : 'N/A'),
                  QuantMetricCell(
                      label: 'SPOT RV',
                      value: rv.ewmaForecastRvPct != null
                          ? '${rv.ewmaForecastRvPct!.toStringAsFixed(1)}%'
                          : 'Collecting',
                      valueColor: QuantTheme.positive),
                  QuantMetricCell(
                      label: 'VRP',
                      value: rv.varianceRiskPremiumPct != null
                          ? '${rv.varianceRiskPremiumPct!.toStringAsFixed(1)}%'
                          : 'N/A',
                      valueColor: QuantTheme.warning),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${surf.surfaceNote} | No extrapolation outside [${ivGrid.minObservedStrike ?? "-"}-${ivGrid.maxObservedStrike ?? "-"}]',
                style: QuantTheme.label(size: 9.5),
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
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: const BoxDecoration(
                  color: QuantTheme.bgElevated,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('STRIKE', style: QuantTheme.heading(size: 9.5)),
                    Text('CE IV [SRC]', style: QuantTheme.heading(size: 9.5)),
                    Text('PE IV [SRC]', style: QuantTheme.heading(size: 9.5)),
                    Text('CE/PE Δ', style: QuantTheme.heading(size: 9.5)),
                    Text('CE/PE Θ', style: QuantTheme.heading(size: 9.5)),
                  ],
                ),
              ),
              ...displayRows.map((r) {
                final cell = cellByStrike[r.strike];
                final ceTag = cell?.ceSource.shortTag ?? 'N/A';
                final peTag = cell?.peSource.shortTag ?? 'N/A';
                final ceStr = cell?.ceIv != null
                    ? '${cell!.ceIv!.toStringAsFixed(1)}% [$ceTag]'
                    : 'N/A';
                final peStr = cell?.peIv != null
                    ? '${cell!.peIv!.toStringAsFixed(1)}% [$peTag]'
                    : 'N/A';
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
                      Text('${r.strike}',
                          style: QuantTheme.mono(
                              size: 10, color: QuantTheme.accent)),
                      Text(ceStr,
                          style: QuantTheme.mono(
                            size: 9.5,
                            color: cell?.ceSource == IvCellSource.interpolated
                                ? QuantTheme.warning
                                : QuantTheme.textPrimary,
                          )),
                      Text(peStr,
                          style: QuantTheme.mono(
                            size: 9.5,
                            color: cell?.peSource == IvCellSource.interpolated
                                ? QuantTheme.warning
                                : QuantTheme.textPrimary,
                          )),
                      Text(
                        '${r.ceDelta.toStringAsFixed(2)}/${r.peDelta.toStringAsFixed(2)}',
                        style: QuantTheme.mono(
                            size: 9.5, color: QuantTheme.positive),
                      ),
                      Text(
                        '${r.ceTheta.toStringAsFixed(1)}/${r.peTheta.toStringAsFixed(1)}',
                        style: QuantTheme.mono(
                            size: 9.5, color: QuantTheme.warning),
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
  }

  Widget _buildLiquidityWorkspace(
      UnderlyingIndex idx, List<StrikeRowSnapshot> rows) {
    if (rows.isEmpty) {
      return QuantPanel(
        child: Text('NO DATA — Awaiting live order-book depth from broker.',
            style: QuantTheme.mono(size: 11, color: QuantTheme.negative)),
      );
    }

    final ws = AngelWsStreamer.instance;
    final micro = MicrostructureEngine.instance;
    final displayRows = rows.where((r) => r.offset.abs() <= 3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuantPanel(
          backgroundColor: QuantTheme.bgSecondary,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('VisualHFT LOB Microstructure (${idx.label})',
                      style: QuantTheme.heading(size: 11.5)),
                  Text('5-Lvl Weighted OBI • Micro-Price • Flow Toxicity',
                      style: QuantTheme.label(size: 9.5)),
                ],
              ),
              QuantBadge(
                text: ws.isConnected
                    ? 'WS LIVE • ${ws.totalTicksReceived}t'
                    : 'REST SNAPSHOT',
                color: ws.isConnected ? QuantTheme.positive : QuantTheme.warning,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ...displayRows.map((r) {
          final ceMicro = micro.getSnapshot(r.ceSecurityId);
          final peMicro = micro.getSnapshot(r.peSecurityId);
          return QuantPanel(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Strike ${r.strike} ${r.offset == 0 ? "(ATM)" : ""}',
                      style: QuantTheme.heading(
                          size: 11, color: QuantTheme.accent),
                    ),
                    Text(
                      'CE ₹${r.ceLtp.toStringAsFixed(1)} | PE ₹${r.peLtp.toStringAsFixed(1)}',
                      style: QuantTheme.mono(size: 10),
                    ),
                  ],
                ),
                const Divider(color: QuantTheme.border, height: 10),
                _microSideRow('CE', r.ceImbalance, ceMicro, QuantTheme.positive),
                const SizedBox(height: 5),
                _microSideRow('PE', r.peImbalance, peMicro, QuantTheme.negative),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _microSideRow(
    String side,
    double? fallbackImb,
    MicrostructureSnapshot? snap,
    Color sideCol,
  ) {
    final obiVal = snap != null ? snap.weightedObi : (fallbackImb ?? 0.0);
    final hasAny = snap != null || fallbackImb != null;
    final obiStr = hasAny
        ? '${obiVal >= 0 ? "+" : ""}${(obiVal * 100).toStringAsFixed(0)}%'
        : 'N/A';
    final toxStr = snap != null ? '${snap.toxicityScore.toStringAsFixed(0)}%' : '--';
    final mpStr = snap?.microPrice != null
        ? 'μ₹${snap!.microPrice!.toStringAsFixed(2)}'
        : 'μ--';
    final sprdStr = snap?.spreadBps != null
        ? '${snap!.spreadBps!.toStringAsFixed(0)}bps'
        : '--';
    final lbl = snap?.pressureLabel ?? (hasAny ? 'DEPTH' : 'AWAITING WS');

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            QuantBadge(text: side, color: sideCol),
            const SizedBox(width: 6),
            Text('OBI $obiStr • Tox $toxStr',
                style: QuantTheme.mono(size: 9.5)),
          ],
        ),
        Row(
          children: [
            Text('$mpStr ($sprdStr) ',
                style: QuantTheme.mono(
                    size: 9, color: QuantTheme.textSecondary)),
            Text(
              lbl,
              style: QuantTheme.mono(
                size: 8.5,
                color: lbl.contains('BUY')
                    ? QuantTheme.positive
                    : (lbl.contains('SELL')
                        ? QuantTheme.negative
                        : QuantTheme.accent),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
