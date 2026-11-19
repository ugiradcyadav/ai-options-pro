import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/execution_engine.dart';
import '../../engine/risk_engine.dart';
import '../../engine/strategy_settings.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';

class SignalDetailsScreen extends StatefulWidget {
  final AppState appState;
  final AiSignal signal;

  const SignalDetailsScreen({
    super.key,
    required this.appState,
    required this.signal,
  });

  @override
  State<SignalDetailsScreen> createState() => _SignalDetailsScreenState();
}

class _SignalDetailsScreenState extends State<SignalDetailsScreen> {
  bool _executing = false;
  int _recordedBarCount = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: widget.signal.index.label,
      limit: 60,
    );
    if (!mounted) return;
    setState(() => _recordedBarCount = bars.length);
  }

  Future<void> _handlePaperExecution() async {
    setState(() => _executing = true);
    final res = await widget.appState.executeActiveSignal();
    if (!mounted) return;
    setState(() => _executing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor:
            (res?.success == true) ? QuantTheme.positive : QuantTheme.negative,
        content: Text(res?.message ?? 'Order blocked by strategy or risk gate.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sig = widget.signal;
    final engine = DhanDataEngine.instance;
    final spot = engine.spotPrices[sig.index] ?? 0.0;
    final rows = engine.optionChainRows[sig.index] ?? const [];
    final ai = AiRecalibrationEngine.instance;
    final settings = StrategySettingsEngine.instance.current;

    StrikeRowSnapshot? strikeRow;
    for (final r in rows) {
      if (r.strike == sig.strike) {
        strikeRow = r;
        break;
      }
    }

    final isCall = sig.action == SignalAction.buyCe;
    final isTradable = sig.strategyPassed &&
        sig.riskWithinLimits &&
        sig.action != SignalAction.noTrade &&
        sig.quantity > 0;
    final optLabel =
        isCall ? 'CE' : (sig.action == SignalAction.buyPe ? 'PE' : 'NONE');

    final entry = sig.entryPremium;
    final sl = sig.stopLossPremium;
    final tgt = sig.targetPremium;
    final expGainPts = isTradable ? (tgt - entry) : 0.0;
    final maxRiskPts = isTradable ? (entry - sl).abs() : 0.0;
    final rrRatio = maxRiskPts > 0 ? (expGainPts / maxRiskPts) : 0.0;

    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: entry,
      exitPremium: tgt,
      quantity: sig.quantity,
    );

    return Scaffold(
      backgroundColor: QuantTheme.bgMain,
      appBar: AppBar(
        title: const Text('Signal Details & Execution Gate'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(
              child: QuantBadge(text: 'PAPER MODE', color: QuantTheme.positive),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            QuantPanel(
              borderColor:
                  isTradable ? QuantTheme.positive : QuantTheme.border,
              child: Row(
                children: [
                  Icon(
                    isTradable ? Icons.check_circle : Icons.pause_circle_filled,
                    color: isTradable ? QuantTheme.positive : QuantTheme.warning,
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isTradable
                              ? '${sig.action.label} — APPROVED'
                              : 'NO TRADE — BLOCKED / STANDBY',
                          style: QuantTheme.heading(
                            size: 14,
                            color: isTradable
                                ? QuantTheme.positive
                                : QuantTheme.warning,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Model: ${sig.modelVersion} | Real Bars Recorded: $_recordedBarCount',
                          style: QuantTheme.mono(
                              size: 10, color: QuantTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CONTRACT & EXECUTION LEVELS',
                      style: QuantTheme.heading(size: 12)),
                  const Divider(color: QuantTheme.border, height: 14),
                  _kvRow('Underlying Spot',
                      spot > 0 ? '${sig.index.label} (${spot.toStringAsFixed(2)})' : 'NO DATA'),
                  _kvRow('Contract',
                      sig.tradingSymbol.isNotEmpty ? sig.tradingSymbol : '${sig.strike} $optLabel'),
                  _kvRow('Security ID',
                      sig.securityId.isNotEmpty ? sig.securityId : 'UNRESOLVED'),
                  _kvRow('Expiry', sig.expiry.isNotEmpty ? sig.expiry : 'N/A'),
                  _kvRow('Entry Premium', '₹${entry.toStringAsFixed(2)}',
                      color: QuantTheme.accent),
                  _kvRow('Target / Stop-Loss',
                      '₹${tgt.toStringAsFixed(2)}  /  ₹${sl.toStringAsFixed(2)}'),
                  _kvRow('Reward / Risk Ratio', '${rrRatio.toStringAsFixed(2)}x'),
                  _kvRow('Quantity & Lot Size',
                      '${sig.quantity} qty (${sig.lotSize} per lot)'),
                  _kvRow('Est. Friction (0.15% STT)',
                      '₹${costs.totalFrictionInr.toStringAsFixed(2)}'),
                ],
              ),
            ),
            const SizedBox(height: 10),

            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DIAGNOSTICS & REAL OPTION GREEKS',
                      style: QuantTheme.heading(size: 12)),
                  const Divider(color: QuantTheme.border, height: 14),
                  ...sig.reasons.map((r) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.5),
                        child: Text('• $r',
                            style: QuantTheme.label(
                                size: 11, color: QuantTheme.textPrimary)),
                      )),
                  if (strikeRow != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Greeks ($optLabel ${strikeRow.strike}): '
                      'IV ${(isCall ? strikeRow.ceIv : strikeRow.peIv)?.toStringAsFixed(2) ?? "N/A"}% | '
                      'Δ ${(isCall ? strikeRow.ceDelta : strikeRow.peDelta).toStringAsFixed(3)} | '
                      'Γ ${(isCall ? strikeRow.ceGamma : strikeRow.peGamma).toStringAsFixed(5)} | '
                      'Θ ${(isCall ? strikeRow.ceTheta : strikeRow.peTheta).toStringAsFixed(2)}/d | '
                      'ν ${(isCall ? strikeRow.ceVega : strikeRow.peVega).toStringAsFixed(2)}',
                      style: QuantTheme.mono(size: 11, color: QuantTheme.accent),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    'Invalidation: SL ₹${sl.toStringAsFixed(2)} | Time-Exit ${settings.timeExitMinutes}m | Forced 15:15 IST | HMM Chop ${(ai.probChopRegime * 100).toStringAsFixed(0)}%',
                    style: QuantTheme.label(size: 10, color: QuantTheme.warning),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: QuantTheme.accent,
                        foregroundColor: QuantTheme.bgMain,
                      ),
                      onPressed:
                          (_executing || !isTradable) ? null : _handlePaperExecution,
                      icon: const Icon(Icons.science_outlined, size: 17),
                      label: Text('Paper Trade (Real Quote)',
                          style: QuantTheme.heading(
                              size: 11, color: QuantTheme.bgMain)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: QuantTheme.textSecondary,
                        side: const BorderSide(color: QuantTheme.border),
                      ),
                      onPressed: ExecutionEngine.liveTradingUnlocked ? () {} : null,
                      icon: const Icon(Icons.lock_outline, size: 16),
                      label: Text('Live Locked (15d Gate)',
                          style: QuantTheme.label(size: 11)),
                    ),
                  ),
                ),
              ],
            ),
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
            child: Text(v,
                textAlign: TextAlign.right,
                style: QuantTheme.mono(size: 11, color: color)),
          ),
        ],
      ),
    );
  }
}
