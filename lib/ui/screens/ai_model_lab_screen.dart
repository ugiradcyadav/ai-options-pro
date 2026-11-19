import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/dataset_label_engine.dart';
import '../../state/app_state.dart';
import '../theme/quant_theme.dart';

class AiModelLabScreen extends StatefulWidget {
  final AppState appState;
  final bool embeddedMode;

  const AiModelLabScreen({
    super.key,
    required this.appState,
    this.embeddedMode = false,
  });

  @override
  State<AiModelLabScreen> createState() => _AiModelLabScreenState();
}

class _AiModelLabScreenState extends State<AiModelLabScreen> {
  bool _recalibrating = false;
  int _totalBarsStored = 0;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    final db = await ForeverDatabase.instance.database;
    final rows = await db.query('one_min_bars', columns: ['id']);
    if (!mounted) return;
    setState(() => _totalBarsStored = rows.length);
  }

  Future<void> _runRecalibration() async {
    setState(() => _recalibrating = true);
    await AiRecalibrationEngine.instance
        .runLightweightFiveDayRecalibration(force: true);
    await _loadCounts();
    if (!mounted) return;
    setState(() => _recalibrating = false);
  }

  @override
  Widget build(BuildContext context) {
    final ai = AiRecalibrationEngine.instance;
    final meta = ai.activeModel;
    final lastCalStr = ai.lastCalibrationMs > 0
        ? DateFormat('dd MMM yyyy HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(ai.lastCalibrationMs))
        : 'Not yet calibrated';

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('AI Model Laboratory & Registry',
                      style: QuantTheme.heading(size: 13)),
                  QuantBadge(
                    text: meta.passedEvaluationGate
                        ? 'GATE A5: PROMOTED'
                        : 'RULES-ONLY (SHADOW)',
                    color: meta.passedEvaluationGate
                        ? QuantTheme.positive
                        : QuantTheme.warning,
                  ),
                ],
              ),
              const Divider(color: QuantTheme.border, height: 14),
              _kvRow('Active Model Version', meta.version,
                  color: QuantTheme.accent),
              _kvRow('Architecture', meta.algorithmName),
              _kvRow('Feature Schema', DatasetLabelEngine.featureSchemaVersion),
              _kvRow('Recorded Real 1m Bars', '$_totalBarsStored bars'),
              _kvRow('Last Evaluation Run', lastCalStr),
            ],
          ),
        ),
        const SizedBox(height: 10),

        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Out-of-Sample Validation & Calibration',
                  style: QuantTheme.heading(size: 12)),
              const Divider(color: QuantTheme.border, height: 14),
              _kvRow(
                'OOS Accuracy (Unclamped)',
                meta.displayAccuracyLabel,
                color: meta.hasSufficientData
                    ? QuantTheme.positive
                    : QuantTheme.warning,
              ),
              _kvRow(
                'Brier Calibration Score',
                meta.hasSufficientData
                    ? 'Pending isotonic calibration'
                    : 'Insufficient data',
              ),
              _kvRow(
                'Reliability Diagram',
                meta.hasSufficientData
                    ? 'Ready for OOS binning'
                    : 'Insufficient data (Need >= 100 real OOS trades)',
              ),
              const SizedBox(height: 10),
              Text(
                'Policy: Model probabilities are NOT used in Kelly sizing or EV gating until Gate A5 (N >= 300 real OOS trades with positive calibrated edge) passes.',
                style: QuantTheme.label(size: 10, color: QuantTheme.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        QuantPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Model Implementation Status',
                  style: QuantTheme.heading(size: 12)),
              const Divider(color: QuantTheme.border, height: 14),
              _statusRow('Symmetric Rules Strategy (Live == Backtest)', 'ACTIVE',
                  QuantTheme.positive),
              const SizedBox(height: 6),
              _statusRow('3-State Forward-HMM (Single-Pass)', 'ACTIVE',
                  QuantTheme.accent),
              const SizedBox(height: 6),
              _statusRow('Rule-Weighted Logistic Score',
                  meta.passedEvaluationGate ? 'PROMOTED' : 'SHADOW ONLY',
                  QuantTheme.warning),
              const SizedBox(height: 6),
              _statusRow('Offline Purged Walk-Forward GBDT', 'UNTRAINED',
                  QuantTheme.textSecondary),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 42,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: QuantTheme.accent,
                          foregroundColor: QuantTheme.bgMain,
                        ),
                        onPressed: _recalibrating ? null : _runRecalibration,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(
                          _recalibrating ? 'Evaluating...' : 'Evaluate OOS DB',
                          style: QuantTheme.heading(
                              size: 11, color: QuantTheme.bgMain),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 42,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: QuantTheme.warning,
                          side: const BorderSide(color: QuantTheme.warning),
                        ),
                        onPressed: () async {
                          await ai.rollbackToPreviousWeights();
                          if (mounted) setState(() {});
                        },
                        icon: const Icon(Icons.undo, size: 16),
                        label: Text('Rollback',
                            style: QuantTheme.heading(
                                size: 11, color: QuantTheme.warning)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embeddedMode) return body;
    return SingleChildScrollView(padding: const EdgeInsets.all(12), child: body);
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

  Widget _statusRow(String name, String badge, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(name, style: QuantTheme.label(size: 11))),
        QuantBadge(text: badge, color: color),
      ],
    );
  }
}
