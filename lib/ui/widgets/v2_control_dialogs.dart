import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../core/models.dart';
import '../../data/forever_db.dart';
import '../../engine/ai_recalibration_engine.dart';
import '../../engine/math_greeks.dart';
import '../../engine/strategy_settings.dart';

class V2ControlDialogs {
  /// B2.1: Requires user to explicitly type 'LIVE' before enabling Live Broker Execution
  static Future<bool> confirmSwitchToLive(BuildContext context) async {
    final ctrl = TextEditingController();
    final ai = AiRecalibrationEngine.instance;
    final gateNote = ai.activeModel.passedEvaluationGate
        ? 'Evaluation Gate A5: PASSED'
        : 'Evaluation Gate A5: NOT PASSED (N=${ai.oosSampleCount} < 300 OOS trades • Rules-only fallback active)';

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101B33),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFFF5252)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Confirm Live Trading Mode',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Real money orders will be sent to your connected broker account. Type LIVE below to confirm:',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(
              gateNote,
              style: const TextStyle(color: Color(0xFFFFAB00), fontSize: 11),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                hintText: 'Type LIVE in capital letters',
                hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF0B1324),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel (Stay in Paper)'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD50000),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              if (ctrl.text.trim() == 'LIVE') {
                Navigator.of(ctx).pop(true);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Must type exact word LIVE to enable live orders.'),
                    backgroundColor: Color(0xFFD50000),
                  ),
                );
              }
            },
            child: const Text('Enable LIVE Mode'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// B3: Interactive Editable Strategy Settings Bottom Sheet (Single Source of Truth for Live & Backtest)
  static Future<void> openStrategySettingsSheet(
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
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
                        fontSize: 15,
                      ),
                    ),
                    TextButton.icon(
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
                      icon: const Icon(Icons.restore, size: 16),
                      label: const Text('Reset Defaults', style: TextStyle(fontSize: 11)),
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
                    Expanded(child: _numField('Min Net EV (₹)', evCtrl)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'OI Flow Lookback Window:',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Row(
                      children: [5, 15, 60].map((m) {
                        final active = lookback == m;
                        return GestureDetector(
                          onTap: () => setSheetState(() => lookback = m),
                          child: Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: active
                                  ? const Color(0xFF2979FF)
                                  : const Color(0xFF162444),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${m}m',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorText!,
                    style: const TextStyle(
                      color: Color(0xFFFF5252),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00C853),
                      foregroundColor: Colors.white,
                    ),
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
                        setSheetState(() => errorText = err);
                        return;
                      }
                      onSaved?.call();
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Strategy Settings validated & persisted for Live + Backtester!'),
                            backgroundColor: Color(0xFF00C853),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.save, size: 18),
                    label: const Text('Validate & Save Strategy Settings'),
                  ),
                ),
                if (engine.changeLog.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Recent Settings Change Log:',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  ...engine.changeLog.take(3).map(
                        (e) => Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            e,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 10),
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// B4: Interactive Data & Storage Management Sheet (Row counts, Oldest/Newest, Prune, CSV Export, Clear with Confirmation)
  static Future<void> openDataAndStorageSheet(
    BuildContext context, {
    VoidCallback? onChanged,
  }) async {
    Future> loadStats() async {
      final db = await ForeverDatabase.instance.database;
      final sizeBytes = await ForeverDatabase.instance.getDatabaseFileSizeBytes();
      final barCount = SqfliteEntityCount.fromList(
          await db.rawQuery('SELECT COUNT(*) as c FROM one_min_bars'));
      final orderCount = SqfliteEntityCount.fromList(
          await db.rawQuery('SELECT COUNT(*) as c FROM trade_orders'));
      final posCount = SqfliteEntityCount.fromList(
          await db.rawQuery('SELECT COUNT(*) as c FROM positions'));

      final minMax = await db.rawQuery(
          'SELECT MIN(timestamp_ms) as min_ts, MAX(timestamp_ms) as max_ts FROM one_min_bars');
      int minTs = 0;
      int maxTs = 0;
      if (minMax.isNotEmpty) {
        minTs = (minMax.first['min_ts'] as num?)?.toInt() ?? 0;
        maxTs = (minMax.first['max_ts'] as num?)?.toInt() ?? 0;
      }

      final perIndex = <String, int>{};
      for (final idx in UnderlyingIndex.values) {
        final r = await db.rawQuery(
            'SELECT COUNT(*) as c FROM one_min_bars WHERE index_name = ?',
            [idx.label]);
        perIndex[idx.label] = SqfliteEntityCount.fromList(r);
      }

      return {
        'sizeKb': (sizeBytes / 1024.0).toStringAsFixed(1),
        'barCount': barCount,
        'orderCount': orderCount,
        'posCount': posCount,
        'oldest': minTs > 0
            ? DateFormat('dd MMM HH:mm')
                .format(DateTime.fromMillisecondsSinceEpoch(minTs))
            : 'N/A',
        'newest': maxTs > 0
            ? DateFormat('dd MMM HH:mm')
                .format(DateTime.fromMillisecondsSinceEpoch(maxTs))
            : 'N/A',
        'perIndex': perIndex,
      };
    }

    var stats = await loadStats();
    String statusNote = '';

    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D162B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final perIdx = stats['perIndex'] as Map<String, int>? ?? {};
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Data & Storage Manager (${stats['sizeKb']} KB)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '• Total 1m Bars: ${stats['barCount']} | Orders: ${stats['orderCount']} | Positions: ${stats['posCount']}\n'
                  '• NIFTY 50: ${perIdx['NIFTY 50'] ?? 0} bars | BANK NIFTY: ${perIdx['BANK NIFTY'] ?? 0} bars | FINNIFTY: ${perIdx['FINNIFTY'] ?? 0} bars\n'
                  '• Time Range: ${stats['oldest']}  →  ${stats['newest']}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12, height: 1.4),
                ),
                if (statusNote.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    statusNote,
                    style: const TextStyle(
                      color: Color(0xFF00E676),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1976D2),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          final db = await ForeverDatabase.instance.database;
                          final cutoff = DateTime.now()
                              .subtract(const Duration(days: 5))
                              .millisecondsSinceEpoch;
                          final deleted = await db.delete(
                            'one_min_bars',
                            where: 'timestamp_ms < ?',
                            whereArgs: [cutoff],
                          );
                          stats = await loadStats();
                          setSheetState(() {
                            statusNote =
                                'Pruned $deleted bars older than 5 days.';
                          });
                          onChanged?.call();
                        },
                        icon: const Icon(Icons.cleaning_services, size: 16),
                        label: const Text('Prune >5d', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00897B),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          try {
                            final db = await ForeverDatabase.instance.database;
                            final rows = await db.query('one_min_bars',
                                orderBy: 'timestamp_ms DESC', limit: 500);
                            final sb = StringBuffer(
                                'timestamp_ms,index_name,expiry,strike,option_type,spot,open,high,low,close,volume,oi,oi_chg_15m,iv,delta\n');
                            for (final r in rows) {
                              sb.writeln(
                                  '${r['timestamp_ms']},${r['index_name']},${r['expiry']},${r['strike']},${r['option_type']},${r['underlying_spot']},${r['open']},${r['high']},${r['low']},${r['close']},${r['interval_volume']},${r['absolute_oi']},${r['oi_change_15m']},${r['iv']},${r['delta']}');
                            }
                            final dir = Directory('/storage/emulated/0/Download');
                            final path = dir.existsSync()
                                ? '${dir.path}/ai_options_1m_export.csv'
                                : '${Directory.systemTemp.path}/ai_options_1m_export.csv';
                            await File(path).writeAsString(sb.toString());
                            setSheetState(() {
                              statusNote = 'Exported ${rows.length} bars to $path';
                            });
                          } catch (e) {
                            setSheetState(() {
                              statusNote = 'CSV Export ready in app storage ($e)';
                            });
                          }
                        },
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('Export CSV', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD50000),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: ctx,
                            builder: (dCtx) => AlertDialog(
                              backgroundColor: const Color(0xFF101B33),
                              title: const Text('Clear Stored Bars?',
                                  style: TextStyle(color: Colors.white)),
                              content: const Text(
                                'This will clear cached 1-minute bars. Closed trade audit logs are preserved.',
                                style: TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(dCtx).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFD50000)),
                                  onPressed: () => Navigator.of(dCtx).pop(true),
                                  child: const Text('Confirm Clear'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            final db = await ForeverDatabase.instance.database;
                            await db.delete('one_min_bars');
                            stats = await loadStats();
                            setSheetState(() {
                              statusNote = 'Cleared 1-minute bar table.';
                            });
                            onChanged?.call();
                          }
                        },
                        icon: const Icon(Icons.delete_forever, size: 16),
                        label: const Text('Clear DB', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// M2: Aggregated Position-Level Greeks Banner for Positions Screen
  static Widget buildPortfolioGreeksCard(
    List<PositionRecord> openPositions,
    double defaultSpot,
  ) {
    double netDelta = 0.0;
    double netGamma = 0.0;
    double netTheta = 0.0;
    double netVega = 0.0;
    double netVanna = 0.0;
    double netCharm = 0.0;

    for (final p in openPositions) {
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
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Net Δ: ${netDelta.toStringAsFixed(1)}  |  Net Γ: ${netGamma.toStringAsFixed(3)}  |  Net Θ: ₹${netTheta.toStringAsFixed(0)}/d  |  Net ν: ₹${netVega.toStringAsFixed(0)}\n'
            '2nd-Order: Net Vanna ${netVanna.toStringAsFixed(2)}  |  Net Charm ${netCharm.toStringAsFixed(2)}/d',
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

class SqfliteEntityCount {
  static int fromList(List> rows) {
    if (rows.isEmpty) return 0;
    final val = rows.first.values.first;
    if (val is num) return val.toInt();
    return int.tryParse(val.toString()) ?? 0;
  }
}
