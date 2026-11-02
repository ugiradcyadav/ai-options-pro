import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/strategy_settings.dart';

class V2ControlDialogs {
  static Future confirmSwitchToLive(BuildContext context) async {
    final ctrl = TextEditingController();
    final ai = AiRecalibrationEngine.instance;
    final gateNote = ai.activeModel.passedEvaluationGate
        ? 'Evaluation Gate A5: PASSED'
        : 'Evaluation Gate A5: NOT PASSED (N=${ai.oosSampleCount} OOS trades • Rules-only fallback active)';

    final confirmed = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101B33),
        title: const Text(
          'Confirm Live Trading Mode',
          style: TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Real money orders will be sent to your broker. Type LIVE below to confirm:',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(gateNote,
                style: const TextStyle(color: Color(0xFFFFAB00), fontSize: 11)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                hintText: 'Type LIVE in capital letters',
                hintStyle: TextStyle(color: Colors.white30, fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD50000)),
            onPressed: () {
              if (ctrl.text.trim() == 'LIVE') {
                Navigator.of(ctx).pop(true);
              }
            },
            child: const Text('Enable LIVE Mode'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  static Future openStrategySettingsSheet(
    BuildContext context, {
    VoidCallback? onSaved,
  }) async {
    final engine = StrategySettingsEngine.instance;
    await engine.load();
    final cur = engine.current;

    final oiCtrl = TextEditingController(text: cur.oiChangeThreshold.toString());
    final volCtrl = TextEditingController(text: cur.minVolumeFilter.toString());
    final minIvCtrl = TextEditingController(text: cur.minIvPct.toString());
    final maxIvCtrl = TextEditingController(text: cur.maxIvPct.toString());
    final targetCtrl = TextEditingController(text: cur.targetPct.toString());
    final slCtrl = TextEditingController(text: cur.stopLossPct.toString());
    final timeCtrl = TextEditingController(text: cur.timeExitMinutes.toString());
    final evCtrl = TextEditingController(text: cur.minNetEvInr.toString());
    int lookback = cur.lookbackMinutes;
    String? errorText;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0D162B),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Strategy Settings (Live & Backtest)',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                    TextButton(
                      onPressed: () async {
                        await engine.resetToDefaults();
                        final def = engine.current;
                        oiCtrl.text = def.oiChangeThreshold.toString();
                        volCtrl.text = def.minVolumeFilter.toString();
                        minIvCtrl.text = def.minIvPct.toString();
                        maxIvCtrl.text = def.maxIvPct.toString();
                        targetCtrl.text = def.targetPct.toString();
                        slCtrl.text = def.stopLossPct.toString();
                        timeCtrl.text = def.timeExitMinutes.toString();
                        evCtrl.text = def.minNetEvInr.toString();
                        setSheetState(() {
                          lookback = def.lookbackMinutes;
                          errorText = null;
                        });
                        onSaved?.call();
                      },
                      child: const Text('Reset Defaults'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _numField('OI Change Threshold', oiCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _numField('Min 1m Volume', volCtrl)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _numField('Min IV %', minIvCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _numField('Max IV %', maxIvCtrl)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _numField('Target Profit %', targetCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _numField('Stop-Loss %', slCtrl)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _numField('Time Exit (Mins)', timeCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _numField('Min Net EV (INR)', evCtrl)),
                  ],
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(errorText!,
                      style: const TextStyle(
                          color: Color(0xFFFF5252), fontSize: 12)),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00C853)),
                    onPressed: () async {
                      final candidate = StrategySettings(
                        oiChangeThreshold: int.tryParse(oiCtrl.text.trim()) ?? -1,
                        minVolumeFilter: int.tryParse(volCtrl.text.trim()) ?? -1,
                        minIvPct: double.tryParse(minIvCtrl.text.trim()) ?? -1,
                        maxIvPct: double.tryParse(maxIvCtrl.text.trim()) ?? -1,
                        targetPct: double.tryParse(targetCtrl.text.trim()) ?? -1,
                        stopLossPct: double.tryParse(slCtrl.text.trim()) ?? -1,
                        timeExitMinutes: int.tryParse(timeCtrl.text.trim()) ?? -1,
                        lookbackMinutes: lookback,
                        minNetEvInr: double.tryParse(evCtrl.text.trim()) ?? 0.0,
                      );
                      final err = await engine.updateAndPersist(candidate);
                      if (err != null) {
                        setSheetState(() => errorText = err.toString());
                        return;
                      }
                      onSaved?.call();
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('Validate & Save Strategy Settings'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Future openDataAndStorageSheet(
    BuildContext context, {
    VoidCallback? onChanged,
  }) async {
    final db = await ForeverDatabase.instance.database;
    final rows = await db.query('one_min_bars');
    final sizeBytes = rows.length * 256;
    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D162B),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Data & Storage Manager (${(sizeBytes / 1024.0).toStringAsFixed(1)} KB)',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              'Stored 1-Minute Enriched Bars: ${rows.length}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      final cutoff = DateTime.now()
                          .subtract(const Duration(days: 5))
                          .millisecondsSinceEpoch;
                      await db.delete('one_min_bars',
                          where: 'timestamp_ms < ?', whereArgs: [cutoff]);
                      onChanged?.call();
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('Prune 5d+'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD50000)),
                    onPressed: () async {
                      await db.delete('one_min_bars');
                      onChanged?.call();
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('Clear Bars'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget buildPortfolioGreeksCard(
    List openPositions,
    double defaultSpot,
  ) {
    double netDelta = 0.0;
    double netGamma = 0.0;
    double netTheta = 0.0;
    double netVega = 0.0;
    double netVanna = 0.0;
    double netCharm = 0.0;

    for (final raw in openPositions) {
      final p = raw as PositionRecord;
      if (!p.isOpen) continue;
      final isCall = p.optionType.toUpperCase() == 'CE';
      final spot = defaultSpot > 0 ? defaultSpot : p.strike.toDouble();
      final g = MathGreeksEngine.computeIvAndGreeks(
        spot: spot,
        strike: p.strike.toDouble(),
        optionLtp: p.currentLtp > 0 ? p.currentLtp : p.avgEntryPrice,
        daysToExpiry: 4.0,
        isCall: isCall,
      );
      netDelta += g.delta * p.quantity;
      netGamma += g.gamma * p.quantity;
      netTheta += g.theta * p.quantity;
      netVega += g.vega * p.quantity;
      netVanna += g.vanna * p.quantity;
      netCharm += g.charm * p.quantity;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF101B33),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E325C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Portfolio Aggregated Greeks (M2 First & Second-Order)',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            'Net Δ: ${netDelta.toStringAsFixed(1)} | Net Γ: ${netGamma.toStringAsFixed(3)} | Net Θ: ₹${netTheta.toStringAsFixed(0)}/d | Net ν: ₹${netVega.toStringAsFixed(0)}\n'
            '2nd-Order: Net Vanna ${netVanna.toStringAsFixed(2)} | Net Charm ${netCharm.toStringAsFixed(2)}/d',
            style: const TextStyle(
                color: Colors.cyanAccent, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  static Widget _numField(String label, TextEditingController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0xFF162444),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}
