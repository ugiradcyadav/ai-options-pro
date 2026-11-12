import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/dhan_data_engine.dart';
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/risk_engine.dart';
import '../../engine/strategy_settings.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';
import '../widgets/v2_control_dialogs.dart';

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
  List _comparableBars = [];
  bool _executing = false;

  @override
  void initState() {
    super.initState();
    _loadComparableHistory();
  }

  Future<void> _loadComparableHistory() async {
    final bars = await ForeverDatabase.instance.getRecentBars(
      indexName: widget.signal.index.label,
      limit: 60,
    );
    if (!mounted) return;
    setState(() {
      _comparableBars = bars;
    });
  }

  Future<void> _handlePaperExecution() async {
    setState(() => _executing = true);
    if (widget.appState.isLiveMode) {
      widget.appState.toggleTradingMode(false);
    }
    await widget.appState.executeActiveSignal();
    if (!mounted) return;
    setState(() => _executing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: QuantTheme.positive,
        content: Text('Paper order executed and logged to Positions & Orders.'),
      ),
    );
  }

  Future<void> _handleLiveApprovalRequest() async {
    final sig = widget.signal;
    if (sig.action == SignalAction.noTrade || sig.strike == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: QuantTheme.negative,
          content: Text('Cannot execute Live Order: Signal is currently NO TRADE.'),
        ),
      );
      return;
    }

    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: sig.entryPremium,
      exitPremium: sig.targetPremium,
      quantity: sig.lotSize,
    );

    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: QuantTheme.bgPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          border: const BorderSide(color: QuantTheme.border),
        ),
        title: Row(
          children: [
            const Icon(Icons.verified_user, color: QuantTheme.warning, size: 18),
            const SizedBox(width: 8),
            Text('Manual Live Order Approval', style: QuantTheme.heading(size: 14)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Contract: ${sig.index.label} ${sig.expiry} ${sig.strike} ${sig.action == SignalAction.buyCe ? "CE" : "PE"}\n'
              'Direction: BUY (INTRADAY MARKET)\n'
              'Quantity: ${sig.lotSize} (${sig.lotSize ~/ sig.index.defaultLotSize} Lot)\n'
              'Entry Premium: ₹${sig.entryPremium.toStringAsFixed(2)}\n'
              'Stop-Loss: ₹${sig.stopLossPremium.toStringAsFixed(2)}  |  Target: ₹${sig.targetPremium.toStringAsFixed(2)}\n'
              'Est. Charges + Slippage: ₹${costs.totalFrictionInr.toStringAsFixed(2)}\n'
              'Total Capital Required: ₹${sig.requiredCapital.toStringAsFixed(2)}',
              style: QuantTheme.mono(size: 11, color: QuantTheme.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              'Next step will verify typed LIVE confirmation before transmitting to broker.',
              style: QuantTheme.label(size: 11, color: QuantTheme.warning),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: QuantTheme.negative),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Proceed to LIVE Confirmation'),
          ),
        ],
      ),
    );

    if (proceed != true || !mounted) return;
    final liveConfirmed = await V2ControlDialogs.confirmSwitchToLive(context);
    if (!liveConfirmed || !mounted) return;

    setState(() => _executing = true);
    widget.appState.toggleTradingMode(true);
    await widget.appState.executeActiveSignal();
    if (!mounted) return;
    setState(() => _executing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: QuantTheme.accent,
        content: Text('Live order request processed. Check Orders tab for broker status.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sig = widget.signal;
    final engine = DhanDataEngine.instance;
    final spot = engine.spotPrices[sig.index] ?? 0.0;
    final rows = engine.optionChainRows[sig.index] ?? [];
    final ai = AiRecalibrationEngine.instance;
    final settings = StrategySettingsEngine.instance.current;

    StrikeRowSnapshot? strikeRow;
    for (final r in rows) {
      if (r.strike == sig.strike || r.offset == 0) {
        strikeRow = r;
        if (r.strike == sig.strike) break;
      }
    }

    final isCall = sig.action == SignalAction.buyCe;
    final isTradable = sig.action != SignalAction.noTrade && sig.entryPremium > 0;
    final optLabel = isCall ? 'CE' : (sig.action == SignalAction.buyPe ? 'PE' : 'NONE');

    final entry = sig.entryPremium;
    final sl = sig.stopLossPremium;
    final tgt = sig.targetPremium;
    final expGainPts = isTradable ? (tgt - entry) : 0.0;
    final maxRiskPts = isTradable ? (entry - sl).abs() : 0.0;
    final rrRatio = maxRiskPts > 0 ? (expGainPts / maxRiskPts) : 0.0;
    final targetPct = entry > 0 ? ((tgt - entry) / entry) * 100.0 : 0.0;
    final slPct = entry > 0 ? ((sl - entry) / entry) * 100.0 : 0.0;

    final costs = RiskEngine.computeRoundTripCostsAndSlippage(
      entryPremium: entry,
      exitPremium: tgt,
      quantity: sig.lotSize,
    );
    final netEv = RiskEngine.computeNetExpectedValueInr(
      winProbability: (sig.confidencePct / 100.0).clamp(0.01, 0.99),
      entryPremium: entry,
      stopLossPremium: sl,
      targetPremium: tgt,
      quantity: sig.lotSize,
    );

    // Compute comparable setups win rate from stored 1m bars
    int compCount = 0;
    int compWins = 0;
    for (int i = 3; i < _comparableBars.length - 3; i++) {
      final b = _comparableBars[i] as OneMinEnrichedBar;
      final nxt = _comparableBars[i + 3] as OneMinEnrichedBar;
      if (b.oiChange15m.abs() >= settings.oiChangeThreshold * 0.25) {
        compCount++;
        if (nxt.close > b.close) compWins++;
      }
    }
    final compWinPct = compCount > 0 ? (compWins / compCount) * 100.0 : 0.0;

    return Scaffold(
      backgroundColor: QuantTheme.bgMain,
      appBar: AppBar(
        title: const Text('Signal Details & Execution Gate'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: QuantBadge(
                text: widget.appState.isLiveMode ? 'LIVE MODE' : 'PAPER MODE',
                color: widget.appState.isLiveMode
                    ? QuantTheme.negative
                    : QuantTheme.positive,
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Confirmed / No-Trade Banner
            QuantPanel(
              backgroundColor: isTradable
                  ? QuantTheme.positive.withOpacity(0.12)
                  : QuantTheme.bgPanel,
              borderColor: isTradable ? QuantTheme.positive : QuantTheme.border,
              child: Row(
                children: [
                  Icon(
                    isTradable ? Icons.check_circle : Icons.pause_circle_filled,
                    color: isTradable ? QuantTheme.positive : QuantTheme.warning,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isTradable
                              ? '${sig.action.label} — STRATEGY CONFIRMED'
                              : 'NO TRADE — STANDING BY',
                          style: QuantTheme.heading(
                            size: 14,
                            color: isTradable
                                ? QuantTheme.positive
                                : QuantTheme.warning,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Confidence: ${sig.confidencePct.toStringAsFixed(1)}%  |  Model: ${sig.modelVersion}',
                          style: QuantTheme.mono(
                            size: 11,
                            color: QuantTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Contract & Pricing Specification Table
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CONTRACT & EXECUTION LEVELS', style: QuantTheme.heading(size: 12)),
                  const Divider(color: QuantTheme.border, height: 16),
                  _kvRow('Underlying Index', '${sig.index.label} (${spot.toStringAsFixed(2)})'),
                  _kvRow('Strike & Option Type', sig.strike > 0 ? '${sig.strike} $optLabel (ATM Band)' : 'Awaiting Strike'),
                  _kvRow('Active Expiry', sig.expiry),
                  _kvRow('Entry Premium', '₹${entry.toStringAsFixed(2)}', valueColor: QuantTheme.accent),
                  _kvRow(
                    'Target Premium',
                    '₹${tgt.toStringAsFixed(2)} (+${targetPct.toStringAsFixed(1)}% / +${expGainPts.toStringAsFixed(2)} pts)',
                    valueColor: QuantTheme.positive,
                  ),
                  _kvRow(
                    'Stop-Loss Premium',
                    '₹${sl.toStringAsFixed(2)} (${slPct.toStringAsFixed(1)}% / -${maxRiskPts.toStringAsFixed(2)} pts)',
                    valueColor: QuantTheme.negative,
                  ),
                  _kvRow('Reward / Risk Ratio', '${rrRatio.toStringAsFixed(2)}x'),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Why This Signal? (Model Explanations & Technical Confirmation)
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MODEL EXPLANATIONS & TECHNICAL CONFIRMATION',
                      style: QuantTheme.heading(size: 12)),
                  const Divider(color: QuantTheme.border, height: 16),
                  _bulletRow(sig.htfOiReason, true),
                  ...sig.reasons.map((r) => _bulletRow(r, !r.startsWith('BLOCKED'))),
                  if (strikeRow != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Greeks Snapshot (${strikeRow.strike}): '
                      'IV ${(isCall ? strikeRow.ceIv : strikeRow.peIv).toStringAsFixed(2)}% | '
                      'Δ ${(isCall ? strikeRow.ceDelta : strikeRow.peDelta).toStringAsFixed(3)} | '
                      'Γ ${strikeRow.ceGamma.toStringAsFixed(5)} | '
                      'Θ ${strikeRow.ceTheta.toStringAsFixed(2)}/d | '
                      'ν ${strikeRow.ceVega.toStringAsFixed(2)}',
                      style: QuantTheme.mono(size: 11, color: QuantTheme.accent),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Risk Calculations & Friction Breakdown
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('RISK & STATUTORY COST BREAKDOWN',
                          style: QuantTheme.heading(size: 12)),
                      QuantBadge(
                        text: sig.riskWithinLimits ? 'RISK PASSED' : 'RISK BLOCKED',
                        color: sig.riskWithinLimits
                            ? QuantTheme.positive
                            : QuantTheme.negative,
                      ),
                    ],
                  ),
                  const Divider(color: QuantTheme.border, height: 16),
                  _kvRow('Quantity / Lot Size', '${sig.lotSize} qty (${sig.index.defaultLotSize}/lot)'),
                  _kvRow('Required Margin / Outlay', '₹${sig.requiredCapital.toStringAsFixed(2)}'),
                  _kvRow('Available Broker Capital', '₹${sig.availableCapital.toStringAsFixed(2)}'),
                  _kvRow(
                    'Max Potential Stop Loss',
                    '₹${((maxRiskPts * sig.lotSize) + costs.totalFrictionInr).toStringAsFixed(2)}',
                    valueColor: QuantTheme.negative,
                  ),
                  _kvRow(
                    'Statutory Charges + Slippage',
                    '₹${costs.totalFrictionInr.toStringAsFixed(2)} (Tax/Brk ₹${costs.totalStatutoryChargesInr.toStringAsFixed(1)} + Slip ₹${costs.totalSlippageInr.toStringAsFixed(1)})',
                  ),
                  _kvRow(
                    'Modeled Net Expected Value (EV)',
                    '${netEv >= 0 ? "+" : ""}₹${netEv.toStringAsFixed(2)}',
                    valueColor: netEv >= 0 ? QuantTheme.positive : QuantTheme.negative,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Trade Invalidation Conditions & Comparable Historical Setups
            QuantPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TRADE INVALIDATION & HISTORICAL COMPARABLES',
                      style: QuantTheme.heading(size: 12)),
                  const Divider(color: QuantTheme.border, height: 16),
                  _warnRow('Invalidated if option premium breaches SL ₹${sl.toStringAsFixed(2)} on 1m tick.'),
                  _warnRow('Time-Stop Exit if target not reached within ${settings.timeExitMinutes} minutes (Theta protection).'),
                  _warnRow('Abstain if HMM Chop probability rises above 62% (Current: ${(ai.probChopRegime * 100).toStringAsFixed(0)}%).'),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: QuantTheme.bgElevated,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Comparable SQLite 1m Setups:',
                            style: QuantTheme.label(size: 11)),
                        Text(
                          compCount > 0
                              ? '$compWins / $compCount won (${compWinPct.toStringAsFixed(1)}%)'
                              : 'Collecting live bars (${_comparableBars.length} stored)',
                          style: QuantTheme.mono(
                            size: 11,
                            color: QuantTheme.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Dual Action Buttons: Paper Trade & Request Live Approval
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: QuantTheme.bgElevated,
                        foregroundColor: QuantTheme.accent,
                        side: const BorderSide(color: QuantTheme.accent),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: (_executing || !isTradable) ? null : _handlePaperExecution,
                      icon: const Icon(Icons.science_outlined, size: 17),
                      label: Text(
                        'Paper Trade',
                        style: QuantTheme.heading(size: 12, color: QuantTheme.accent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: QuantTheme.positive,
                        foregroundColor: QuantTheme.bgMain,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: (_executing || !isTradable) ? null : _handleLiveApprovalRequest,
                      icon: const Icon(Icons.gpp_good, size: 17),
                      label: Text(
                        'Request Live Approval',
                        style: QuantTheme.heading(size: 12, color: QuantTheme.bgMain),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(String k, String v, {Color valueColor = QuantTheme.textPrimary}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: QuantTheme.label(size: 11)),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: QuantTheme.mono(size: 12, color: valueColor, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bulletRow(String text, bool ok) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 15,
            color: ok ? QuantTheme.positive : QuantTheme.negative,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: QuantTheme.label(size: 11, color: QuantTheme.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _warnRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 15, color: QuantTheme.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: QuantTheme.label(size: 11, color: QuantTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
