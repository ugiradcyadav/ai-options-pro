import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/angel_smartapi_engine.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../data/scrip_master_engine.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/execution_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/v2_control_dialogs.dart';
import 'ai_model_lab_screen.dart';
import 'api_setup_screen.dart';
import 'backtest_screen.dart';

class SettingsScreen extends StatefulWidget {
  final AppState appState;

  const SettingsScreen({super.key, required this.appState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _hubTab = 'Settings';
  int _storedBarsCount = 0;
  int _dbSizeBytes = 0;

  @override
  void initState() {
    super.initState();
    _refreshDbStats();
  }

  Future<void> _refreshDbStats() async {
    final db = await ForeverDatabase.instance.database;
    final rows = await db.query('one_min_bars', columns: ['id']);
    final bytes = await ForeverDatabase.instance.getDatabaseFileSizeBytes();
    if (!mounted) return;
    setState(() {
      _storedBarsCount = rows.length;
      _dbSizeBytes = bytes;
    });
  }

  Future<void> _openRiskEditorDialog() async {
    final cur = widget.appState.riskConfig;
    final riskPctCtrl =
        TextEditingController(text: cur.maxRiskPerTradePct.toString());
    final dailyLossCtrl =
        TextEditingController(text: cur.maxDailyLossInr.toString());
    final maxPosCtrl =
        TextEditingController(text: cur.maxConcurrentPositions.toString());
    final outlayCtrl =
        TextEditingController(text: cur.maxCapitalOutlayPct.toString());
    String? errText;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: QuantTheme.bgPanel,
          title: Text('Risk Management Configuration',
              style: QuantTheme.heading(size: 14)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dlgField('Max Risk Per Trade (%)', riskPctCtrl),
                const SizedBox(height: 8),
                _dlgField('Max Daily Net Loss (INR)', dailyLossCtrl),
                const SizedBox(height: 8),
                _dlgField('Max Concurrent Positions', maxPosCtrl),
                const SizedBox(height: 8),
                _dlgField('Max Capital Outlay (%)', outlayCtrl),
                if (errText != null) ...[
                  const SizedBox(height: 8),
                  Text(errText!,
                      style: const TextStyle(
                          color: QuantTheme.negative, fontSize: 11)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: QuantTheme.positive,
                  foregroundColor: QuantTheme.bgMain),
              onPressed: () {
                final rPct = double.tryParse(riskPctCtrl.text.trim()) ?? -1;
                final dLoss = double.tryParse(dailyLossCtrl.text.trim()) ?? -1;
                final mPos = int.tryParse(maxPosCtrl.text.trim()) ?? -1;
                final cOut = double.tryParse(outlayCtrl.text.trim()) ?? -1;

                if (rPct <= 0 || rPct > 25.0) {
                  setDlgState(() =>
                      errText = 'Risk per trade must be 0.1% to 25%.');
                  return;
                }
                if (dLoss < 100) {
                  setDlgState(() =>
                      errText = 'Max daily loss must be >= ₹100.');
                  return;
                }
                if (mPos < 1 || mPos > 20) {
                  setDlgState(() =>
                      errText = 'Max concurrent positions must be 1 to 20.');
                  return;
                }
                if (cOut < 5.0 || cOut > 100.0) {
                  setDlgState(() =>
                      errText = 'Max capital outlay must be 5% to 100%.');
                  return;
                }

                widget.appState.updateRiskConfig(
                  cur.copyWith(
                    maxRiskPerTradePct: rPct,
                    maxDailyLossInr: dLoss,
                    maxConcurrentPositions: mPos,
                    maxCapitalOutlayPct: cOut,
                  ),
                );
                Navigator.of(ctx).pop();
              },
              child: const Text('Validate & Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = DhanDataEngine.instance;
    final angel = AngelSmartApiEngine.instance;
    final ai = AiRecalibrationEngine.instance;
    final master = ScripMasterEngine.instance;
    final riskCfg = widget.appState.riskConfig;
    final health = engine.dataHealth;

    final lastObs = engine.lastSyncTimestampMs > 0
        ? DateFormat('dd MMM HH:mm:ss').format(
            DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs))
        : 'NO DATA';
    final dbSizeKb = (_dbSizeBytes / 1024.0).toStringAsFixed(1);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: ['Settings', 'Backtest', 'AI Models', 'Storage'].map((t) {
              final active = _hubTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (t == 'Storage') {
                      V2ControlDialogs.openDataAndStorageSheet(
                        context,
                        onChanged: _refreshDbStats,
                      );
                    } else {
                      setState(() => _hubTab = t);
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

          if (_hubTab == 'Backtest')
            BacktestScreen(appState: widget.appState, embeddedMode: true)
          else if (_hubTab == 'AI Models')
            AiModelLabScreen(appState: widget.appState, embeddedMode: true)
          else ...[
            QuantPanel(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ApiSetupScreen(
                      onConnectedSuccess: () {
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                );
              },
              child: Row(
                children: [
                  const Icon(Icons.hub_outlined,
                      color: QuantTheme.accent, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Broker & API Setup (Encrypted Storage)',
                            style: QuantTheme.heading(size: 13)),
                        Text(
                          angel.isConfigured
                              ? 'Angel One (${angel.clientCode}) • ${health.label}'
                              : 'Not connected — Tap to configure broker API',
                          style: QuantTheme.mono(
                            size: 11,
                            color: health == DataHealthStatus.live
                                ? QuantTheme.positive
                                : QuantTheme.warning,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      color: QuantTheme.textSecondary),
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
                      Text('System Health & Diagnostics',
                          style: QuantTheme.heading(size: 12)),
                      QuantBadge(
                        text: health.label,
                        color: health == DataHealthStatus.live
                            ? QuantTheme.positive
                            : QuantTheme.negative,
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  _kvRow('Last Market Observation', lastObs),
                  _kvRow('Refresh Rate & Latency',
                      '750ms target | ${(engine.dataDelaySec * 1000).round()}ms'),
                  _kvRow('Missing Data Count', '${engine.missingDataCount}'),
                  _kvRow('Database Storage Usage',
                      '$dbSizeKb KB ($_storedBarsCount real bars)'),
                  _kvRow('Instrument Master', master.masterVersion),
                  _kvRow('AI Model Status', ai.activeModel.version),
                  _kvRow(
                    'LIVE Mode Gate',
                    ExecutionEngine.liveTradingUnlocked
                        ? 'UNLOCKED'
                        : 'LOCKED (15d real-data paper run required)',
                    color: QuantTheme.warning,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            QuantPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _tile(Icons.tune, 'Strategy Settings',
                      'OI lots, volume, IV band, target %, SL %, time exit', () {
                    V2ControlDialogs.openStrategySettingsSheet(context);
                  }),
                  _tile(
                      Icons.shield_outlined,
                      'Risk Management Settings',
                      'Max risk ${riskCfg.maxRiskPerTradePct}% | Daily loss cap ₹${riskCfg.maxDailyLossInr.toStringAsFixed(0)}',
                      _openRiskEditorDialog),
                  _tile(Icons.storage_outlined, 'Database Management (v3)',
                      '$dbSizeKb KB • Prune 5d+ or clear recorded bars', () {
                    V2ControlDialogs.openDataAndStorageSheet(context,
                        onChanged: _refreshDbStats);
                  }),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tile(
      IconData icon, String title, String subtitle, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: const BoxDecoration(
          border:
              Border(bottom: BorderSide(color: QuantTheme.border, width: 0.6)),
        ),
        child: Row(
          children: [
            Icon(icon, color: QuantTheme.accent, size: 19),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: QuantTheme.heading(size: 12)),
                  Text(subtitle, style: QuantTheme.label(size: 10)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: QuantTheme.textSecondary, size: 18),
          ],
        ),
      ),
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

  Widget _dlgField(String label, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: QuantTheme.mono(size: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: QuantTheme.label(size: 11),
        isDense: true,
        filled: true,
        fillColor: QuantTheme.bgSecondary,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
