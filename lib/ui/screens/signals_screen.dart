import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/mtf_strategy_engine.dart';
import '../../state/app_state.dart';

class SignalsScreen extends StatefulWidget {
  final AppState appState;

  const SignalsScreen({super.key, required this.appState});

  @override
  State<SignalsScreen> createState() => _SignalsScreenState();
}

class _SignalsScreenState extends State<SignalsScreen> {
  String _subTab = 'Live'; // Live, Backtest, History
  List> _historySignals = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final rows = await ForeverDatabase.instance.getRecentSignals(limit: 25);
    if (mounted) {
      setState(() => _historySignals = rows);
    }
  }

  Future<void> _showManualApprovalDialog(AiSignal sig) async {
    final isLive = widget.appState.tradingMode == TradingMode.live;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101B33),
        title: Text(
          isLive
              ? 'Confirm LIVE Dhan Order'
              : 'Confirm Paper Trade Order',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Action: ${sig.action.label} (${sig.index.label})',
              style: const TextStyle(
                color: Color(0xFF00E676),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Contract: Strike ${sig.strike} | Expiry ${sig.expiry}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text(
              'Quantity: ${sig.lotSize} (1 Lot) @ Rs. ${sig.entryPremium.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text(
              'Stop-Loss (1m): Rs. ${sig.stopLossPremium.toStringAsFixed(2)} | Target: Rs. ${sig.targetPremium.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const Divider(color: Colors.white24, height: 18),
            Text(
              'Estimated Outlay (incl. charges): Rs. ${sig.requiredCapital.toStringAsFixed(0)}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isLive
                  ? const Color(0xFFD50000)
                  : const Color(0xFF00C853),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              isLive ? 'Send Live Order' : 'Execute Paper Trade',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await widget.appState.approveAndExecuteSignal(sig);
      await _loadHistory();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? '${sig.action.label} executed in ${widget.appState.tradingMode == TradingMode.live ? "LIVE" : "PAPER"} mode!'
                : 'Order blocked by Risk/Broker verification.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;
    final engine = DhanDataEngine.instance;
    final chain = engine.optionChainRows[idx] ?? [];
    final expiry = engine.selectedExpiry[idx] ?? '2026-04-30';

    final signal = widget.appState.latestSignal ??
        MtfStrategyEngine.evaluateOneMinEntry(
          index: idx,
          expiry: expiry,
          chainRows: chain,
          recent1mBars: const [],
          availableCapital: engine.availableTradingCapital > 0
              ? engine.availableTradingCapital
              : 8420.0,
          riskConfig: widget.appState.riskConfig,
          openPositionsCount: widget.appState.openPositions.length,
          todayRealizedLossInr: widget.appState.todayRealizedLoss,
        );

    final isBuyCe = signal.action == SignalAction.buyCe;
    final isBuyPe = signal.action == SignalAction.buyPe;
    final badgeColor = isBuyCe
        ? const Color(0xFF00C853)
        : (isBuyPe ? const Color(0xFFD50000) : Colors.blueGrey);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Sub-Tabs: Live | Backtest | History
          Row(
            children: ['Live', 'Backtest', 'History'].map((t) {
              final active = _subTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _subTab = t),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      t,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),

          // Index Selector Row
          Row(
            children: UnderlyingIndex.values.map((u) {
              final active = idx == u;
              return Expanded(
                child: GestureDetector(
                  onTap: () => widget.appState.setSelectedUnderlying(u),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      u.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Current Signal Card (1m Entry + 5m/15m/60m OI Confirmation)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF203868)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Current Signal (1m Entry)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        signal.action.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Strike ${signal.strike > 0 ? signal.strike : 24300} (ATM)  |  Expiry ${signal.expiry}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),

                // Confidence Bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Confidence',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      '${signal.confidencePct.toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (signal.confidencePct / 100.0).clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF00E676),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                const Text(
                  'Reason (HTF OI Confirm + 1m Trigger)',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                ...signal.reasons.map(
                  (r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.circle,
                          size: 6,
                          color: Color(0xFF00E676),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            r,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Independent Risk Check Box
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0C1528),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF1E325C)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                signal.riskWithinLimits
                                    ? Icons.check_circle
                                    : Icons.error,
                                color: signal.riskWithinLimits
                                    ? const Color(0xFF00E676)
                                    : const Color(0xFFFF5252),
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Risk Check',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '+ ${signal.riskNote}',
                            style: TextStyle(
                              color: signal.riskWithinLimits
                                  ? const Color(0xFF00E676)
                                  : const Color(0xFFFF5252),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Available Capital',
                            style: TextStyle(color: Colors.white60, fontSize: 12),
                          ),
                          Text(
                            '₹ ${signal.availableCapital.toStringAsFixed(0)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Required Premium',
                            style: TextStyle(color: Colors.white60, fontSize: 12),
                          ),
                          Text(
                            '₹ ${signal.requiredCapital > 0 ? signal.requiredCapital.toStringAsFixed(0) : "2,860"}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // View Details / Manual Approval Button
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1976D2),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => _showManualApprovalDialog(signal),
                    child: Text(
                      signal.action == SignalAction.noTrade
                          ? 'View Details (No Trade Setup)'
                          : 'View Details & Approve ${signal.action.label}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Recent Signals List
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recent Signals',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Divider(color: Colors.white12, height: 18),
                if (_historySignals.isEmpty) ...[
                  _recentSignalRow('09:32', 'BUY CE', true),
                  _recentSignalRow('09:17', 'NO TRADE', false),
                ] else
                  ..._historySignals.take(6).map((s) {
                    final dt = DateTime.fromMillisecondsSinceEpoch(
                      (s['timestamp_ms'] as int?) ?? 0,
                    );
                    final timeStr = DateFormat('HH:mm').format(dt);
                    final act = (s['action'] ?? 'NO TRADE').toString();
                    return _recentSignalRow(timeStr, act, act != 'NO TRADE');
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentSignalRow(String time, String action, bool active) {
    final color = action == 'BUY CE'
        ? const Color(0xFF00E676)
        : (action == 'BUY PE' ? const Color(0xFFFF5252) : Colors.white54);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(time, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(
            action,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          Icon(
            active ? Icons.check : Icons.remove,
            color: active ? const Color(0xFF00E676) : Colors.white38,
            size: 16,
          ),
        ],
      ),
    );
  }
}
