import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../engine/mtf_strategy_engine.dart';
import '../../state/app_state.dart';

class HomeScreen extends StatelessWidget {
  final AppState appState;
  final void Function(String destination) onNavigateQuickAction;

  const HomeScreen({
    super.key,
    required this.appState,
    required this.onNavigateQuickAction,
  });

  @override
  Widget build(BuildContext context) {
    final engine = DhanDataEngine.instance;
    final chain = engine.optionChainRows[appState.selectedIndex] ?? [];
    final marketSense = MtfStrategyEngine.evaluateMarketSense(chain);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Header: AI Options Pro + Mode Switch + Settings Gear
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF102244),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF2979FF)),
                ),
                child: const Icon(
                  Icons.psychology,
                  color: Color(0xFF40C4FF),
                  size: 26,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Options Pro',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Research  |  Analyse  |  Trade',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ),
              // Paper vs Live Execution Mode Toggle Switch
              GestureDetector(
                onTap: () {
                  final next = appState.tradingMode == TradingMode.paper
                      ? TradingMode.live
                      : TradingMode.paper;
                  appState.switchTradingMode(next);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: appState.tradingMode == TradingMode.live
                        ? const Color(0xFFD50000).withOpacity(0.25)
                        : const Color(0xFF1565C0).withOpacity(0.25),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: appState.tradingMode == TradingMode.live
                          ? const Color(0xFFFF5252)
                          : const Color(0xFF42A5F5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        appState.tradingMode == TradingMode.live
                            ? Icons.flash_on
                            : Icons.science_outlined,
                        size: 13,
                        color: appState.tradingMode == TradingMode.live
                            ? const Color(0xFFFF5252)
                            : const Color(0xFF40C4FF),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        appState.tradingMode == TradingMode.live
                            ? 'LIVE EXEC'
                            : 'PAPER MODE',
                        style: TextStyle(
                          color: appState.tradingMode == TradingMode.live
                              ? const Color(0xFFFF5252)
                              : const Color(0xFF40C4FF),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: () => onNavigateQuickAction('settings'),
                icon: const Icon(Icons.settings_outlined, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Dhan Connected Status Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: engine.isConnected
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFFAB00),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      engine.isConnected
                          ? 'Dhan Connected'
                          : engine.connectionStatusText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  engine.isConnected ? 'Live Data (1m Entry)' : 'Tap Settings -> API',
                  style: TextStyle(
                    color: engine.isConnected
                        ? const Color(0xFF00E676)
                        : const Color(0xFFFFAB00),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 3 Live Index Cards: NIFTY 50, BANK NIFTY, FINNIFTY
          Row(
            children: UnderlyingIndex.values.map((idx) {
              final spot = engine.spotPrices[idx] ?? 0.0;
              final chgPct = engine.spotChangePct[idx] ?? 0.0;
              final isSelected = appState.selectedIndex == idx;
              final isPos = chgPct >= 0;

              return Expanded(
                child: GestureDetector(
                  onTap: () => appState.setSelectedUnderlying(idx),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF16284C)
                          : const Color(0xFF101B33),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF2979FF)
                            : const Color(0xFF1E325C),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          idx.label,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          spot > 0 ? spot.toStringAsFixed(2) : '--',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          spot > 0
                              ? '${isPos ? "+" : ""}${chgPct.toStringAsFixed(2)}%'
                              : 'Syncing',
                          style: TextStyle(
                            color: isPos
                                ? const Color(0xFF00E676)
                                : const Color(0xFFFF5252),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Market Sense Card
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.Query_stats, color: Color(0xFF40C4FF), size: 18),
                        SizedBox(width: 6),
                        Text(
                          'Market Sense',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: marketSense.badge == 'Bullish'
                            ? const Color(0xFF00C853).withOpacity(0.2)
                            : (marketSense.badge == 'Bearish'
                                ? const Color(0xFFD50000).withOpacity(0.2)
                                : Colors.white12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        marketSense.badge,
                        style: TextStyle(
                          color: marketSense.badge == 'Bullish'
                              ? const Color(0xFF00E676)
                              : (marketSense.badge == 'Bearish'
                                  ? const Color(0xFFFF5252)
                                  : Colors.white70),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  marketSense.headline,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Quick Actions Grid (6 Working Buttons)
          const Text(
            'Quick Actions',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.25,
            children: [
              _quickActionBtn(
                icon: Icons.bar_chart_rounded,
                label: 'OI Analysis',
                onTap: () => onNavigateQuickAction('oi_analysis'),
              ),
              _quickActionBtn(
                icon: Icons.hub_outlined,
                label: 'Option Chain',
                onTap: () => onNavigateQuickAction('option_chain'),
              ),
              _quickActionBtn(
                icon: Icons.insights_rounded,
                label: 'Backtest',
                onTap: () => onNavigateQuickAction('backtest'),
              ),
              _quickActionBtn(
                icon: Icons.radar_rounded,
                label: 'Signals',
                onTap: () => onNavigateQuickAction('signals'),
              ),
              _quickActionBtn(
                icon: Icons.work_outline_rounded,
                label: 'Positions',
                onTap: () => onNavigateQuickAction('positions'),
              ),
              _quickActionBtn(
                icon: Icons.settings_suggest_outlined,
                label: 'Settings',
                onTap: () => onNavigateQuickAction('settings'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Bottom Watchlist Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Watchlist',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => onNavigateQuickAction('option_chain'),
                      child: const Text(
                        'View All',
                        style: TextStyle(
                          color: Color(0xFF40C4FF),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 18),
                ...UnderlyingIndex.values.map((idx) {
                  final spot = engine.spotPrices[idx] ?? 0.0;
                  final chg = engine.spotChangePct[idx] ?? 0.0;
                  final pos = chg >= 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: InkWell(
                      onTap: () {
                        appState.setSelectedUnderlying(idx);
                        onNavigateQuickAction('option_chain');
                      },
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            idx.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                spot > 0 ? spot.toStringAsFixed(2) : '--',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Text(
                                spot > 0
                                    ? '${pos ? "+" : ""}${chg.toStringAsFixed(2)}%'
                                    : '--',
                                style: TextStyle(
                                  color: pos
                                      ? const Color(0xFF00E676)
                                      : const Color(0xFFFF5252),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
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
          ),
        ],
      ),
    );
  }

  Widget _quickActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF101B33),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF203868)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: const Color(0xFF40C4FF), size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
