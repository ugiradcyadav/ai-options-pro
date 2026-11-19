import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../engine/exit_manager.dart';
import '../../engine/ledger_reconciler.dart';
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
  late String _activeTab;
  LedgerAuditReport? _auditReport;
  bool _auditing = false;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
  }

  Map<String, double> _buildLiveLtpMap() {
    final engine = DhanDataEngine.instance;
    final map = <String, double>{};
    for (final idx in UnderlyingIndex.values) {
      for (final r in (engine.optionChainRows[idx] ?? const [])) {
        if (r.ceSecurityId.isNotEmpty && r.ceLtp > 0) {
          map[r.ceSecurityId] = r.ceLtp;
        }
        if (r.peSecurityId.isNotEmpty && r.peLtp > 0) {
          map[r.peSecurityId] = r.peLtp;
        }
      }
    }
    return map;
  }

  Future<void> _runLedgerAudit() async {
    setState(() => _auditing = true);
    final engine = DhanDataEngine.instance;
    final rep = await LedgerReconciler.reconcileFromDb(
      startingCapitalInr: engine.availableTradingCapital ?? 0.0,
      liveLtpBySecurityId: _buildLiveLtpMap(),
      isFeedLive: engine.dataHealth == DataHealthStatus.live,
    );
    if (!mounted) return;
    setState(() {
      _auditReport = rep;
      _auditing = false;
    });
  }

  Color _statusColor(OrderLifecycleState st) {
    if (st == OrderLifecycleState.filled) return QuantTheme.positive;
    if (st == OrderLifecycleState.partial) return QuantTheme.accent;
    if (st == OrderLifecycleState.acked || st == OrderLifecycleState.sent) {
      return QuantTheme.warning;
    }
    return QuantTheme.negative;
  }

  void _openPositionExecutionDetails(PositionRecord pos, double? liveLtp) {
    final hasLiveQuote = liveLtp != null && liveLtp > 0;
    final grossPnl =
        hasLiveQuote ? (liveLtp - pos.avgEntryPrice) * pos.quantity : null;
    final costs = hasLiveQuote
        ? RiskEngine.computeRoundTripCostsAndSlippage(
            entryPremium: pos.avgEntryPrice,
            exitPremium: liveLtp,
            quantity: pos.quantity,
          )
        : null;
    final netPnl = (grossPnl != null && costs != null)
        ? (grossPnl - costs.totalFrictionInr)
        : null;

    showModalBottomSheet(
      context: context,
      backgroundColor: QuantTheme.bgPanel,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${pos.indexName} ${pos.strike} ${pos.optionType} (${pos.mode})',
                style: QuantTheme.heading(size: 14)),
            const Divider(color: QuantTheme.border, height: 14),
            _kvRow('Security ID', pos.securityId),
            _kvRow('Qty & Avg Entry',
                '${pos.quantity} @ ₹${pos.avgEntryPrice.toStringAsFixed(2)}'),
            _kvRow(
                'Live LTP',
                hasLiveQuote
                    ? '₹${liveLtp.toStringAsFixed(2)}'
                    : 'N/A (Feed not LIVE)'),
            _kvRow('Stored SL / Target',
                '₹${pos.stopLossPrice.toStringAsFixed(2)}  /  ₹${pos.targetPrice.toStringAsFixed(2)}'),
            _kvRow(
                'Est. Friction (0.15% STT)',
                costs != null
                    ? '₹${costs.totalFrictionInr.toStringAsFixed(2)}'
                    : 'N/A'),
            _kvRow(
              'Net Realizable P&L',
              netPnl != null
                  ? '${netPnl >= 0 ? "+" : ""}₹${netPnl.toStringAsFixed(2)}'
                  : 'N/A (Unmeasured)',
              color: netPnl == null
                  ? QuantTheme.warning
                  : (netPnl >= 0
                      ? QuantTheme.positive
                      : QuantTheme.negative),
            ),
            const SizedBox(height: 12),
            if (pos.isOpen)
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: QuantTheme.negative),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await widget.appState.closePosition(pos.positionId);
                    if (mounted) setState(() {});
                  },
                  child: const Text('Square-Off Position Now'),
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
    final isLive = engine.dataHealth == DataHealthStatus.live;
    final liveLtpMap = _buildLiveLtpMap();
    final openPos =
        widget.appState.openPositions.where((p) => p.isOpen).toList();
    final closedPos =
        widget.appState.openPositions.where((p) => !p.isOpen).toList();
    final allOrders = widget.appState.orders;
    final riskCfg = widget.appState.riskConfig;
    final availCap = engine.availableTradingCapital;
    final liveSpot = engine.spotPrices[widget.appState.selectedIndex];

    double usedMargin = 0.0;
    double? openUnrealizedPnl = 0.0;
    for (final p in openPos) {
      usedMargin += p.avgEntryPrice * p.quantity;
      final qLtp = liveLtpMap[p.securityId];
      if (!isLive || qLtp == null || qLtp <= 0) {
        // Keep unmeasured P&L strictly null (N/A) instead of falling back to 0
        openUnrealizedPnl = null;
      } else if (openUnrealizedPnl != null) {
        openUnrealizedPnl += (qLtp - p.avgEntryPrice) * p.quantity;
      }
    }

    final todayRealized = widget.appState.todayNetRealizedPnlIst;
    final double? totalPnl =
        openUnrealizedPnl != null ? (openUnrealizedPnl + todayRealized) : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ExitManager.instance.persistentAlerts.isNotEmpty)
            QuantPanel(
              margin: const EdgeInsets.only(bottom: 10),
              borderColor: QuantTheme.negative,
              child: Text(
                ExitManager.instance.persistentAlerts.first,
                style: QuantTheme.mono(size: 11, color: QuantTheme.negative),
              ),
            ),

          Row(
            children: ['Positions', 'Orders', 'History', 'Risk'].map((t) {
              final active = _activeTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _activeTab = t);
                    if (t == 'Risk' && _auditReport == null) {
                      _runLedgerAudit();
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      t,
                      style: QuantTheme.heading(
                        size: 11,
                        color: active ? QuantTheme.bgMain : QuantTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),

          Row(
            children: [
              Expanded(
                child: QuantPanel(
                  backgroundColor: QuantTheme.bgSecondary,
                  child: QuantMetricCell(
                    label: 'TODAY NET P&L (IST)',
                    value: totalPnl != null
                        ? '${totalPnl >= 0 ? "+" : ""}₹${totalPnl.toStringAsFixed(0)}'
                        : 'N/A (Unmeasured)',
                    valueColor: totalPnl == null
                        ? QuantTheme.warning
                        : (totalPnl >= 0
                            ? QuantTheme.positive
                            : QuantTheme.negative),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: QuantPanel(
                  backgroundColor: QuantTheme.bgSecondary,
                  child: QuantMetricCell(
                    label: 'AVAILABLE CAPITAL',
                    value: availCap != null
                        ? '₹${availCap.toStringAsFixed(0)}'
                        : 'NO DATA',
                    valueColor: availCap != null
                        ? QuantTheme.accent
                        : QuantTheme.negative,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          V2ControlDialogs.buildPortfolioGreeksCard(openPos, liveSpot),

          if (_activeTab == 'Positions')
            _buildOpenPositionsView(openPos, liveLtpMap, isLive)
          else if (_activeTab == 'Orders')
            _buildOrdersView(allOrders)
          else if (_activeTab == 'History')
            _buildHistoryView(closedPos)
          else
            _buildRiskView(usedMargin, availCap, riskCfg, openPos.length),

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: riskCfg.killSwitchActive
                    ? QuantTheme.positive
                    : QuantTheme.negative,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                if (riskCfg.killSwitchActive) {
                  widget.appState.updateRiskConfig(
                      riskCfg.copyWith(killSwitchActive: false));
                } else {
                  await widget.appState.activateKillSwitch(flattenAll: true);
                }
                if (mounted) setState(() {});
              },
              icon: Icon(
                  riskCfg.killSwitchActive ? Icons.lock_open : Icons.gpp_bad,
                  size: 18),
              label: Text(
                riskCfg.killSwitchActive
                    ? 'Resume Trading (Deactivate Kill Switch)'
                    : 'Emergency Kill Switch (Block & Flatten All)',
                style: QuantTheme.heading(size: 12, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpenPositionsView(
    List openPos,
    Map<String, double> liveLtpMap,
    bool isLive,
  ) {
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Open Positions (${openPos.length})',
              style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          if (openPos.isEmpty)
            Text('No open positions.', style: QuantTheme.label(size: 11))
          else
            ...openPos.map((raw) {
              final p = raw as PositionRecord;
              final liveLtp = isLive ? liveLtpMap[p.securityId] : null;
              final double? pnl = (liveLtp != null && liveLtp > 0)
                  ? (liveLtp - p.avgEntryPrice) * p.quantity
                  : null;
              return GestureDetector(
                onTap: () => _openPositionExecutionDetails(p, liveLtp),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: QuantTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: QuantTheme.border),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${p.indexName} ${p.strike} ${p.optionType}${p.legacyUnverified ? " [LEGACY]" : ""}',
                            style: QuantTheme.heading(size: 12),
                          ),
                          Text(
                            'Qty ${p.quantity} | Avg ₹${p.avgEntryPrice.toStringAsFixed(2)} | SL ₹${p.stopLossPrice.toStringAsFixed(1)} | Tgt ₹${p.targetPrice.toStringAsFixed(1)}',
                            style: QuantTheme.mono(
                                size: 10, color: QuantTheme.textSecondary),
                          ),
                        ],
                      ),
                      Text(
                        pnl != null
                            ? '${pnl >= 0 ? "+" : ""}₹${pnl.toStringAsFixed(1)}'
                            : 'N/A',
                        style: QuantTheme.mono(
                          size: 12,
                          color: pnl == null
                              ? QuantTheme.warning
                              : (pnl >= 0
                                  ? QuantTheme.positive
                                  : QuantTheme.negative),
                        ),
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
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Orders (${allOrders.length})',
              style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          if (allOrders.isEmpty)
            Text('No orders recorded.', style: QuantTheme.label(size: 11))
          else
            ...allOrders.take(20).map((raw) {
              final o = raw as TradeOrder;
              final st = o.lifecycleState;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '${o.side} ${o.indexName} ${o.strike} ${o.optionType} (${o.filledQty}/${o.quantity} @ ₹${o.price.toStringAsFixed(2)})',
                        style: QuantTheme.mono(size: 10),
                      ),
                    ),
                    QuantBadge(text: st.label, color: _statusColor(st)),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildHistoryView(List closedPos) {
    return QuantPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Closed Positions (${closedPos.length})',
              style: QuantTheme.heading(size: 12)),
          const Divider(color: QuantTheme.border, height: 14),
          if (closedPos.isEmpty)
            Text('No closed trades.', style: QuantTheme.label(size: 11))
          else
            ...closedPos.map((raw) {
              final p = raw as PositionRecord;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${p.indexName} ${p.strike} ${p.optionType}${p.legacyUnverified ? " [LEGACY]" : ""}',
                      style: QuantTheme.mono(size: 11),
                    ),
                    Text(
                      '${p.realizedPnl >= 0 ? "+" : ""}₹${p.realizedPnl.toStringAsFixed(2)}',
                      style: QuantTheme.mono(
                        size: 11,
                        color: p.realizedPnl >= 0
                            ? QuantTheme.positive
                            : QuantTheme.negative,
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

  Widget _buildRiskView(
      double usedMargin, double? availCap, RiskConfig riskCfg, int openCount) {
    final rep = _auditReport;
    return Column(
      children: [
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Risk Guardrails & Feed State',
                  style: QuantTheme.heading(size: 12)),
              const Divider(color: QuantTheme.border, height: 14),
              _kvRow('Used Margin', '₹${usedMargin.toStringAsFixed(0)}'),
              _kvRow(
                  'Available Capital',
                  availCap != null
                      ? '₹${availCap.toStringAsFixed(0)}'
                      : 'NO DATA'),
              _kvRow('Open Positions',
                  '$openCount / ${riskCfg.maxConcurrentPositions}'),
              _kvRow('IST Daily Realized Loss / Cap',
                  '₹${widget.appState.todayRealizedLossInr.toStringAsFixed(0)} / ₹${riskCfg.maxDailyLossInr.toStringAsFixed(0)}'),
              _kvRow('Open Position Risk',
                  '₹${widget.appState.openPositionsRiskInr.toStringAsFixed(0)}'),
              _kvRow('Data Feed Health', DhanDataEngine.instance.dataHealth.label),
            ],
          ),
        ),
        const SizedBox(height: 10),
        QuantPanel(
          borderColor: rep == null
              ? QuantTheme.border
              : (rep.isReconciled ? QuantTheme.positive : QuantTheme.negative),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Independent Ledger Audit & Drawdown',
                      style: QuantTheme.heading(size: 12)),
                  if (rep != null)
                    QuantBadge(
                      text: rep.isReconciled ? 'RECONCILED' : 'MISMATCH',
                      color: rep.isReconciled
                          ? QuantTheme.positive
                          : QuantTheme.negative,
                    ),
                ],
              ),
              const Divider(color: QuantTheme.border, height: 14),
              if (rep == null)
                Text('Tap below to independently verify SQLite fills, cash & NAV.',
                    style: QuantTheme.label(size: 11))
              else ...[
                _kvRow('Orders (Filled / Partial)',
                    '${rep.filledOrdersCount} / ${rep.partialOrdersCount}'),
                _kvRow('Realized Net P&L',
                    '${rep.realizedNetPnlInr >= 0 ? "+" : ""}₹${rep.realizedNetPnlInr.toStringAsFixed(2)}'),
                _kvRow(
                    'Expected NAV',
                    rep.expectedNavInr != null
                        ? '₹${rep.expectedNavInr!.toStringAsFixed(0)}'
                        : 'N/A (Unmeasured open P&L)',
                    color: rep.expectedNavInr != null
                        ? QuantTheme.accent
                        : QuantTheme.warning),
                _kvRow(
                  'Ongoing Drawdown Depth',
                  rep.ongoingDrawdownInr > 0
                      ? '-₹${rep.ongoingDrawdownInr.toStringAsFixed(0)} (${rep.ongoingDrawdownPct.toStringAsFixed(1)}% • ${rep.ongoingEpisodeHours.toStringAsFixed(1)}h)'
                      : 'At Equity Peak (₹0 DD)',
                  color: rep.ongoingDrawdownInr > 0
                      ? QuantTheme.negative
                      : QuantTheme.positive,
                ),
                _kvRow('Historical Max Drawdown',
                    '₹${rep.maxDrawdownInr.toStringAsFixed(0)}'),
                ...rep.warnings.map((w) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('⚠ $w',
                          style: QuantTheme.mono(
                              size: 10, color: QuantTheme.warning)),
                    )),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 38,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: QuantTheme.accent,
                    side: const BorderSide(color: QuantTheme.accent),
                  ),
                  onPressed: _auditing ? null : _runLedgerAudit,
                  icon: const Icon(Icons.fact_check_outlined, size: 16),
                  label: Text(
                    _auditing
                        ? 'Auditing Ledger...'
                        : 'Run Independent Ledger Audit',
                    style:
                        QuantTheme.heading(size: 11, color: QuantTheme.accent),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kvRow(String k, String v, {Color color = QuantTheme.textPrimary}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: QuantTheme.label(size: 11)),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.right,
                style: QuantTheme.mono(size: 11, color: color)),
          ),
        ],
      ),
    );
  }
}
