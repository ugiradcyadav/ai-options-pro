import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../core/ui_haptics.dart';
import '../../data/macro_data_engine.dart';
import '../../data/news_wire_engine.dart';
import '../../data/participant_oi_engine.dart';
import '../../engine/minor_intel_engine.dart';
import '../theme/quant_theme.dart';

/// LAYER 3 (MACRO): Near-Real-Time Global Indices, FX, Yields & Commodities Strip
class MacroCuesStripCard extends StatelessWidget {
  final MacroSnapshot snapshot;
  final VoidCallback onRefresh;

  const MacroCuesStripCard({
    super.key,
    required this.snapshot,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final bias = snapshot.biasLabel;
    final biasCol = bias == 'RISK-ON'
        ? QuantTheme.positive
        : (bias == 'RISK-OFF'
            ? QuantTheme.negative
            : (bias == 'MIXED' ? QuantTheme.warning : QuantTheme.textSecondary));
    final syncStr = snapshot.fetchedAtMs > 0
        ? DateFormat('HH:mm:ss')
            .format(DateTime.fromMillisecondsSinceEpoch(snapshot.fetchedAtMs))
        : '--:--';

    return QuantPanel(
      padding: const EdgeInsets.all(12),
      backgroundColor: QuantTheme.bgPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text('Global Macro & FX',
                      style: QuantTheme.heading(size: 11.5)),
                  const SizedBox(width: 6),
                  QuantBadge(text: bias, color: biasCol),
                ],
              ),
              GestureDetector(
                onTap: () {
                  UiHaptics.tap();
                  onRefresh();
                },
                child: Text(
                  '↻ $syncStr',
                  style: QuantTheme.mono(size: 9.5, color: QuantTheme.accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (snapshot.quotes.isEmpty)
            Text(
              'Loading live USD/INR, DXY, US10Y, Brent, Nasdaq & Gold...',
              style: QuantTheme.label(size: 10),
            )
          else ...[
            SizedBox(
              height: 54,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: snapshot.quotes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final q = snapshot.quotes[i];
                  final isUp = q.changePct >= 0;
                  final col =
                      isUp ? QuantTheme.positive : QuantTheme.negative;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: QuantTheme.bgMain,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: QuantTheme.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(q.label,
                            style: QuantTheme.label(
                                size: 8.5, color: QuantTheme.textSecondary)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              q.formattedPrice,
                              style: QuantTheme.mono(
                                  size: 11, weight: FontWeight.w800),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '${isUp ? "+" : ""}${q.changePct.toStringAsFixed(2)}%',
                              style: QuantTheme.mono(size: 9, color: col),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (snapshot.activeFlags.isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(
                '• ${snapshot.activeFlags.join("  |  ")}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: QuantTheme.label(
                  size: 9.5,
                  color: bias == 'RISK-OFF'
                      ? QuantTheme.warning
                      : QuantTheme.textSecondary,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// LAYER 1 (MINOR): Futures Basis + 0-DTE Straddle Decay + 5-Level Depth Ladder + Heavyweight Points + ORB
class MinorIntradayIntelCard extends StatelessWidget {
  final UnderlyingIndex index;
  final FuturesBasisSnapshot? futuresBasis;
  final IndexContributionSummary contribution;
  final StraddleGammaSnapshot? straddleGamma;
  final IntradayLevelsSnapshot orbLevels;
  final List<StrikeRowSnapshot> chainRows;
  final List<double> straddleHistory;
  final bool hasLiveData;

  const MinorIntradayIntelCard({
    super.key,
    required this.index,
    required this.futuresBasis,
    required this.contribution,
    required this.straddleGamma,
    required this.orbLevels,
    required this.chainRows,
    this.straddleHistory = const [],
    required this.hasLiveData,
  });

  @override
  Widget build(BuildContext context) {
    final anyAlert = (straddleGamma?.gammaBlastAlert == true) ||
        contribution.isNarrowTrap ||
        orbLevels.divergenceTrap;

    final depthRows = chainRows.where((r) => r.offset.abs() <= 2).toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));

    int sumBid = 0;
    int sumAsk = 0;
    for (final r in depthRows) {
      sumBid += r.ceBidQty + r.peBidQty;
      sumAsk += r.ceAskQty + r.peAskQty;
    }
    final totDepth = math.max(1, sumBid + sumAsk);
    final bidPct = (sumBid / totDepth) * 100.0;
    final askPct = (sumAsk / totDepth) * 100.0;

    return QuantPanel(
      padding: const EdgeInsets.all(14),
      borderColor: anyAlert ? QuantTheme.warning : QuantTheme.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Minor Intraday & 0-DTE Desk (${index.label})',
                  style: QuantTheme.heading(size: 12.5)),
              QuantBadge(
                text: straddleGamma?.gammaBlastAlert == true
                    ? 'GAMMA BLAST ZONE'
                    : (contribution.isNarrowTrap || orbLevels.divergenceTrap
                        ? 'TRAP ALERT'
                        : orbLevels.stateLabel),
                color: anyAlert
                    ? QuantTheme.warning
                    : (orbLevels.stateLabel == 'ABOVE ORB'
                        ? QuantTheme.positive
                        : (orbLevels.stateLabel == 'BELOW ORB'
                            ? QuantTheme.negative
                            : QuantTheme.accent)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!hasLiveData)
            Text(
              'NO DATA — Connect Angel One to stream Futures Basis, 0-DTE Straddle Decay, Depth Ladder & ORB.',
              style: QuantTheme.mono(size: 10, color: QuantTheme.negative),
            )
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                QuantMetricCell(
                  label: 'FUT BASIS',
                  value: futuresBasis != null
                      ? '${futuresBasis!.basisPoints >= 0 ? "+" : ""}${futuresBasis!.basisPoints.toStringAsFixed(1)}pt'
                      : 'Resolving',
                  valueColor: futuresBasis == null
                      ? QuantTheme.textSecondary
                      : (futuresBasis!.basisPoints >= 0
                          ? QuantTheme.positive
                          : QuantTheme.negative),
                ),
                QuantMetricCell(
                  label: straddleGamma?.isZeroDte == true
                      ? '0-DTE STRADDLE'
                      : 'ATM STRADDLE',
                  value: straddleGamma != null
                      ? '₹${straddleGamma!.atmStraddlePrice.toStringAsFixed(0)}'
                      : 'N/A',
                  valueColor: QuantTheme.accent,
                ),
                QuantMetricCell(
                  label: 'STRADDLE Δ',
                  value: straddleGamma?.decaySinceOpenPct != null
                      ? '${straddleGamma!.decaySinceOpenPct! >= 0 ? "+" : ""}${straddleGamma!.decaySinceOpenPct!.toStringAsFixed(1)}%'
                      : '--',
                  valueColor: (straddleGamma?.decaySinceOpenPct ?? 0) <= 0
                      ? QuantTheme.warning
                      : QuantTheme.positive,
                ),
                QuantMetricCell(
                  label: 'IMPLIED MOVE',
                  value: straddleGamma != null
                      ? '±${straddleGamma!.impliedMovePct.toStringAsFixed(2)}%'
                      : 'N/A',
                ),
              ],
            ),

            if (straddleHistory.length >= 2) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: QuantTheme.bgMain,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: QuantTheme.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ATM Straddle Decay Curve',
                              style: QuantTheme.heading(size: 10)),
                          Text(
                            '${straddleHistory.length} session points',
                            style: QuantTheme.label(size: 9),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      height: 30,
                      child: CustomPaint(
                        painter: MiniSeriesPainter(
                          values: straddleHistory,
                          color: (straddleGamma?.decaySinceOpenPct ?? 0) <= 0
                              ? QuantTheme.warning
                              : QuantTheme.positive,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (futuresBasis != null) ...[
              const SizedBox(height: 6),
              Text(
                '${futuresBasis!.tradingSymbol}: ${futuresBasis!.futuresLtp.toStringAsFixed(1)} • ${futuresBasis!.posture} (Δ ${futuresBasis!.basisDeltaPoints >= 0 ? "+" : ""}${futuresBasis!.basisDeltaPoints.toStringAsFixed(1)}pt) • OI ${futuresBasis!.futOiLots}L',
                style: QuantTheme.mono(
                    size: 9.5, color: QuantTheme.textSecondary),
              ),
            ],
            if (straddleGamma != null) ...[
              const SizedBox(height: 4),
              Text(
                straddleGamma!.statusNote,
                style: QuantTheme.label(
                  size: 9.5,
                  color: straddleGamma!.gammaBlastAlert
                      ? QuantTheme.warning
                      : QuantTheme.textSecondary,
                ),
              ),
            ],

            if (depthRows.isNotEmpty) ...[
              const Divider(color: QuantTheme.border, height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Order Book Depth Ladder (ATM ±2)',
                      style: QuantTheme.heading(size: 10.5)),
                  Text(
                    'Bids ${bidPct.toStringAsFixed(1)}% | Asks ${askPct.toStringAsFixed(1)}%',
                    style: QuantTheme.mono(
                        size: 9, color: QuantTheme.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ...depthRows.map((r) {
                final bQty = r.ceBidQty + r.peBidQty;
                final aQty = r.ceAskQty + r.peAskQty;
                final maxSide = math.max(1, math.max(bQty, aQty));
                final bRatio = (bQty / maxSide).clamp(0.05, 1.0).toDouble();
                final aRatio = (aQty / maxSide).clamp(0.05, 1.0).toDouble();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          QuantTheme.fmtLakhs(bQty),
                          style: QuantTheme.mono(
                              size: 9, color: QuantTheme.positive),
                        ),
                      ),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              width: bRatio * 68,
                              height: 7,
                              decoration: BoxDecoration(
                                color: QuantTheme.positive,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: r.offset == 0
                              ? QuantTheme.headerNavy
                              : QuantTheme.bgMain,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${r.strike}',
                          style: QuantTheme.mono(
                            size: 9,
                            color: r.offset == 0
                                ? Colors.white
                                : QuantTheme.textPrimary,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            Container(
                              width: aRatio * 68,
                              height: 7,
                              decoration: BoxDecoration(
                                color: QuantTheme.negative,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          QuantTheme.fmtLakhs(aQty),
                          textAlign: TextAlign.right,
                          style: QuantTheme.mono(
                              size: 9, color: QuantTheme.negative),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],

            const Divider(color: QuantTheme.border, height: 14),
            Text('Heavyweight Index Points Contribution',
                style: QuantTheme.heading(size: 10.5)),
            const SizedBox(height: 6),
            if (contribution.topDrivers.isEmpty)
              Text(contribution.trapNote, style: QuantTheme.label(size: 9.5))
            else ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: contribution.topDrivers.map((d) {
                  final pos = d.estIndexPoints >= 0;
                  final col = pos ? QuantTheme.positive : QuantTheme.negative;
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: col.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: col.withOpacity(0.45)),
                    ),
                    child: Text(
                      '${d.symbol} ${pos ? "+" : ""}${d.estIndexPoints.toStringAsFixed(1)}pt',
                      style: QuantTheme.mono(size: 9, color: col),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 6),
              Text(
                contribution.trapNote,
                style: QuantTheme.label(
                  size: 9.5,
                  color: contribution.isNarrowTrap
                      ? QuantTheme.warning
                      : QuantTheme.textPrimary,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: orbLevels.divergenceTrap
                    ? QuantTheme.warning.withOpacity(0.10)
                    : QuantTheme.bgMain,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '15m ORB: ${orbLevels.note}',
                style: QuantTheme.mono(
                  size: 9.5,
                  color: orbLevels.divergenceTrap
                      ? QuantTheme.warning
                      : QuantTheme.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class MiniSeriesPainter extends CustomPainter {
  final List<double> values;
  final Color color;

  MiniSeriesPainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    double minV = values.first;
    double maxV = values.first;
    for (final v in values) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final span = math.max(0.01, maxV - minV);
    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = (i / (values.length - 1)) * size.width;
      final norm = (values[i] - minV) / span;
      final y = size.height - (norm * (size.height - 6) + 3);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant MiniSeriesPainter oldDelegate) => true;
}

/// LAYER 2 (MAJOR): Official NSE Clearing Participant-Wise OI (FII / DII / Pro / Client)
class ParticipantOiCard extends StatelessWidget {
  final ParticipantOiSnapshot snapshot;
  final VoidCallback onRefresh;

  const ParticipantOiCard({
    super.key,
    required this.snapshot,
    required this.onRefresh,
  });

  static String _fmtSigned(int v) {
    final abs = v.abs();
    final sign = v >= 0 ? '+' : '-';
    if (abs >= 100000) return '$sign${(abs / 100000.0).toStringAsFixed(1)}L';
    if (abs >= 1000) return '$sign${(abs / 1000.0).toStringAsFixed(1)}K';
    return '$sign$abs';
  }

  @override
  Widget build(BuildContext context) {
    final fii = snapshot.fii;
    final fiiPct = fii?.futLongRatioPct ?? 50.0;

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
                  Text('Institutional OI (FII / DII / Pro)',
                      style: QuantTheme.heading(size: 12.5)),
                  Text(
                    snapshot.hasData
                        ? 'Official NSE EOD • ${snapshot.tradingDateLabel}'
                        : 'Official NSE Clearing CSV',
                    style: QuantTheme.label(size: 9.5),
                  ),
                ],
              ),
              GestureDetector(
                onTap: () {
                  UiHaptics.tap();
                  onRefresh();
                },
                child: QuantBadge(
                  text: snapshot.hasData
                      ? 'FII ${fiiPct.toStringAsFixed(0)}% L ↻'
                      : 'Fetch NSE ↻',
                  color: !snapshot.hasData
                      ? QuantTheme.accent
                      : (fiiPct >= 52
                          ? QuantTheme.positive
                          : (fiiPct <= 42
                              ? QuantTheme.negative
                              : QuantTheme.warning)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!snapshot.hasData)
            Text(
              snapshot.summaryNote,
              style: QuantTheme.label(size: 10, color: QuantTheme.warning),
            )
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (fiiPct / 100.0).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: QuantTheme.negative.withOpacity(0.25),
                valueColor: const AlwaysStoppedAnimation(QuantTheme.positive),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: const [
                Expanded(flex: 2, child: Text('GROUP', style: TextStyle(fontSize: 9, color: QuantTheme.textSecondary, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Text('NET FUT', textAlign: TextAlign.right, style: TextStyle(fontSize: 9, color: QuantTheme.textSecondary, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Text('NET CALL', textAlign: TextAlign.right, style: TextStyle(fontSize: 9, color: QuantTheme.textSecondary, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Text('NET PUT', textAlign: TextAlign.right, style: TextStyle(fontSize: 9, color: QuantTheme.textSecondary, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Text('FUT L%', textAlign: TextAlign.right, style: TextStyle(fontSize: 9, color: QuantTheme.textSecondary, fontWeight: FontWeight.w700))),
              ],
            ),
            const Divider(color: QuantTheme.border, height: 10),
            ...snapshot.rows.map((r) {
              Color colOf(int v) =>
                  v >= 0 ? QuantTheme.positive : QuantTheme.negative;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3.5),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(r.participant,
                          style: QuantTheme.heading(size: 10.5)),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(_fmtSigned(r.netIndexFutures),
                          textAlign: TextAlign.right,
                          style: QuantTheme.mono(
                              size: 10, color: colOf(r.netIndexFutures))),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(_fmtSigned(r.netIndexCalls),
                          textAlign: TextAlign.right,
                          style: QuantTheme.mono(
                              size: 10, color: colOf(r.netIndexCalls))),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(_fmtSigned(r.netIndexPuts),
                          textAlign: TextAlign.right,
                          style: QuantTheme.mono(
                              size: 10, color: colOf(r.netIndexPuts))),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text('${r.futLongRatioPct.toStringAsFixed(0)}%',
                          textAlign: TextAlign.right,
                          style: QuantTheme.mono(
                              size: 10, color: QuantTheme.accent)),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 6),
            Text(snapshot.summaryNote, style: QuantTheme.label(size: 9.5)),
          ],
        ],
      ),
    );
  }
}

/// DEDICATED BOTTOM SECTION: Live Official News & Announcements Wire (RBI / NSE / BSE)
class LiveNewsWireCard extends StatefulWidget {
  final List<MarketNewsItem> items;
  final int lastFetchedMs;
  final String errorNote;
  final VoidCallback onRefresh;

  const LiveNewsWireCard({
    super.key,
    required this.items,
    required this.lastFetchedMs,
    required this.errorNote,
    required this.onRefresh,
  });

  @override
  State<LiveNewsWireCard> createState() => _LiveNewsWireCardState();
}

class _LiveNewsWireCardState extends State<LiveNewsWireCard> {
  String _filter = 'ALL'; // 'ALL' | 'HIGH IMPACT' | 'RBI' | 'NSE' | 'BSE'
  bool _expanded = false;

  Color _sourceColor(String src) {
    if (src == 'RBI') return QuantTheme.warning;
    if (src == 'NSE') return QuantTheme.accent;
    return QuantTheme.positive;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.items.where((it) {
      if (_filter == 'ALL') return true;
      if (_filter == 'HIGH IMPACT') return it.isHighImpact;
      return it.source == _filter;
    }).toList();

    final visible =
        _expanded ? filtered.take(25).toList() : filtered.take(8).toList();
    final syncStr = widget.lastFetchedMs > 0
        ? DateFormat('HH:mm:ss')
            .format(DateTime.fromMillisecondsSinceEpoch(widget.lastFetchedMs))
        : '--:--';

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
                  Text('Official Announcements Wire',
                      style: QuantTheme.heading(size: 13)),
                  Text('RBI • NSE Filings • BSE Notices (Sync $syncStr)',
                      style: QuantTheme.label(size: 9.5)),
                ],
              ),
              GestureDetector(
                onTap: () {
                  UiHaptics.tap();
                  widget.onRefresh();
                },
                child: const QuantBadge(text: '↻ Live', color: QuantTheme.accent),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['ALL', 'HIGH IMPACT', 'RBI', 'NSE', 'BSE'].map((f) {
                final active = _filter == f;
                return GestureDetector(
                  onTap: () {
                    UiHaptics.tap();
                    setState(() => _filter = f);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.headerNavy : QuantTheme.bgMain,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: active
                            ? QuantTheme.headerNavy
                            : QuantTheme.border,
                      ),
                    ),
                    child: Text(
                      f,
                      style: QuantTheme.mono(
                        size: 9,
                        color: active ? Colors.white : QuantTheme.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const Divider(color: QuantTheme.border, height: 16),
          if (visible.isEmpty)
            Text(
              widget.errorNote.isNotEmpty
                  ? widget.errorNote
                  : 'No official announcements match "$_filter" yet. Tap Live to refresh.',
              style: QuantTheme.label(size: 10.5),
            )
          else ...[
            ...visible.map((it) {
              final dtStr = it.timestampMs > 0
                  ? DateFormat('dd MMM • HH:mm')
                      .format(DateTime.fromMillisecondsSinceEpoch(it.timestampMs))
                  : it.pubDateRaw;
              return GestureDetector(
                onTap: () {
                  UiHaptics.light();
                  if (it.link.isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: it.link));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: QuantTheme.headerNavy,
                        content: Text(
                          'Official ${it.source} link copied: ${it.link}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: const BoxDecoration(
                    border: Border(
                        bottom:
                            BorderSide(color: QuantTheme.border, width: 0.7)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              QuantBadge(
                                text: it.source,
                                color: _sourceColor(it.source),
                              ),
                              const SizedBox(width: 6),
                              if (it.isHighImpact)
                                QuantBadge(
                                  text: it.impactTag,
                                  color: QuantTheme.negative,
                                ),
                            ],
                          ),
                          Text(dtStr,
                              style: QuantTheme.mono(
                                  size: 8.5, color: QuantTheme.textSecondary)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        it.title,
                        style: QuantTheme.label(
                          size: 11,
                          color: QuantTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            if (filtered.length > 8) ...[
              const SizedBox(height: 8),
              Center(
                child: GestureDetector(
                  onTap: () {
                    UiHaptics.tap();
                    setState(() => _expanded = !_expanded);
                  },
                  child: QuantBadge(
                    text: _expanded
                        ? 'Show Fewer Updates'
                        : 'Show More (${filtered.length} updates)',
                    color: QuantTheme.accent,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
