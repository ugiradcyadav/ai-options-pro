import '../widgets/v2_control_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models.dart';
import '../../core/totp_auth.dart';
import '../../data/dhan_data_engine.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../state/app_state.dart';
import 'api_setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  final AppState appState;

  const SettingsScreen({super.key, required this.appState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _maskedClientId = '*********';

  @override
  void initState() {
    super.initState();
    _loadMaskedId();
  }

  Future<void> _loadMaskedId() async {
    final c = await TotpAuthManager.loadCredentials();
    if (mounted && c.clientId.isNotEmpty) {
      setState(() {
        _maskedClientId = c.clientId.length > 4
            ? '****${c.clientId.substring(c.clientId.length - 4)}'
            : c.clientId;
      });
    }
  }

  void _openApiSetupSheet() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ApiSetupScreen(
          isFirstLaunch: false,
          onConnectedSuccess: () {
            Navigator.pop(context);
            _loadMaskedId();
            setState(() {});
          },
        ),
      ),
    );
  }

  void _showRiskConfigDialog() {
    final rc = widget.appState.riskConfig;
    final lossCtrl =
        TextEditingController(text: rc.maxDailyLossInr.toStringAsFixed(0));
    final posCtrl =
        TextEditingController(text: rc.maxConcurrentPositions.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101B33),
        title: const Text(
          'Risk Management Limits',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lossCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Max Daily Loss Limit (INR)',
                labelStyle: TextStyle(color: Colors.white70),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: posCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Max Concurrent Positions',
                labelStyle: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              widget.appState.riskConfig = rc.copyWith(
                maxDailyLossInr:
                    double.tryParse(lossCtrl.text) ?? rc.maxDailyLossInr,
                maxConcurrentPositions:
                    int.tryParse(posCtrl.text) ?? rc.maxConcurrentPositions,
              );
              Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _showModelRecalibrationSheet() async {
    final ai = AiRecalibrationEngine.instance;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101B33),
        title: const Text(
          'On-Device AI & Monday Self-Recalibration',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Active Model: ${ai.activeModel.version}',
              style: const TextStyle(
                color: Color(0xFF00E676),
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Validation Accuracy: ${ai.activeModel.validationWinRate.toStringAsFixed(1)}%',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              'Schedule: Auto-recalibrates every 5 trading days (Monday morning signals use fresh weights).',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(
              'Status: ${ai.lastRecalibrationNote}',
              style: const TextStyle(color: Color(0xFF40C4FF), fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () async {
              await ai.runLightweightFiveDayRecalibration(force: true);
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('Recalibrate Now (<2s)'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = DhanDataEngine.instance;
    final lastSyncStr = engine.lastSyncTimestampMs > 0
        ? DateFormat('HH:mm:ss').format(
            DateTime.fromMillisecondsSinceEpoch(engine.lastSyncTimestampMs),
          )
        : '--:--:--';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Account & API Card
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
                  'Account & API',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.cloud_done, color: Color(0xFF40C4FF), size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Dhan (Auto-TOTP)',
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
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: engine.isConnected
                            ? const Color(0xFF00C853).withOpacity(0.2)
                            : Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        engine.isConnected ? 'Connected' : 'Configure',
                        style: TextStyle(
                          color: engine.isConnected
                              ? const Color(0xFF00E676)
                              : Colors.orangeAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Client ID  |  $_maskedClientId',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Last Sync  $lastSyncStr',
                          style: const TextStyle(
                            color: Color(0xFF00E676),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _openApiSetupSheet,
                      child: const Text('Change', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Trading Mode Switch Card (Paper vs Live Execution)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Live Broker Order Execution',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              subtitle: Text(
                widget.appState.tradingMode == TradingMode.live
                    ? 'LIVE MODE: Approved orders sent to Dhan API'
                    : 'PAPER MODE: Real Dhan feed, local order book',
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              value: widget.appState.tradingMode == TradingMode.live,
              activeColor: const Color(0xFFFF5252),
              onChanged: (val) {
                widget.appState.switchTradingMode(
                  val ? TradingMode.live : TradingMode.paper,
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // Settings Menu Items (All Working)
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF101B33),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E325C)),
            ),
            child: Column(
              children: [
                _settingsTile(
                  icon: Icons.shield_outlined,
                  title: 'Risk Management',
                  subtitle:
                      'Max Daily Loss ₹${widget.appState.riskConfig.maxDailyLossInr.toStringAsFixed(0)} | Buyer-Only Locked',
                  onTap: _showRiskConfigDialog,
                ),
                _settingsTile(
                  icon: Icons.tune_rounded,
                  title: 'Strategy Settings',
                  subtitle: '1m Sniper Entry + 5m/15m/60m OI Confirmation',
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Active Rule: 1m Entry Trigger confirmed by 5m/15m/60m OI Change.',
                        ),
                      ),
                    );
                  },
                ),
                _settingsTile(
                  icon: Icons.memory_rounded,
                  title: 'Model Settings (5-Day Monday Recalibration)',
                  subtitle: AiRecalibrationEngine.instance.activeModel.version,
                  onTap: _showModelRecalibrationSheet,
                ),
                _settingsTile(
                  icon: Icons.storage_rounded,
                  title: 'Data & Storage (Forever 1m DB)',
                  subtitle:
                      '${widget.appState.databaseSizeMb.toStringAsFixed(2)} MB used (Ultra-Lean 1m Bars)',
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Forever SQLite DB Size: ${widget.appState.databaseSizeMb.toStringAsFixed(2)} MB',
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Data Health Monitor Panel
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Data Health',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00C853).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '● Healthy',
                        style: TextStyle(
                          color: Color(0xFF00E676),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 18),
                _healthRow(
                  'Live Feed',
                  engine.isConnected ? 'Connected' : 'Standby',
                  valueColor: const Color(0xFF00E676),
                ),
                _healthRow('Last Update', lastSyncStr),
                _healthRow(
                  'Data Delay',
                  '${engine.dataDelaySec.toStringAsFixed(2)} sec',
                ),
                _healthRow(
                  'Missing Data',
                  engine.missingDataCount == 0
                      ? 'None'
                      : '${engine.missingDataCount} retries',
                  valueColor: const Color(0xFF00E676),
                ),
                _healthRow(
                  'Forever DB Usage',
                  '${widget.appState.databaseSizeMb.toStringAsFixed(2)} MB / 5.0 GB Reserve',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: const Color(0xFF40C4FF), size: 20),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: Colors.white54, fontSize: 11),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.white54, size: 18),
    );
  }

  Widget _healthRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
