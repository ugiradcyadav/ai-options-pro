import '../core/models.dart';
import 'execution_engine.dart';
import 'strategy_settings.dart';

class ExitTriggerEvent {
  final PositionRecord closedPosition;
  final TradeOrder exitOrder;
  final String reason;

  const ExitTriggerEvent({
    required this.closedPosition,
    required this.exitOrder,
    required this.reason,
  });
}

class ExitManager {
  static final ExitManager instance = ExitManager._();
  ExitManager._();

  final List<String> persistentAlerts = [];

  /// Checks whether current UTC time is at or past 15:15 IST (09:45 UTC)
  static bool isAtOrPastForcedSquareOffIst({DateTime? nowUtc}) {
    final ist = (nowUtc ?? DateTime.now().toUtc())
        .toUtc()
        .add(const Duration(hours: 5, minutes: 30));
    if (ist.hour > 15) return true;
    if (ist.hour == 15 && ist.minute >= 15) return true;
    return false;
  }

  /// Evaluates every open position against stored SL, Target, Time-Exit, and 15:15 IST forced square-off
  Future<List<ExitTriggerEvent>> evaluateAndExecuteExits({
    required List<PositionRecord> openPositions,
    required Map<String, StrikeRowSnapshot> quoteBySecurityId,
    StrategySettings? settingsOverride,
    DateTime? nowUtc,
  }) async {
    final settings = settingsOverride ?? StrategySettingsEngine.instance.current;
    final currentUtc = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    final nowMs = currentUtc.millisecondsSinceEpoch;
    final forceSquareOff = isAtOrPastForcedSquareOffIst(nowUtc: currentUtc);
    final events = <ExitTriggerEvent>[];

    for (final pos in openPositions) {
      if (!pos.isOpen) continue;

      final quote = quoteBySecurityId[pos.securityId];
      final isCall = pos.optionType.toUpperCase() == 'CE';
      final liveLtp = quote != null
          ? (isCall ? quote.ceLtp : quote.peLtp)
          : pos.currentLtp;
      final liveBid = quote != null ? (isCall ? quote.ceBid : quote.peBid) : null;
      final liveAsk = quote != null ? (isCall ? quote.ceAsk : quote.peAsk) : null;
      final checkPrice = (liveBid != null && liveBid > 0) ? liveBid : liveLtp;

      if (checkPrice <= 0) {
        if (forceSquareOff) {
          _raiseAlert(
              'ALERT: Cannot square off ${pos.tradingSymbol} at 15:15 IST — live quote unavailable.');
        }
        continue;
      }

      String? triggerReason;
      if (forceSquareOff) {
        triggerReason = 'FORCED_1515_IST_SQUARE_OFF';
      } else if (pos.stopLossPrice > 0 && checkPrice <= pos.stopLossPrice) {
        triggerReason = 'STOP_LOSS_HIT (₹${pos.stopLossPrice.toStringAsFixed(2)})';
      } else if (pos.targetPrice > 0 && checkPrice >= pos.targetPrice) {
        triggerReason = 'TARGET_HIT (₹${pos.targetPrice.toStringAsFixed(2)})';
      } else if (pos.openedAtMs > 0 &&
          (nowMs - pos.openedAtMs) >= settings.timeExitMinutes * 60000) {
        triggerReason = 'TIME_EXIT (${settings.timeExitMinutes}m elapsed)';
      }

      if (triggerReason != null) {
        final res = await ExecutionEngine.instance.executeExit(
          position: pos,
          currentLtp: liveLtp,
          bestBid: liveBid,
          bestAsk: liveAsk,
          exitReason: triggerReason,
        );
        if (res.success && res.position != null) {
          events.add(
            ExitTriggerEvent(
              closedPosition: res.position!,
              exitOrder: res.order,
              reason: triggerReason,
            ),
          );
        } else {
          _raiseAlert(
              'EXIT FAILED for ${pos.tradingSymbol} ($triggerReason): ${res.message}');
        }
      }
    }

    return events;
  }

  void _raiseAlert(String msg) {
    if (!persistentAlerts.contains(msg)) {
      persistentAlerts.insert(0, msg);
      if (persistentAlerts.length > 20) persistentAlerts.removeLast();
    }
  }
}
