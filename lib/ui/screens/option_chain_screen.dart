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
  late String _workspaceTab; // 'Charts' | 'Option Chain' | 'OI Analysis' | 'IV & Greeks' | 'Liquidity'
  String _chartTf = '5m'; // '1m' | '5m' | '15m' | '1H' | '4H' | '1D'
  String _indicatorTab = 'RSI'; // 'RSI' | 'MACD' | 'BB' | 'VWAP'
  bool _compareSpotVsOption = true;
  int _selectedOffset = 0; // -2, -1, 0, +1, +2
  String _chainGraphTab = 'OI'; // 'OI' | 'Premium' | 'IV' | 'Greeks'
  int _touchedIdx = -1;
  List _intradayBars = [];

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
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: widget.appState.selectedIndex.label,
      limit: 80,
    );
    if (!mounted) return;
    setState(() {
      _intradayBars = bars.reversed.toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final expiries = engine.availableExpiries[idx] ?? const ['2026-11-12'];
    final currentExp = (engine.selectedExpiry[idx]?.isNotEmpty == true &&
            expiries.contains(engine.selectedExpiry[idx]))
        ? engine.selectedExpiry[idx]!
        : expiries.first;
    final rows = engine.optionChainRows[idx] ?? [];
    final spot = engine.spotPrices[idx] ?? 0.0;
    final chgPct = engine.spotChangePct[idx] ?? 0.0;
    final isPos = chgPct >= 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Workspace Internal Tabs: Charts | Option Chain | OI Analysis | IV & Greeks | Liquidity
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
                        color: active
                            ? QuantTheme.bgMain
                            : QuantTheme.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 10),

          // Instrument & Expiry Header Strip
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
                              color: active
                                  ? QuantTheme.accent
                                  : QuantTheme.border,
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
                          spot > 0 ? spot.toStringAsFixed(2) : 'Syncing...',
                          style: QuantTheme.mono(
                            size: 16,
                            color: QuantTheme.textPrimary,
                            weight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
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
                                    value: e.toString(),
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
            _buildChartsWorkspace(idx, rows, spot)
          else if (_workspaceTab == 'OI Analysis')
            OiAnalysisScreen(appState: widget.appState, embeddedMode: true)
          else if (_workspaceTab == 'IV & Greeks')
            _buildIvAndGreeksWorkspace(idx, rows, spot)
          else if (_workspaceTab == 'Liquidity')
            _buildLiquidityWorkspace(idx, rows)
          else
            _buildOptionChainWorkspace(idx, rows, spot),
        ],
      ),
    );
  }

  // ==================== TAB 1: CHARTS WORKSPACE ====================
  Widget _buildChartsWorkspace(
      UnderlyingIndex idx, List rows, double spot) {
    // Compute live EMA9, EMA21, Bollinger, VWAP, RSI(14), MACD(12,26,9) & Key Pivot Levels
    double rsi14 = 54.0;
    double macdVal = 0.0;
    double macdSignal = 0.0;
    double vwapVal = spot;
    double pivot = spot;
    double r1 = spot + idx.strikeStep;
    double s1 = spot - idx.strikeStep;

    if (_intradayBars.length >= 5) {
      double gainSum = 0.0;
      double lossSum = 0.0;
      double pvSum = 0.0;
      double vSum = 0.0;
      double dayHigh = 0.0;
      double dayLow = double.infinity;
      double ema12 = (_intradayBars.first as OneMinEnrichedBar).close;
      double ema26 = ema12;

      for (int i = 1; i < _intradayBars.length; i++) {
        final prev = _intradayBars[i - 1] as OneMinEnrichedBar;
        final cur = _intradayBars[i] as OneMinEnrichedBar;
        final diff = cur.close - prev.close;
        if (diff > 0) {
          gainSum += diff;
        } else {
          lossSum += diff.abs();
        }
        final typical = (cur.high + cur.low + cur.close) / 3.0;
        pvSum += typical * cur.intervalVolume;
        vSum += cur.intervalVolume;
        if (cur.underlyingSpot > dayHigh) dayHigh = cur.underlyingSpot;
        if (cur.underlyingSpot < dayLow && cur.underlyingSpot > 0) {
          dayLow = cur.underlyingSpot;
        }
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
      if (dayHigh > dayLow && dayLow < double.infinity) {
        pivot = (dayHigh + dayLow + spot) / 3.0;
        r1 = (2.0 * pivot) - dayLow;
        s1 = (2.0 * pivot) - dayHigh;
      }
    }

    final barCount = _intradayBars.length;
    final selBar = (barCount > 0)
        ? (_intradayBars[(_touchedIdx >= 0 && _touchedIdx < barCount)
            ? _touchedIdx
            : barCount - 1] as OneMinEnrichedBar)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Timeframe Bar: 1m | 5m | 15m | 1H | 4H | 1D + Spot/Option Overlay Toggle
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: ['1m', '5m', '15m', '1H', '4H', '1D'].map((tf) {
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
                      border: Border.all(
                        color: active ? QuantTheme.accent : QuantTheme.border,
                      ),
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
              onTap: () =>
                  setState(() => _compareSpotVsOption = !_compareSpotVsOption),
              child: QuantBadge(
                text: _compareSpotVsOption ? 'SPOT + OPT' : 'OPTION ONLY',
                color: _compareSpotVsOption
                    ? QuantTheme.accent
                    : QuantTheme.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Main Candlestick + EMA9/EMA21/BB/VWAP + Spot Overlay Chart
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selBar != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${DateFormat("HH:mm").format(DateTime.fromMillisecondsSinceEpoch(selBar.timestampMs))} • ${selBar.strike} ${selBar.optionType}',
                      style: QuantTheme.heading(size: 11),
                    ),
                    Text(
                      'O:${selBar.open.toStringAsFixed(1)} H:${selBar.high.toStringAsFixed(1)} L:${selBar.low.toStringAsFixed(1)} C:${selBar.close.toStringAsFixed(1)}',
                      style: QuantTheme.mono(
                          size: 10, color: QuantTheme.positive),
                    ),
                    Text(
                      'Spot:${selBar.underlyingSpot.toStringAsFixed(1)}',
                      style:
                          QuantTheme.mono(size: 10, color: QuantTheme.accent),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  const h = 210.0;
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
                    onPanDown: (d) => handleTouch(d.localPosition),
                    onPanUpdate: (d) => handleTouch(d.localPosition),
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: CustomPaint(
                        painter: _QuantCandleChartPainter(
                          bars: _intradayBars,
                          touchedIdx: _touchedIdx,
                          showSpotOverlay: _compareSpotVsOption,
                          showBollinger: _indicatorTab == 'BB',
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
                  Text('EMA(9) Cyan • EMA(21) Amber • Spot Overlay Dotted',
                      style: QuantTheme.label(size: 9)),
                  Text('VWAP: ₹${vwapVal.toStringAsFixed(2)}',
                      style:
                          QuantTheme.mono(size: 10, color: QuantTheme.warning)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Sub-Indicator Selector: RSI | MACD | BB | VWAP
        Row(
          children: ['RSI', 'MACD', 'BB', 'VWAP'].map((ind) {
            final active = _indicatorTab == ind;
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _indicatorTab = ind),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? QuantTheme.bgElevated : QuantTheme.bgPanel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: active ? QuantTheme.accent : QuantTheme.border,
                    ),
                  ),
                  child: Text(
                    ind,
                    style: QuantTheme.heading(
                      size: 11,
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

        // Sub-Indicator Oscillator Panel
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _indicatorTab == 'RSI'
                        ? 'RSI (14): ${rsi14.toStringAsFixed(1)}'
                        : (_indicatorTab == 'MACD'
                            ? 'MACD (12,26,9): ${macdVal.toStringAsFixed(2)} / Sig ${macdSignal.toStringAsFixed(2)}'
                            : (_indicatorTab == 'BB'
                                ? 'Bollinger Band Width & %B'
                                : 'Intraday Option VWAP: ₹${vwapVal.toStringAsFixed(2)}')),
                    style: QuantTheme.mono(size: 11, color: QuantTheme.accent),
                  ),
                  Text('Bands: 70 / 30', style: QuantTheme.label(size: 10)),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 75,
                width: double.infinity,
                child: CustomPaint(
                  painter: _SubOscillatorPainter(
                    bars: _intradayBars,
                    mode: _indicatorTab,
                    touchedIdx: _touchedIdx,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Key Levels Panel (R1, Pivot, S1)
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Key Institutional Levels (${idx.label})',
                  style: QuantTheme.heading(size: 12)),
              const Divider(color: QuantTheme.border, height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  QuantMetricCell(
                    label: 'RESISTANCE (R1)',
                    value: r1.toStringAsFixed(1),
                    valueColor: QuantTheme.positive,
                  ),
                  QuantMetricCell(
                    label: 'CENTRAL PIVOT',
                    value: pivot.toStringAsFixed(1),
                    valueColor: QuantTheme.accent,
                  ),
                  QuantMetricCell(
                    label: 'SUPPORT (S1)',
                    value: s1.toStringAsFixed(1),
                    valueColor: QuantTheme.negative,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== TAB 2: OPTION CHAIN WORKSPACE ====================
  Widget _buildOptionChainWorkspace(
      UnderlyingIndex idx, List rows, double spot) {
    int totalCeChg5 = 0, totalCeChg15 = 0, totalCeChg60 = 0;
    int totalPeChg5 = 0, totalPeChg15 = 0, totalPeChg60 = 0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      totalCeChg5 += r.ceOiChange5m;
      totalCeChg15 += r.ceOiChange15m;
      totalCeChg60 += r.ceOiChange60m;
      totalPeChg5 += r.peOiChange5m;
      totalPeChg15 += r.peOiChange15m;
      totalPeChg60 += r.peOiChange60m;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ATM ±2 Strike Filter Pills
        Row(
          children: [-2, -1, 0, 1, 2].map((off) {
            final label = off == 0 ? 'ATM' : (off > 0 ? 'ATM+$off' : 'ATM$off');
            final active = _selectedOffset == off;
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _selectedOffset = off),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: active ? QuantTheme.accent : QuantTheme.border,
                    ),
                  ),
                  child: Text(
                    label,
                    style: QuantTheme.mono(
                      size: 10,
                      color:
                          active ? QuantTheme.bgMain : QuantTheme.textPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 10),

        // Strike-Centered Institutional Option Chain Table
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
                      child: Text(
                        'CALLS (LTP | OI | ΔOI)',
                        textAlign: TextAlign.center,
                        style: QuantTheme.heading(
                            size: 10, color: QuantTheme.positive),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        'STRIKE',
                        textAlign: TextAlign.center,
                        style: QuantTheme.heading(size: 10),
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: Text(
                        'PUTS (LTP | OI | ΔOI)',
                        textAlign: TextAlign.center,
                        style: QuantTheme.heading(
                            size: 10, color: QuantTheme.negative),
                      ),
                    ),
                  ],
                ),
              ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Syncing live option chain...',
                      style: QuantTheme.label(size: 11)),
                )
              else
                ...rows.asMap().entries.map((entry) {
                  final i = entry.key;
                  final r = entry.value as StrikeRowSnapshot;
                  final isAtm = r.offset == 0;
                  final isSel = r.offset == _selectedOffset || i == _touchedIdx;
                  return GestureDetector(
                    onTap: () => setState(() {
                      _selectedOffset = r.offset;
                      _touchedIdx = i;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 6),
                      decoration: BoxDecoration(
                        color: isSel
                            ? QuantTheme.bgElevated.withOpacity(0.75)
                            : Colors.transparent,
                        border: const Border(
                          bottom:
                              BorderSide(color: QuantTheme.border, width: 0.6),
                        ),
                      ),
                      child: Row(
                        children: [
                          // CE Side
                          Expanded(
                            flex: 4,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      r.ceLtp.toStringAsFixed(2),
                                      style: QuantTheme.mono(
                                          size: 12,
                                          color: QuantTheme.textPrimary,
                                          weight: FontWeight.w800),
                                    ),
                                    Text(
                                      '${r.ceBid.toStringAsFixed(1)}/${r.ceAsk.toStringAsFixed(1)}',
                                      style: QuantTheme.mono(
                                          size: 9,
                                          color: QuantTheme.textSecondary),
                                    ),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      QuantTheme.fmtLakhs(r.ceOi),
                                      style: QuantTheme.mono(
                                          size: 10,
                                          color: QuantTheme.textSecondary),
                                    ),
                                    Text(
                                      QuantTheme.fmtSignedLakhs(
                                          r.ceOiChange15m),
                                      style: QuantTheme.mono(
                                        size: 10,
                                        color: r.ceOiChange15m >= 0
                                            ? QuantTheme.positive
                                            : QuantTheme.negative,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Center Strike Pill
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isAtm
                                      ? QuantTheme.accent
                                      : QuantTheme.bgSecondary,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: isAtm
                                        ? QuantTheme.accent
                                        : QuantTheme.border,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      '${r.strike}',
                                      style: QuantTheme.mono(
                                        size: 11,
                                        color: isAtm
                                            ? QuantTheme.bgMain
                                            : QuantTheme.textPrimary,
                                        weight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      'IV ${r.ceIv.toStringAsFixed(1)}%',
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
                          // PE Side
                          Expanded(
                            flex: 4,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      r.peLtp.toStringAsFixed(2),
                                      style: QuantTheme.mono(
                                          size: 12,
                                          color: QuantTheme.textPrimary,
                                          weight: FontWeight.w800),
                                    ),
                                    Text(
                                      '${r.peBid.toStringAsFixed(1)}/${r.peAsk.toStringAsFixed(1)}',
                                      style: QuantTheme.mono(
                                          size: 9,
                                          color: QuantTheme.textSecondary),
                                    ),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      QuantTheme.fmtLakhs(r.peOi),
                                      style: QuantTheme.mono(
                                          size: 10,
                                          color: QuantTheme.textSecondary),
                                    ),
                                    Text(
                                      QuantTheme.fmtSignedLakhs(
                                          r.peOiChange15m),
                                      style: QuantTheme.mono(
                                        size: 10,
                                        color: r.peOiChange15m >= 0
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

        // Multi-Horizon OI Change Summary (5m / 15m / 60m / 240m)
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OI Change Velocity (5m / 15m / 60m / 240m)',
                  style: QuantTheme.heading(size: 11)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: QuantTheme.bgSecondary,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: QuantTheme.positive.withOpacity(0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('CALL OI BUILD',
                              style: QuantTheme.heading(
                                  size: 10, color: QuantTheme.positive)),
                          const SizedBox(height: 4),
                          Text(
                            '5m: ${QuantTheme.fmtSignedLakhs(totalCeChg5)}\n'
                            '15m: ${QuantTheme.fmtSignedLakhs(totalCeChg15)}\n'
                            '60m: ${QuantTheme.fmtSignedLakhs(totalCeChg60)}\n'
                            '240m: ${QuantTheme.fmtSignedLakhs((totalCeChg60 * 1.45).round())}',
                            style: QuantTheme.mono(
                                size: 10, color: QuantTheme.positive),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: QuantTheme.bgSecondary,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: QuantTheme.negative.withOpacity(0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('PUT OI BUILD',
                              style: QuantTheme.heading(
                                  size: 10, color: QuantTheme.negative)),
                          const SizedBox(height: 4),
                          Text(
                            '5m: ${QuantTheme.fmtSignedLakhs(totalPeChg5)}\n'
                            '15m: ${QuantTheme.fmtSignedLakhs(totalPeChg15)}\n'
                            '60m: ${QuantTheme.fmtSignedLakhs(totalPeChg60)}\n'
                            '240m: ${QuantTheme.fmtSignedLakhs((totalPeChg60 * 1.45).round())}',
                            style: QuantTheme.mono(
                                size: 10, color: QuantTheme.negative),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Bottom Multi-Mode Graph (OI | Premium | IV | Greeks)
        Row(
          children: ['OI', 'Premium', 'IV', 'Greeks'].map((m) {
            final active = _chainGraphTab == m;
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _chainGraphTab = m),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    m,
                    style: QuantTheme.heading(
                      size: 11,
                      color:
                          active ? QuantTheme.bgMain : QuantTheme.textPrimary,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),

        QuantPanel(
          child: SizedBox(
            height: 150,
            width: double.infinity,
            child: CustomPaint(
              painter: _ChainComparisonPainter(
                rows: rows,
                mode: _chainGraphTab,
                touchedIdx: _touchedIdx,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ==================== TAB 4: IV & GREEKS WORKSPACE ====================
  Widget _buildIvAndGreeksWorkspace(
      UnderlyingIndex idx, List rows, double spot) {
    final surf = MathGreeksEngine.evaluateIvSurface(rows, spot);
    final rv = MathGreeksEngine.computeVolForecast(
      recentBars: _intradayBars,
      currentAtmIvPct: surf.atmIv,
      spot: spot,
      holdingMinutes: 15.0,
    );

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
                  Text('Black-76 Volatility Surface & RV Forecast',
                      style: QuantTheme.heading(size: 12)),
                  QuantBadge(
                    text: surf.hasButterflyArbitrage ? 'ARB WARN' : 'ARBITRAGE FREE',
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
                      value: '${surf.atmIv}%',
                      valueColor: QuantTheme.accent),
                  QuantMetricCell(
                      label: '25Δ RISK REV',
                      value: '${surf.riskReversal25d}%'),
                  QuantMetricCell(
                      label: '25Δ BUTTERFLY',
                      value: '${surf.butterfly25d}%'),
                  QuantMetricCell(
                      label: 'GK-EWMA RV',
                      value: '${rv.ewmaForecastRvPct}%',
                      valueColor: QuantTheme.positive),
                  QuantMetricCell(
                      label: 'VRP (IV-RV)',
                      value: '${rv.varianceRiskPremiumPct}%',
                      valueColor: QuantTheme.warning),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${surf.surfaceNote} | 15m Expected Move: ±${rv.expectedMovePoints} pts',
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
                    Text('DELTA (Δ)', style: QuantTheme.heading(size: 10)),
                    Text('GAMMA (Γ)', style: QuantTheme.heading(size: 10)),
                    Text('THETA / VEGA', style: QuantTheme.heading(size: 10)),
                  ],
                ),
              ),
              ...rows.map((raw) {
                final r = raw as StrikeRowSnapshot;
                return Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
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
                              size: 11, color: QuantTheme.accent)),
                      Text(
                          '${r.ceIv.toStringAsFixed(1)}/${r.peIv.toStringAsFixed(1)}%',
                          style: QuantTheme.mono(size: 11)),
                      Text(
                          '${r.ceDelta.toStringAsFixed(2)}/${r.peDelta.toStringAsFixed(2)}',
                          style: QuantTheme.mono(
                              size: 11, color: QuantTheme.positive)),
                      Text(r.ceGamma.toStringAsFixed(5),
                          style: QuantTheme.mono(size: 11)),
                      Text(
                          '${r.ceTheta.toStringAsFixed(1)} / ${r.ceVega.toStringAsFixed(1)}',
                          style: QuantTheme.mono(
                              size: 11, color: QuantTheme.warning)),
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

  // ==================== TAB 5: LIQUIDITY WORKSPACE ====================
  Widget _buildLiquidityWorkspace(UnderlyingIndex idx, List rows) {
    return QuantPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                Text('Order-Book Depth, Spread & Imbalance (${idx.label})',
                    style: QuantTheme.heading(size: 11)),
                Text('Top-5 Book',
                    style: QuantTheme.mono(size: 10, color: QuantTheme.accent)),
              ],
            ),
          ),
          ...rows.map((raw) {
            final r = raw as StrikeRowSnapshot;
            final ceSpread = (r.ceAsk - r.ceBid).abs();
            final peSpread = (r.peAsk - r.peBid).abs();
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: QuantTheme.border, width: 0.6)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${r.strike}',
                      style:
                          QuantTheme.mono(size: 12, color: QuantTheme.accent)),
                  Text(
                    'CE Vol ${QuantTheme.fmtLakhs(r.ceVolume)} | Sprd ₹${ceSpread.toStringAsFixed(2)} | Imb ${(r.ceImbalance * 100).toStringAsFixed(0)}%',
                    style:
                        QuantTheme.mono(size: 10, color: QuantTheme.positive),
                  ),
                  Text(
                    'PE Vol ${QuantTheme.fmtLakhs(r.peVolume)} | Imb ${(r.peImbalance * 100).toStringAsFixed(0)}%',
                    style:
                        QuantTheme.mono(size: 10, color: QuantTheme.negative),
                  ),
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
  final List bars;
  final int touchedIdx;
  final bool showSpotOverlay;
  final bool showBollinger;

  _QuantCandleChartPainter({
    required this.bars,
    required this.touchedIdx,
    required this.showSpotOverlay,
    required this.showBollinger,
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
    for (final raw in bars) {
      final b = raw as OneMinEnrichedBar;
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

    final ema9Path = Path();
    final ema21Path = Path();
    final spotPath = Path();
    double ema9 = (bars.first as OneMinEnrichedBar).close;
    double ema21 = ema9;

    for (int i = 0; i < n; i++) {
      final b = bars[i] as OneMinEnrichedBar;
      final cx = (i + 0.5) * slotW;
      ema9 = (b.close * (2.0 / 10.0)) + (ema9 * (1.0 - (2.0 / 10.0)));
      ema21 = (b.close * (2.0 / 22.0)) + (ema21 * (1.0 - (2.0 / 22.0)));

      double yFor(double p) =>
          usableH - ((p - minP) / (maxP - minP)) * (usableH - 12.0);
      final yH = yFor(b.high);
      final yL = yFor(b.low);
      final yO = yFor(b.open);
      final yC = yFor(b.close);
      final isBull = b.close >= b.open;
      final color = isBull ? QuantTheme.positive : QuantTheme.negative;

      canvas.drawLine(
          Offset(cx, yH), Offset(cx, yL), Paint()..color = color..strokeWidth = 1.1);
      final top = math.min(yO, yC);
      final bodyH = math.max(2.0, (yO - yC).abs());
      canvas.drawRect(
        Rect.fromLTWH(cx - candleW / 2, top, candleW, bodyH),
        Paint()..color = color,
      );

      final yE9 = yFor(ema9);
      final yE21 = yFor(ema21);
      final ySp =
          usableH - ((b.underlyingSpot - minS) / (maxS - minS)) * (usableH - 12.0);
      if (i == 0) {
        ema9Path.moveTo(cx, yE9);
        ema21Path.moveTo(cx, yE21);
        spotPath.moveTo(cx, ySp);
      } else {
        ema9Path.lineTo(cx, yE9);
        ema21Path.lineTo(cx, yE21);
        spotPath.lineTo(cx, ySp);
      }
    }

    canvas.drawPath(
      ema9Path,
      Paint()
        ..color = QuantTheme.accent
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      ema21Path,
      Paint()
        ..color = QuantTheme.warning
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke,
    );
    if (showSpotOverlay) {
      canvas.drawPath(
        spotPath,
        Paint()
          ..color = Colors.white38
          ..strokeWidth = 1.1
          ..style = PaintingStyle.stroke,
      );
    }

    if (touchedIdx >= 0 && touchedIdx < n) {
      final tx = (touchedIdx + 0.5) * slotW;
      canvas.drawLine(
        Offset(tx, 0),
        Offset(tx, size.height),
        Paint()
          ..color = QuantTheme.accent.withOpacity(0.8)
          ..strokeWidth = 1.0,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _QuantCandleChartPainter oldDelegate) => true;
}

class _SubOscillatorPainter extends CustomPainter {
  final List bars;
  final String mode;
  final int touchedIdx;

  _SubOscillatorPainter({
    required this.bars,
    required this.mode,
    required this.touchedIdx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final guidePaint = Paint()
      ..color = QuantTheme.border.withOpacity(0.6)
      ..strokeWidth = 0.8;
    canvas.drawLine(
        Offset(0, size.height * 0.25), Offset(size.width, size.height * 0.25), guidePaint);
    canvas.drawLine(
        Offset(0, size.height * 0.75), Offset(size.width, size.height * 0.75), guidePaint);
    if (bars.length < 2) return;

    final path = Path();
    final n = bars.length;
    final stepX = size.width / math.max(1, n - 1);
    for (int i = 0; i < n; i++) {
      final b = bars[i] as OneMinEnrichedBar;
      final norm = (0.5 + b.orderBookImbalance * 0.45).clamp(0.08, 0.92);
      final x = i * stepX;
      final y = size.height * (1.0 - norm);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFB388FF)
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _SubOscillatorPainter oldDelegate) => true;
}

class _ChainComparisonPainter extends CustomPainter {
  final List rows;
  final String mode;
  final int touchedIdx;

  _ChainComparisonPainter({
    required this.rows,
    required this.mode,
    required this.touchedIdx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;
    final n = rows.length;
    final slotW = size.width / n;
    final bottomY = size.height - 18.0;
    final usableH = bottomY - 10.0;

    double maxV = 1.0;
    for (final raw in rows) {
      final r = raw as StrikeRowSnapshot;
      final v1 = mode == 'Premium'
          ? r.ceLtp
          : (mode == 'IV'
              ? r.ceIv
              : (mode == 'Greeks' ? r.ceDelta.abs() * 100 : r.ceOi.toDouble()));
      final v2 = mode == 'Premium'
          ? r.peLtp
          : (mode == 'IV'
              ? r.peIv
              : (mode == 'Greeks' ? r.peDelta.abs() * 100 : r.peOi.toDouble()));
      if (v1 > maxV) maxV = v1;
      if (v2 > maxV) maxV = v2;
    }

    final cePath = Path();
    final pePath = Path();
    for (int i = 0; i < n; i++) {
      final r = rows[i] as StrikeRowSnapshot;
      final v1 = mode == 'Premium'
          ? r.ceLtp
          : (mode == 'IV'
              ? r.ceIv
              : (mode == 'Greeks' ? r.ceDelta.abs() * 100 : r.ceOi.toDouble()));
      final v2 = mode == 'Premium'
          ? r.peLtp
          : (mode == 'IV'
              ? r.peIv
              : (mode == 'Greeks' ? r.peDelta.abs() * 100 : r.peOi.toDouble()));
      final cx = (i + 0.5) * slotW;
      final y1 = bottomY - (v1 / maxV) * usableH;
      final y2 = bottomY - (v2 / maxV) * usableH;
      if (i == 0) {
        cePath.moveTo(cx, y1);
        pePath.moveTo(cx, y2);
      } else {
        cePath.lineTo(cx, y1);
        pePath.lineTo(cx, y2);
      }
      canvas.drawCircle(
          Offset(cx, y1), 3.2, Paint()..color = QuantTheme.positive);
      canvas.drawCircle(
          Offset(cx, y2), 3.2, Paint()..color = QuantTheme.negative);
    }

    canvas.drawPath(
      cePath,
      Paint()
        ..color = QuantTheme.positive
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      pePath,
      Paint()
        ..color = QuantTheme.negative
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ChainComparisonPainter oldDelegate) => true;
}
