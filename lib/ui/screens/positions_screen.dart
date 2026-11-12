import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/risk_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/v2_control_dialogs.dart';

class PositionsScreen extends StatefulWidget {
  final AppState appState;
  final String initialTab;

  const PositionsScreen({
    super.key,
    required this.appState,
    this.initialTab = 'Positions',
  });

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  late String _activeTab; // 'Positions' | 'Orders' | 'History' | 'Risk'
  String _orderStatusFilter = 'ALL';

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
  }

  Color _statusColor(String status) {
    final s = status.toUpperCase();
    if (s.contains('FILL') && !s.contains('PART')) return QuantTheme.positive;
    if (s.contains('PART')) return QuantTheme.accent;
    if (s.contains('PEND') || s.contains('ACCEPT') || s.contains('OPEN')) {
      return QuantTheme.warning;
    }
    if (s.contains('REJ') || s.contains('CANCEL')) return QuantTheme.negative;
    return QuantTheme.textSecondary;
  }

  String _normalizeStatusBadge(String raw) {
    final s = raw.toUpperCase();
    if (s.contains('PART')) return 'PARTIALLY FILLED';
    if (s.contains('FILL')) return 'FILLED';
    if (s.contains('ACCEPT')) return 'ACCEPTED';
    if (s.contains('PEND')) return 'PENDING';
    if (s.contains('REJ')) return 'REJECTED';
    if (s.contains('CANCEL')) return 'CANCELLED';
    return s;
  }

  void _openPositionExecutionDetails(PositionRecord pos) {
    final idx = widget.appState.selectedIndex;
    final spot = DhanDataEngine.instance.spotPrices[idx] ?? pos.strike.toDouble();
    final curLtp = pos.currentLtp > 0 ? pos.currentLtp : pos.avgEntryPrice;
    final grossPnl = (curLtp - pos.avgEntryPrice) * pos.quantity;
    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: pos.avgEntryPrice,
      exitPremium: curLtp,
      quantity: pos.quantity,
    );
    final netPnl = grossPnl - costs.totalFrictionInr;
    final pnlPct = pos.avgEntryPrice > 0
        ? ((curLtp - pos.avgEntryPrice) / pos.avgEntryPrice) * 100.0
        : 0.0;

    showModalBottomSheet(
      context: context,
      backgroundColor: QuantTheme.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${pos.indexName} ${pos.strike} ${pos.optionType} (${pos.mode})',
                  style: QuantTheme.heading(size: 14),
                ),
                QuantBadge(
                  text: pos.isOpen ? 'OPEN POSITION' : 'CLOSED',
                  color: pos.isOpen ? QuantTheme.positive : QuantTheme.textSecondary,
                ),
              ],
            ),
            const Divider(color: QuantTheme.border, height: 16),
            _kvRow('Position ID', pos.positionId),
            _kvRow('Expiry & Underlying Spot', '${pos.expiry}  |  Spot ${spot.toStringAsFixed(2)}'),
            _kvRow('Quantity', '${pos.quantity} qty'),
            _kvRow('Average Entry Premium', '₹${pos.avgEntryPrice.toStringAsFixed(2)}'),
            _kvRow('Current Market Premium', '₹${curLtp.toStringAsFixed(2)}',
                color: QuantTheme.accent),
            _kvRow('Stop-Loss / Target Level',
                'SL ₹${pos.stopLoss.toStringAsFixed(2)}  |  Tgt ₹${pos.target.toStringAsFixed(2)}'),
            _kvRow(
              'Gross P&L',
              '${grossPnl >= 0 ? "+" : ""}₹${grossPnl.toStringAsFixed(2)} (${pnlPct.toStringAsFixed(2)}%)',
              color: grossPnl >= 0 ? QuantTheme.positive : QuantTheme.negative,
            ),
            _kvRow('Est. Statutory Charges + Slippage',
                '₹${costs.totalFrictionInr.toStringAsFixed(2)}'),
            _kvRow(
              'Net Realizable P&L',
              '${netPnl >= 0 ? "+" : ""}₹${netPnl.toStringAsFixed(2)}',
              color: netPnl >= 0 ? QuantTheme.positive : QuantTheme.negative,
            ),
            const SizedBox(height: 14),
            if (pos.isOpen)
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: QuantTheme.negative,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await widget.appState.closePosition(pos.positionId);
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.exit_to_app, size: 17),
                  label: const Text('Square-Off / Close Position Now'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = DhanDataEngine.instance;
    final openPos =
        widget.appState.openPositions.where((p) => p.isOpen).toList();
    final closedPos =
        widget.appState.openPositions.where((p) => !p.isOpen).toList();
    final allOrders = widget.appState.orders;
    final riskCfg = widget.appState.riskConfig;

    double usedMargin = 0.0;
    double openUnrealizedPnl = 0.0;
    for (final p in openPos) {
      usedMargin += p.avgEntryPrice * p.quantity;
      final ltp = p.currentLtp > 0 ? p.currentLtp : p.avgEntryPrice;
      openUnrealizedPnl += (ltp - p.avgEntryPrice) * p.quantity;
    }

    double realizedDayPnl = 0.0;
    for (final p in closedPos) {
      realizedDayPnl += p.realizedPnl;
    }
    final totalPnl = openUnrealizedPnl + realizedDayPnl;
    final availCap = engine.availableTradingCapital > 0
        ? engine.availableTradingCapital
        : 48200.0;
    final totalCapBase = availCap + usedMargin;
    final totalPnlPct =
        totalCapBase > 0 ? (totalPnl / totalCapBase) * 100.0 : 0.0;
    final dayPnlPct =
        totalCapBase > 0 ? (openUnrealizedPnl / totalCapBase) * 100.0 : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Top Internal Tabs: Positions | Orders | History | Risk
          Row(
            children: ['Positions', 'Orders', 'History', 'Risk'].map((t) {
              final active = _activeTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _activeTab = t),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? QuantTheme.accent : QuantTheme.border,
                      ),
                    ),
                    child: Text(
                      t,
                      style: QuantTheme.heading(
                        size: 11,
                        color: active
                            ? QuantTheme.bgMain
                            : QuantTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),

          // 2. Dual Total P&L and Day P&L Summary Cards (Matches Reference Image)
          Row(
            children: [
              Expanded(
                child: QuantPanel(
                  backgroundColor: QuantTheme.bgSecondary,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total P&L', style: QuantTheme.label(size: 11)),
                      const SizedBox(height: 4),
                      Text(
                        '${totalPnl >= 0 ? "+" : ""}₹${totalPnl.toStringAsFixed(0)}',
                        style: QuantTheme.mono(
                          size: 18,
                          color: totalPnl >= 0
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                          weight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '(${totalPnlPct >= 0 ? "+" : ""}${totalPnlPct.toStringAsFixed(2)}%)',
                        style: QuantTheme.mono(
                          size: 11,
                          color: totalPnl >= 0
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
                  backgroundColor: QuantTheme.bgSecondary,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Day Unrealized P&L',
                          style: QuantTheme.label(size: 11)),
                      const SizedBox(height: 4),
                      Text(
                        '${openUnrealizedPnl >= 0 ? "+" : ""}₹${openUnrealizedPnl.toStringAsFixed(0)}',
                        style: QuantTheme.mono(
                          size: 18,
                          color: openUnrealizedPnl >= 0
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                          weight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '(${dayPnlPct >= 0 ? "+" : ""}${dayPnlPct.toStringAsFixed(2)}%)',
                        style: QuantTheme.mono(
                          size: 11,
                          color: openUnrealizedPnl >= 0
                              ? QuantTheme.positive
                              : QuantTheme.negative,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 3. Aggregated Portfolio Greeks Banner (M2 First & Second-Order)
          V2ControlDialogs.buildPortfolioGreeksCard(
            openPos,
            engine.spotPrices[widget.appState.selectedIndex] ?? 23050.0,
          ),

          if (_activeTab == 'Positions')
            _buildOpenPositionsView(openPos)
          else if (_activeTab == 'Orders')
            _buildOrdersView(allOrders)
          else if (_activeTab == 'History')
            _buildHistoryView(closedPos, allOrders)
          else
            _buildRiskAndExposureView(
              usedMargin: usedMargin,
              availCap: availCap,
              riskCfg: riskCfg,
              openCount: openPos.length,
            ),

          const SizedBox(height: 12),

          // 4. Risk Overview & Persisted Emergency Kill-Switch Footer
          QuantPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.shield_outlined,
                            color: QuantTheme.positive, size: 16),
                        const SizedBox(width: 6),
                        Text('Risk Overview & Margin Telemetry',
                            style: QuantTheme.heading(size: 12)),
                      ],
                    ),
                    QuantBadge(
                      text: riskCfg.killSwitchActive
                          ? 'KILL SWITCH ACTIVE'
                          : 'GUARDRAILS ACTIVE',
                      color: riskCfg.killSwitchActive
                          ? QuantTheme.negative
                          : QuantTheme.positive,
                    ),
                  ],
                ),
                const Divider(color: QuantTheme.border, height: 14),
                _kvRow('Used Margin / Outlay', '₹${usedMargin.toStringAsFixed(0)}'),
                _kvRow('Available Margin', '₹${availCap.toStringAsFixed(0)}',
                    color: QuantTheme.accent),
                _kvRow('Max Risk per Trade',
                    '${riskCfg.maxRiskPerTradePct.toStringAsFixed(1)}%'),
                _kvRow(
                  'Daily Loss Used / Max Limit',
                  '₹${widget.appState.todayRealizedLossInr.toStringAsFixed(0)} / ₹${riskCfg.maxDailyLossInr.toStringAsFixed(0)}',
                  color: widget.appState.todayRealizedLossInr >=
                          riskCfg.maxDailyLossInr
                      ? QuantTheme.negative
                      : QuantTheme.textPrimary,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: riskCfg.killSwitchActive
                          ? QuantTheme.positive
                          : QuantTheme.negative,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () {
                      final nextState = !riskCfg.killSwitchActive;
                      widget.appState.updateRiskConfig(
                        riskCfg.copyWith(killSwitchActive: nextState),
                      );
                      setState(() {});
                    },
                    icon: Icon(
                      riskCfg.killSwitchActive
                          ? Icons.lock_open
                          : Icons.report_gmailerrorred,
                      size: 18,
                    ),
                    label: Text(
                      riskCfg.killSwitchActive
                          ? 'Resume Trading (Deactivate Kill Switch)'
                          : 'Emergency Stop / Activate Kill Switch',
                      style: QuantTheme.heading(size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpenPositionsView(List openPos) {
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Open Positions (${openPos.length})',
                  style: QuantTheme.heading(size: 12)),
              Text('Tap position for execution details',
                  style: QuantTheme.label(size: 10, color: QuantTheme.accent)),
            ],
          ),
          const Divider(color: QuantTheme.border, height: 14),
          if (openPos.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  'No open positions. Execute a signal from Signals Center.',
                  style: QuantTheme.label(size: 11),
                ),
              ),
            )
          else
            ...openPos.map((raw) {
              final p = raw as PositionRecord;
              final ltp =
                  p.currentLtp > 0 ? p.currentLtp : p.avgEntryPrice;
              final pnl = (ltp - p.avgEntryPrice) * p.quantity;
              final pnlPct = p.avgEntryPrice > 0
                  ? ((ltp - p.avgEntryPrice) / p.avgEntryPrice) * 100.0
                  : 0.0;
              final isPos = pnl >= 0;

              return GestureDetector(
                onTap: () => _openPositionExecutionDetails(p),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: QuantTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: QuantTheme.border),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${p.indexName} ${p.strike} ${p.optionType}',
                            style: QuantTheme.heading(size: 13),
                          ),
                          Text(
                            '${isPos ? "+" : ""}₹${pnl.toStringAsFixed(1)} (${isPos ? "+" : ""}${pnlPct.toStringAsFixed(2)}%)',
                            style: QuantTheme.mono(
                              size: 13,
                              color: isPos
                                  ? QuantTheme.positive
                                  : QuantTheme.negative,
                              weight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Qty: ${p.quantity} | Avg: ₹${p.avgEntryPrice.toStringAsFixed(2)} | LTP: ₹${ltp.toStringAsFixed(2)}',
                            style: QuantTheme.mono(
                                size: 10, color: QuantTheme.textSecondary),
                          ),
                          Text(
                            'SL: ₹${p.stopLoss.toStringAsFixed(1)} | Tgt: ₹${p.target.toStringAsFixed(1)}',
                            style: QuantTheme.mono(
                                size: 10, color: QuantTheme.accent),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildOrdersView(List allOrders) {
    final filters = [
      'ALL',
      'FILLED',
      'PENDING',
      'ACCEPTED',
      'PARTIALLY FILLED',
      'REJECTED',
      'CANCELLED'
    ];
    final filtered = _orderStatusFilter == 'ALL'
        ? allOrders
        : allOrders
            .where((o) =>
                _normalizeStatusBadge((o as TradeOrder).status) ==
                _orderStatusFilter)
            .toList();

    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Order Book & Status Filter (${filtered.length})',
              style: QuantTheme.heading(size: 12)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: filters.map((f) {
                final active = _orderStatusFilter == f;
                return GestureDetector(
                  onTap: () => setState(() => _orderStatusFilter = f),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color:
                          active ? QuantTheme.bgElevated : QuantTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: active ? QuantTheme.accent : QuantTheme.border,
                      ),
                    ),
                    child: Text(
                      f,
                      style: QuantTheme.mono(
                        size: 9,
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
          const Divider(color: QuantTheme.border, height: 14),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text('No orders matching filter $_orderStatusFilter.',
                  style: QuantTheme.label(size: 11)),
            )
          else
            ...filtered.map((raw) {
              final o = raw as TradeOrder;
              final badgeText = _normalizeStatusBadge(o.status);
              final badgeCol = _statusColor(badgeText);
              final ts = DateFormat('dd MMM HH:mm:ss')
                  .format(DateTime.fromMillisecondsSinceEpoch(o.timestampMs));
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: QuantTheme.bgSecondary,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: QuantTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${o.side} ${o.indexName} ${o.strike} ${o.optionType} (${o.mode})',
                          style: QuantTheme.heading(size: 11),
                        ),
                        QuantBadge(text: badgeText, color: badgeCol),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Qty: ${o.quantity} @ ₹${o.price.toStringAsFixed(2)}',
                          style: QuantTheme.mono(size: 11),
                        ),
                        Text(ts,
                            style: QuantTheme.mono(
                                size: 9, color: QuantTheme.textSecondary)),
                      ],
                    ),
                    if (o.reason.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Note: ${o.reason}',
                        style: QuantTheme.label(size: 10),
                      ),
                    ],
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildHistoryView(List closedPos, List allOrders) {
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Closed Trade History (${closedPos.length})',
              style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          if (closedPos.isEmpty)
            Text('No closed positions yet in current session.',
                style: QuantTheme.label(size: 11))
          else
            ...closedPos.map((raw) {
              final p = raw as PositionRecord;
              final isWin = p.realizedPnl >= 0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${p.indexName} ${p.strike} ${p.optionType} (${p.quantity}q)',
                        style: QuantTheme.mono(size: 11)),
                    Text(
                      '${isWin ? "+" : ""}₹${p.realizedPnl.toStringAsFixed(2)}',
                      style: QuantTheme.mono(
                        size: 11,
                        color: isWin ? QuantTheme.positive : QuantTheme.negative,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildRiskAndExposureView({
    required double usedMargin,
    required double availCap,
    required RiskConfig riskCfg,
    required int openCount,
  }) {
    final exposurePct = (usedMargin + availCap) > 0
        ? (usedMargin / (usedMargin + availCap)) * 100.0
        : 0.0;
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Portfolio Exposure & Risk Guardrails',
              style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          _kvRow('Capital Exposure %',
              '${exposurePct.toStringAsFixed(1)}% (Max Allowed ${riskCfg.maxCapitalOutlayPct.toStringAsFixed(0)}%)'),
          _kvRow('Concurrent Positions',
              '$openCount / ${riskCfg.maxConcurrentPositions}'),
          _kvRow('Max Risk Per Trade %',
              '${riskCfg.maxRiskPerTradePct.toStringAsFixed(1)}%'),
          _kvRow('Max Daily Loss Cap',
              '₹${riskCfg.maxDailyLossInr.toStringAsFixed(0)}'),
          _kvRow('Reconciliation Status',
              DhanDataEngine.instance.lastAuditStatus,
              color: QuantTheme.positive),
        ],
      ),
    );
  }

  Widget _kvRow(String k, String v, {Color color = QuantTheme.textPrimary}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: QuantTheme.label(size: 11)),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: QuantTheme.mono(
                  size: 11, color: color, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
