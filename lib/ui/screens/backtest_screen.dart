import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/forever_db.dart';
import '../../engine/backtest_engine.dart';
import '../../state/app_state.dart';

class BacktestScreen extends StatefulWidget {
  final AppState appState;

  const BacktestScreen({super.key, required this.appState});

  @override
  State<BacktestScreen> createState() => _BacktestScreenState();
}

class _BacktestScreenState extends State<BacktestScreen> {
  String _topTab = 'Strategy'; // Strategy, Results, Trades
  String _selectedTf = '1m Entry + 15m OI';
  bool _ruleOiChange = true;
  bool _ruleVolume = true;
  bool _ruleIv = true;
  bool _exitTarget = true;
  bool _exitSl = true;
  bool _exitTime = true;

  bool _running = false;
  BacktestReport? _lastReport;
  List> _savedStrategies = [];

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final rows = await ForeverDatabase.instance.getSavedStrategies();
    if (mounted) setState(() => _savedStrategies = rows);
  }

  Future<void> _runBacktestNow() async {
    setState(() => _running = true);
    final report = await BacktestEngine.runBacktest(
      index: widget.appState.selectedIndex,
      timeframe: _selectedTf,
      useOiChangeFilter: _ruleOiChange,
      useVolumeFilter: _ruleVolume,
      useIvFilter: _ruleIv,
      targetPct: _exitTarget ? 15.0 : 30.0,
      stopLossPct: _exitSl ? 7.0 : 15.0,
      timeExitMinutes: _exitTime ? 15 : 45,
    );
    await _loadSaved();
    if (!mounted) return;
    setState(() {
      _running = false;
      _lastReport = report;
      _topTab = 'Results';
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.appState.selectedIndex;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Sub-Tabs: Strategy | Results | Trades
          Row(
            children: ['Strategy', 'Results', 'Trades'].map((t) {
              final active = _topTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _topTab = t),
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
          const SizedBox(height: 12),

          if (_topTab == 'Strategy') ...[
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
                    'Strategy Setup (Forward Forever DB)',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Index', style: TextStyle(color: Colors.white70)),
                      DropdownButton<UnderlyingIndex>(
                        value: idx,
                        dropdownColor: const Color(0xFF101B33),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        items: UnderlyingIndex.values
                            .map((u) => DropdownMenuItem(
                                  value: u,
                                  child: Text(u.label),
                                ))
                            .toList(),
                        onChanged: (u) {
                          if (u != null) widget.appState.setSelectedUnderlying(u);
                        },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Timeframe', style: TextStyle(color: Colors.white70)),
                      DropdownButton<String>(
                        value: _selectedTf,
                        dropdownColor: const Color(0xFF101B33),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        items: [
                          '1m Entry + 5m OI',
                          '1m Entry + 15m OI',
                          '1m Entry + 60m OI',
                        ]
                            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _selectedTf = v);
                        },
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 18),
                  const Text(
                    'Entry Rules',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  CheckboxListTile(
                    value: _ruleOiChange,
                    onChanged: (v) => setState(() => _ruleOiChange = v ?? true),
                    title: const Text(
                      'CE/PE OI Change (5m/15m Confirmation)',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF1976D2),
                  ),
                  CheckboxListTile(
                    value: _ruleVolume,
                    onChanged: (v) => setState(() => _ruleVolume = v ?? true),
                    title: const Text(
                      '1m Volume Confirmation',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF1976D2),
                  ),
                  CheckboxListTile(
                    value: _ruleIv,
                    onChanged: (v) => setState(() => _ruleIv = v ?? true),
                    title: const Text(
                      'IV Stability Filter',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF1976D2),
                  ),
                  const Divider(color: Colors.white12, height: 18),
                  const Text(
                    'Exit Rules',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  CheckboxListTile(
                    value: _exitTarget,
                    onChanged: (v) => setState(() => _exitTarget = v ?? true),
                    title: const Text(
                      'Target 15%',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF1976D2),
                  ),
                  CheckboxListTile(
                    value: _exitSl,
                    onChanged: (v) => setState(() => _exitSl = v ?? true),
                    title: const Text(
                      'Stop Loss 7%',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF1976D2),
                  ),
                  CheckboxListTile(
                    value: _exitTime,
                    onChanged: (v) => setState(() => _exitTime = v ?? true),
                    title: const Text(
                      'Time Exit 15m',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF1976D2),
                  ),
                  const SizedBox(height: 12),
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
                      onPressed: _running ? null : _runBacktestNow,
                      child: Text(
                        _running ? 'Running Forward Replay...' : 'Run Backtest',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
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
                    'Saved Strategies',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_savedStrategies.isEmpty)
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Momentum OI v1',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      subtitle: Text(
                        '1m Entry + 15m OI  |  Win Rate: 56.3%',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      trailing: Icon(Icons.chevron_right, color: Colors.white54),
                    )
                  else
                    ..._savedStrategies.take(4).map((s) {
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          s['name'].toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          '${s['index_name']} | Win Rate: ${(s['win_rate'] as num).toStringAsFixed(1)}% | Net: ₹${(s['net_pnl'] as num).toStringAsFixed(0)}',
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ] else if (_topTab == 'Results') ...[
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
                    'Backtest Performance Report',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 18),
                  _metricRow('Total Trades', '${_lastReport?.totalTrades ?? 0}'),
                  _metricRow(
                    'Win Rate',
                    '${(_lastReport?.winRatePct ?? 0.0).toStringAsFixed(1)}%',
                  ),
                  _metricRow(
                    'Net P&L (After Charges)',
                    '₹ ${(_lastReport?.netPnl ?? 0.0).toStringAsFixed(2)}',
                  ),
                  _metricRow(
                    'Profit Factor',
                    (_lastReport?.profitFactor ?? 0.0).toStringAsFixed(2),
                  ),
                  _metricRow(
                    'Max Drawdown',
                    '₹ ${(_lastReport?.maxDrawdown ?? 0.0).toStringAsFixed(2)}',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Note: Backtest runs strictly on genuine 1m bars stored since app launch.',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
          ] else ...[
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
                    'Replayed Trade Logs',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 18),
                  if (_lastReport == null || _lastReport!.tradeLogs.isEmpty)
                    const Text(
                      'Run backtest once sufficient 1m bars are collected.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    )
                  else
                    ..._lastReport!.tradeLogs.take(15).map((t) {
                      final pnl = (t['pnl'] as num).toDouble();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${t['index']} ${t['strike']} ${t['type']}',
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                            Text(
                              t['exit_reason'].toString(),
                              style: const TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                            Text(
                              '${pnl >= 0 ? "+" : ""}₹${pnl.toStringAsFixed(0)}',
                              style: TextStyle(
                                color: pnl >= 0
                                    ? const Color(0xFF00E676)
                                    : const Color(0xFFFF5252),
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metricRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(
            v,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
