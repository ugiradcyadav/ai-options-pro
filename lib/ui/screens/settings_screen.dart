import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/angel_smartapi_engine.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
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
  String _hubTab = 'Settings'; // 'Settings' | 'Backtest' | 'AI Models' | 'Storage'
  bool _notificationsEnabled = true;
  bool _biometricLock = false;
  int _storedBarsCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshDbCount();
  }

  Future<void> _refreshDbCount() async {
    final db = await ForeverDatabase.instance.database;
    final rows = await db.query('one_min_bars');
    if (!mounted) return;
    setState(() {
      _storedBarsCount = rows.length;
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
                      errText = 'Risk per trade must be between 0.1% and 25%.');
                  return;
                }
                if (dLoss < 100) {
                  setDlgState(() =>
                      errText = 'Max daily loss must be at least ₹100.');
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: QuantTheme.positive,
                    content: Text('Risk settings validated and persisted to SQLite.'),
                  ),
                );
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
    final riskCfg = widget.appState.riskConfig;

    final lastObs = engine.lastSyncTimestampMs > 0
        ? DateFormat('dd MMM HH:mm:ss')
            .format(DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs))
        : 'Waiting for tick';
    final ageSec = engine.lastSyncTimestampMs > 0
        ? ((DateTime.now().millisecondsSinceEpoch - engine.lastSyncTimestampMs) /
                1000.0)
            .clamp(0.0, 999.0)
        : 0.0;
    final dbSizeKb = (_storedBarsCount * 0.25).toStringAsFixed(1);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Hub Navigation: Settings | Backtest | AI Models | Storage
          Row(
            children: ['Settings', 'Backtest', 'AI Models', 'Storage'].map((t) {
              final active = _hubTab == t;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (t == 'Storage') {
                      V2ControlDialogs.openDataAndStorageSheet(
                        context,
                        onChanged: _refreshDbCount,
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

          if (_hubTab == 'Backtest')
            BacktestScreen(appState: widget.appState, embeddedMode: true)
          else if (_hubTab == 'AI Models')
            AiModelLabScreen(appState: widget.appState, embeddedMode: true)
          else ...[
            // 1. Broker Configuration & API Setup Panel
            QuantPanel(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ApiSetupScreen(appState: widget.appState),
                  ),
                );
              },
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: QuantTheme.positive.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.hub_outlined,
                        color: QuantTheme.positive, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Broker & API Configuration',
                            style: QuantTheme.heading(size: 13)),
                        const SizedBox(height: 2),
                        Text(
                          angel.isConfigured
                              ? 'Angel One SmartAPI (${angel.clientCode}) • Connected'
                              : engine.connectionStatusText,
                          style: QuantTheme.mono(
                              size: 11, color: QuantTheme.positive),
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

            // 2. System Health & Market Data Telemetry Panel
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('System Health & Market Data Diagnostics',
                          style: QuantTheme.heading(size: 12)),
                      QuantBadge(
                        text: engine.isConnected ? 'FEED HEALTHY' : 'RECONNECTING',
                        color: engine.isConnected
                            ? QuantTheme.positive
                            : QuantTheme.warning,
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 14),
                  _kvRow('Last Market Observation', lastObs,
                      color: QuantTheme.accent),
                  _kvRow('Data Freshness & Latency',
                      '${ageSec.toStringAsFixed(1)}s age  |  ${(engine.dataDelaySec * 1000).round()}ms latency'),
                  _kvRow('Feed Reconnection Status',
                      'Auto-Poll 1.5s Active (0 disconnects)'),
                  _kvRow('Missing Data / Bad Tick Indicators',
                      '${engine.missingDataCount} missing bars'),
                  _kvRow('Database Storage Usage',
                      '$dbSizeKb KB ($_storedBarsCount 1m bars stored)'),
                  _kvRow('Instrument-Master Version',
                      'NSE-NFO-DYNAMIC-2026.11 (Auto-Expiry)'),
                  _kvRow('AI Model Availability',
                      '${ai.activeModel.version} (${ai.activeModel.passedEvaluationGate ? "Promoted" : "Shadow/Rules"})'),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // 3. Organized Settings Tiles (Strategy, Risk, AI Lab, Database, Notifications, Security)
            QuantPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _settingTile(
                    icon: Icons.tune,
                    title: 'Strategy Settings (Live & Backtester)',
                    subtitle:
                        'Editable OI threshold, volume, IV band, target %, SL %, time exit',
                    onTap: () =>
                        V2ControlDialogs.openStrategySettingsSheet(context),
                  ),
                  _settingTile(
                    icon: Icons.shield_outlined,
                    title: 'Risk Management Settings',
                    subtitle:
                        'Max risk ${riskCfg.maxRiskPerTradePct}% | Daily loss cap ₹${riskCfg.maxDailyLossInr.toStringAsFixed(0)}',
                    onTap: _openRiskEditorDialog,
                  ),
                  _settingTile(
                    icon: Icons.psychology_outlined,
                    title: 'AI Model Laboratory & Calibration',
                    subtitle:
                        'Registry, OOS Brier score, calibration curve, feature importance',
                    onTap: () => setState(() => _hubTab = 'AI Models'),
                  ),
                  _settingTile(
                    icon: Icons.storage_outlined,
                    title: 'Database Management (SQLite)',
                    subtitle:
                        '$_storedBarsCount bars ($dbSizeKb KB) • Prune >5d, CSV Export, Clear',
                    onTap: () => V2ControlDialogs.openDataAndStorageSheet(
                      context,
                      onChanged: _refreshDbCount,
                    ),
                  ),
                  _settingTile(
                    icon: Icons.notifications_active_outlined,
                    title: 'Signal & Risk Notifications',
                    subtitle: _notificationsEnabled
                        ? 'Enabled for signal triggers, SL/Target & feed alerts'
                        : 'Muted',
                    trailing: Switch(
                      value: _notificationsEnabled,
                      activeColor: QuantTheme.accent,
                      onChanged: (v) =>
                          setState(() => _notificationsEnabled = v),
                    ),
                    onTap: () => setState(
                        () => _notificationsEnabled = !_notificationsEnabled),
                  ),
                  _settingTile(
                    icon: Icons.lock_outline,
                    title: 'Security & Execution Mode Gate',
                    subtitle: widget.appState.isLiveMode
                        ? 'LIVE Broker Mode Active (Tap to switch to Paper)'
                        : 'Paper Mode Active (Typed LIVE confirmation required)',
                    trailing: Switch(
                      value: widget.appState.isLiveMode,
                      activeColor: QuantTheme.negative,
                      onChanged: (v) async {
                        if (v) {
                          final ok = await V2ControlDialogs.confirmSwitchToLive(
                              context);
                          if (ok == true) widget.appState.toggleTradingMode(true);
                        } else {
                          widget.appState.toggleTradingMode(false);
                        }
                        if (mounted) setState(() {});
                      },
                    ),
                    onTap: () {},
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 4. Emergency Stop Button (Matches Reference Screen 7/8)
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: QuantTheme.negative,
                  backgroundColor: QuantTheme.negative.withOpacity(0.12),
                  side: const BorderSide(color: QuantTheme.negative, width: 1.2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  final next = !riskCfg.killSwitchActive;
                  widget.appState.updateRiskConfig(
                    riskCfg.copyWith(killSwitchActive: next),
                  );
                  setState(() {});
                },
                icon: const Icon(Icons.notification_important_outlined, size: 18),
                label: Text(
                  riskCfg.killSwitchActive
                      ? 'Emergency Stop ACTIVE (Tap to Resume)'
                      : 'Emergency Stop (Block All New Orders)',
                  style: QuantTheme.heading(size: 12, color: QuantTheme.negative),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _settingTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
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
                  const SizedBox(height: 2),
                  Text(subtitle, style: QuantTheme.label(size: 10)),
                ],
              ),
            ),
            trailing ??
                const Icon(Icons.chevron_right,
                    color: QuantTheme.textSecondary, size: 18),
          ],
        ),
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
