import '../widgets/v2_control_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models.dart';
import '../../state/app_state.dart';

class PositionsScreen extends StatefulWidget {
  final AppState appState;

  const PositionsScreen({super.key, required this.appState});

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  bool _showOpen = true;

  @override
  Widget build(BuildContext context) {
    final openList = widget.appState.openPositions;
    final closedList = widget.appState.closedPositions;
    final orders = widget.appState.orders;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
          // Open | Closed Toggle + Kill Switch
          Row(
            children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _showOpen = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _showOpen
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Open',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _showOpen = false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: !_showOpen
                          ? const Color(0xFF1976D2)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Closed',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.appState.riskConfig.killSwitchActive
                      ? const Color(0xFFD50000)
                      : const Color(0xFF263238),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => widget.appState.toggleKillSwitch(),
                icon: const Icon(Icons.power_settings_new, size: 16),
                label: Text(
                  widget.appState.riskConfig.killSwitchActive
                      ? 'KILL ON'
                      : 'Kill Switch',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          Text(
            _showOpen
                ? 'Open Positions (${openList.length}) — ${widget.appState.tradingMode == TradingMode.live ? "LIVE" : "PAPER"}'
                : 'Closed Positions (${closedList.length})',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),

          if (_showOpen && openList.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF101B33),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF1E325C)),
              ),
              child: const Text(
                'No open positions. Approve a 1m BUY CE / BUY PE signal from the Signals tab.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            )
          else
            ...(_showOpen ? openList : closedList).map((pos) {
              final pnl = _showOpen ? pos.unrealizedPnl : pos.realizedPnl;
              final isProfit = pnl >= 0;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF101B33),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF1E325C)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
                        Text(
                          pos.indexName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        if (_showOpen)
                          TextButton(
                            style: TextButton.styleFrom(
                              backgroundColor:
                                  const Color(0xFFD50000).withOpacity(0.2),
                            ),
                            onPressed: () =>
                                widget.appState.closePosition(pos),
                            child: const Text(
                              'Exit Position',
                              style: TextStyle(
                                color: Color(0xFFFF5252),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00C853).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'BUY',
                            style: TextStyle(
                              color: Color(0xFF00E676),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${pos.optionType} ${pos.strike}  |  Qty ${pos.quantity}  |  Avg ${pos.avgEntryPrice.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
                        Text(
                          'LTP ₹${pos.currentLtp.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          'P&L ${isProfit ? "+" : ""}₹${pnl.toStringAsFixed(2)} (${pos.pnlPct.toStringAsFixed(1)}%)',
                          style: TextStyle(
                            color: isProfit
                                ? const Color(0xFF00E676)
                                : const Color(0xFFFF5252),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),

          const SizedBox(height: 16),
          const Text(
            'Recent Orders',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: orders.isEmpty
                ? const Text(
                    'No orders placed yet in this session.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  )
                : Column(
                    children: orders.take(10).map((o) {
                      final dt =
                          DateTime.fromMillisecondsSinceEpoch(o.timestampMs);
                      final tStr = DateFormat('HH:mm:ss').format(dt);
                      final isFilled = o.status == 'Filled';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [V2ControlDialogs.buildPortfolioGreeksCard(widget.appState.openPositions, 23050.0), 
                                Text(
                                  '${o.side} ${o.optionType} ${o.strike} (${o.mode})',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  tStr,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              'Qty ${o.quantity} @ ₹${o.price.toStringAsFixed(1)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              o.status,
                              style: TextStyle(
                                color: isFilled
                                    ? const Color(0xFF00E676)
                                    : const Color(0xFFFF5252),
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}
