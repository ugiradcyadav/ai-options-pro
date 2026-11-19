import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/math_greeks.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import 'oi_analysis_screen.dart';

class OptionChainScreen extends StatefulWidget {
  final AppState appState;
  final String initialWorkspaceTab;

  const OptionChainScreen({
    super.key,
    required this.appState,
    this.initialWorkspaceTab = 'Option Chain',
  });

  @override
  State<OptionChainScreen> createState() => _OptionChainScreenState();
}

class _OptionChainScreenState extends State<OptionChainScreen> {
  late String _workspaceTab;
  String _chartTf = '5m';
  String _indicatorTab = 'RSI';
  bool _compareSpotVsOption = true;
  int _selectedOffset = 0;
  String _chainGraphTab = 'OI';
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
      limit: 80,
    );
    final spotBars = await ForeverDatabase.instance.getRecentBars(
      indexName: idxLabel,
      optionType: 'SPOT',
      limit: 80,
    );
    if (!mounted) return;
    setState(() {
      _intradayBars = optBars.reversed.toList();
      _spotBars = spotBars.reversed.toList();
    });
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
    final rows = engine.optionChainRows[idx] ?? const <StrikeRowSnapshot>[];
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
                        color: active ? QuantTheme.bgMain : QuantTheme.textPrimary,
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
                            u.label,
                            style: QuantTheme.heading(
                              size: 10,
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

          if (_workspaceTab == 'Charts')
            _buildChartsWorkspace(idx, spot)
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

  Widget _buildChartsWorkspace(UnderlyingIndex idx, double spot) {
    if (_intradayBars.isEmpty) {
      return QuantPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              'NO DATA — Real 1-minute option bars will populate once broker feed is LIVE.',
              textAlign: TextAlign.center,
              style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
            ),
          ),
        ),
      );
    }

    double? rsi14;
    double macdVal = 0.0;
    double macdSignal = 0.0;
    double vwapVal = spot;

    if (_intradayBars.length >= 5) {
      double gainSum = 0.0, lossSum = 0.0, pvSum = 0.0, vSum = 0.0;
      double ema12 = _intradayBars.first.close;
      double ema26 = ema12;
      for (int i = 1; i < _intradayBars.length; i++) {
        final prev = _intradayBars[i - 1];
        final cur = _intradayBars[i];
        final diff = cur.close - prev.close;
        if (diff > 0) {
          gainSum += diff;
        } else {
          lossSum += diff.abs();
        }
        final typical = (cur.high + cur.low + cur.close) / 3.0;
        pvSum += typical * cur.intervalVolume;
        vSum += cur.intervalVolume;
        ema12 = (cur.close * (2.0 / 13.0)) + (ema12 * (1.0 - (2.0 / 13.0)));
        ema26 = (cur.close * (2.0 / 27.0)) + (ema26 * (1.0 - (2.0 / 27.0)));
      }
      if (lossSum > 1e-6) {
        final rs = gainSum / lossSum;
        rsi14 = 100.0 - (100.0 / (1.0 + rs));
      }
      macdVal = ema12 - ema26;
      macdSignal = macdVal * 0.82;
      if (vSum > 0) vwapVal = pvSum / vSum;
    }

    final barCount = _intradayBars.length;
    final selBar = _intradayBars[
        (_touchedIdx >= 0 && _touchedIdx < barCount)
            ? _touchedIdx
            : barCount - 1];

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
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tf,
                      style: QuantTheme.mono(
                        size: 10,
                        color: active ? QuantTheme.bgMain : QuantTheme.textPrimary,
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
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${DateFormat("HH:mm").format(DateTime.fromMillisecondsSinceEpoch(selBar.timestampMs))} • ${selBar.strike} ${selBar.optionType}',
                    style: QuantTheme.heading(size: 11),
                  ),
                  Text(
                    'O:${selBar.open.toStringAsFixed(1)} H:${selBar.high.toStringAsFixed(1)} L:${selBar.low.toStringAsFixed(1)} C:${selBar.close.toStringAsFixed(1)}',
                    style: QuantTheme.mono(size: 10, color: QuantTheme.positive),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  void handleTouch(Offset pos) {
                    if (barCount <= 0 || w <= 0) return;
                    final idx =
                        ((pos.dx / w).clamp(0.0, 0.999) * barCount).floor();
                    if (idx != _touchedIdx) {
                      setState(() => _touchedIdx = idx);
                    }
                  }

                  return GestureDetector(
                    onTapDown: (d) => handleTouch(d.localPosition),
                    onPanUpdate: (d) => handleTouch(d.localPosition),
                    child: SizedBox(
                      width: w,
                      height: 200,
                      child: CustomPaint(
                        painter: _QuantCandleChartPainter(
                          bars: _intradayBars,
                          touchedIdx: _touchedIdx,
                          showSpotOverlay: _compareSpotVsOption,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'RSI(14): ${rsi14?.toStringAsFixed(1) ?? "N/A"} | MACD: ${macdVal.toStringAsFixed(2)}/${macdSignal.toStringAsFixed(2)}',
                    style: QuantTheme.mono(size: 10, color: QuantTheme.accent),
                  ),
                  Text(
                    'VWAP: ₹${vwapVal.toStringAsFixed(2)}',
                    style: QuantTheme.mono(size: 10, color: QuantTheme.warning),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOptionChainWorkspace(
      UnderlyingIndex idx, List<StrikeRowSnapshot> rows, bool hasLiveData) {
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

    String fmtOptDiff(int? v) => v == null ? 'Collecting' : '${v >= 0 ? "+" : ""}$v lots';

    // Display ATM +/- 5 strikes cleanly in the table (full ATM +/- 12 used for GEX/PCR)
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
                      style: QuantTheme.mono(size: 10, color: QuantTheme.positive),
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
                      style: QuantTheme.mono(size: 10, color: QuantTheme.negative),
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
        child: Text('NO DATA — Connect broker API to compute Black-76 IV & Greeks.',
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
                  Text('Black-76 Volatility Surface & Underlying RV',
                      style: QuantTheme.heading(size: 11)),
                  QuantBadge(
                    text: surf.hasButterflyArbitrage ? 'CONCAVE WARN' : 'OLS FIT',
                    color: surf.hasButterflyArbitrage
                        ? QuantTheme.negative
                        : QuantTheme.positive,
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
                      label: '25Δ BF',
                      value: surf.butterfly25d != null
                          ? '${surf.butterfly25d!.toStringAsFixed(2)}%'
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
                '${surf.surfaceNote} | 15m Exp Move: ${rv.expectedMovePoints != null ? "±${rv.expectedMovePoints!.toStringAsFixed(1)} pts" : "Collecting SPOT bars"}',
                style: QuantTheme.label(size: 10),
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
                    Text('STRIKE', style: QuantTheme.heading(size: 10)),
                    Text('CE/PE IV%', style: QuantTheme.heading(size: 10)),
                    Text('CE/PE Δ', style: QuantTheme.heading(size: 10)),
                    Text('CE/PE Γ', style: QuantTheme.heading(size: 10)),
                    Text('CE/PE Θ', style: QuantTheme.heading(size: 10)),
                  ],
                ),
              ),
              ...displayRows.map((r) {
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
                      Text(
                        '${r.ceIv?.toStringAsFixed(1) ?? "--"}/${r.peIv?.toStringAsFixed(1) ?? "--"}%',
                        style: QuantTheme.mono(size: 10),
                      ),
                      Text(
                        '${r.ceDelta.toStringAsFixed(2)}/${r.peDelta.toStringAsFixed(2)}',
                        style: QuantTheme.mono(
                            size: 10, color: QuantTheme.positive),
                      ),
                      Text(
                        '${r.ceGamma.toStringAsFixed(4)}/${r.peGamma.toStringAsFixed(4)}',
                        style: QuantTheme.mono(size: 9),
                      ),
                      Text(
                        '${r.ceTheta.toStringAsFixed(1)}/${r.peTheta.toStringAsFixed(1)}',
                        style: QuantTheme.mono(
                            size: 10, color: QuantTheme.warning),
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
    final displayRows = rows.where((r) => r.offset.abs() <= 4).toList();
    return QuantPanel(
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
                Text('Real Order-Book Depth & Spread (${idx.label})',
                    style: QuantTheme.heading(size: 11)),
                Text('Null when absent',
                    style: QuantTheme.mono(size: 9, color: QuantTheme.accent)),
              ],
            ),
          ),
          ...displayRows.map((r) {
            final ceSpreadStr = (r.ceBid != null && r.ceAsk != null)
                ? '₹${(r.ceAsk! - r.ceBid!).abs().toStringAsFixed(2)}'
                : 'N/A';
            final ceImbStr = r.ceImbalance != null
                ? '${(r.ceImbalance! * 100).toStringAsFixed(0)}%'
                : 'N/A';
            final peImbStr = r.peImbalance != null
                ? '${(r.peImbalance! * 100).toStringAsFixed(0)}%'
                : 'N/A';
            return Container(
              padding: const EdgeInsets.all(9),
              decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: QuantTheme.border, width: 0.6)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${r.strike}',
                      style:
                          QuantTheme.mono(size: 11, color: QuantTheme.accent)),
                  Text('CE Vol ${r.ceVolume} | Sprd $ceSpreadStr | Imb $ceImbStr',
                      style:
                          QuantTheme.mono(size: 9, color: QuantTheme.positive)),
                  Text('PE Vol ${r.peVolume} | Imb $peImbStr',
                      style:
                          QuantTheme.mono(size: 9, color: QuantTheme.negative)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _QuantCandleChartPainter extends CustomPainter {
  final List<OneMinEnrichedBar> bars;
  final int touchedIdx;
  final bool showSpotOverlay;

  _QuantCandleChartPainter({
    required this.bars,
    required this.touchedIdx,
    required this.showSpotOverlay,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = QuantTheme.border.withOpacity(0.45)
      ..strokeWidth = 0.8;
    for (int i = 1; i <= 3; i++) {
      final y = size.height * (i / 4.0);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    if (bars.isEmpty) return;

    double minP = double.infinity, maxP = -double.infinity;
    double minS = double.infinity, maxS = -double.infinity;
    for (final b in bars) {
      if (b.low < minP) minP = b.low;
      if (b.high > maxP) maxP = b.high;
      if (b.underlyingSpot < minS) minS = b.underlyingSpot;
      if (b.underlyingSpot > maxS) maxS = b.underlyingSpot;
    }
    if (maxP <= minP) maxP = minP + 1.0;
    if (maxS <= minS) maxS = minS + 1.0;

    final n = bars.length;
    final slotW = size.width / math.max(1, n);
    final candleW = (slotW * 0.58).clamp(2.0, 9.0);
    final usableH = size.height - 16.0;
    final spotPath = Path();

    for (int i = 0; i < n; i++) {
      final b = bars[i];
      final cx = (i + 0.5) * slotW;
      double yFor(double p) =>
          usableH - ((p - minP) / (maxP - minP)) * (usableH - 12.0);
      final color =
          b.close >= b.open ? QuantTheme.positive : QuantTheme.negative;

      canvas.drawLine(Offset(cx, yFor(b.high)), Offset(cx, yFor(b.low)),
          Paint()..color = color..strokeWidth = 1.1);
      final yO = yFor(b.open);
      final yC = yFor(b.close);
      canvas.drawRect(
        Rect.fromLTWH(cx - candleW / 2, math.min(yO, yC), candleW,
            math.max(2.0, (yO - yC).abs())),
        Paint()..color = color,
      );

      final ySp = usableH -
          ((b.underlyingSpot - minS) / (maxS - minS)) * (usableH - 12.0);
      if (i == 0) {
        spotPath.moveTo(cx, ySp);
      } else {
        spotPath.lineTo(cx, ySp);
      }
    }

    if (showSpotOverlay) {
      canvas.drawPath(
        spotPath,
        Paint()
          ..color = QuantTheme.accent.withOpacity(0.7)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _QuantCandleChartPainter oldDelegate) => true;
}
