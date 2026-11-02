import 'dart:convert';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';

class StrategySettings {
  final int oiChangeThreshold;
  final int minVolumeFilter;
  final double minIvPct;
  final double maxIvPct;
  final double targetPct;
  final double stopLossPct;
  final int timeExitMinutes;
  final int lookbackMinutes;
  final double minNetEvInr;
  final Map perIndexOverrides;

  const StrategySettings({
    this.oiChangeThreshold = 120000,
    this.minVolumeFilter = 350,
    this.minIvPct = 7.5,
    this.maxIvPct = 48.0,
    this.targetPct = 14.0,
    this.stopLossPct = 8.0,
    this.timeExitMinutes = 10,
    this.lookbackMinutes = 15,
    this.minNetEvInr = 15.0,
    this.perIndexOverrides = const {},
  });

  double targetPctForIndex(UnderlyingIndex idx) {
    final ov = perIndexOverrides[idx.label] as Map?;
    final v = (ov?['targetPct'] as num?)?.toDouble();
    if (v != null && v > 0) return v;
    return targetPct;
  }

  double stopLossPctForIndex(UnderlyingIndex idx) {
    final ov = perIndexOverrides[idx.label] as Map?;
    final v = (ov?['stopLossPct'] as num?)?.toDouble();
    if (v != null && v > 0) return v;
    return stopLossPct;
  }

  int oiThresholdForIndex(UnderlyingIndex idx) {
    final ov = perIndexOverrides[idx.label] as Map?;
    final v = (ov?['oiChangeThreshold'] as num?)?.toInt();
    if (v != null && v > 0) return v;
    return oiChangeThreshold;
  }

  String? validate() {
    if (0 >= oiChangeThreshold) return 'OI change threshold must be positive.';
    if (0 > minVolumeFilter) return 'Volume filter cannot be negative.';
    if (1.0 >= minIvPct || minIvPct >= maxIvPct || maxIvPct > 150.0) {
      return 'IV band must satisfy 1% to 150% with minIV below maxIV.';
    }
    if (1.0 >= targetPct || targetPct > 200.0) {
      return 'Target % must be between 1% and 200%.';
    }
    if (0.5 >= stopLossPct || stopLossPct >= 95.0) {
      return 'Stop-Loss % must be between 0.5% and 95%.';
    }
    if (1 > timeExitMinutes || timeExitMinutes > 375) {
      return 'Time exit must be between 1 and 375 minutes.';
    }
    if (lookbackMinutes != 5 && lookbackMinutes != 15 && lookbackMinutes != 60) {
      return 'Lookback window must be 5, 15, or 60 minutes.';
    }
    return null;
  }

  Map toMap() => {
        'oiChangeThreshold': oiChangeThreshold,
        'minVolumeFilter': minVolumeFilter,
        'minIvPct': minIvPct,
        'maxIvPct': maxIvPct,
        'targetPct': targetPct,
        'stopLossPct': stopLossPct,
        'timeExitMinutes': timeExitMinutes,
        'lookbackMinutes': lookbackMinutes,
        'minNetEvInr': minNetEvInr,
        'perIndexOverrides': perIndexOverrides,
      };

  factory StrategySettings.fromMap(Map m) {
    return StrategySettings(
      oiChangeThreshold: (m['oiChangeThreshold'] as num?)?.toInt() ?? 120000,
      minVolumeFilter: (m['minVolumeFilter'] as num?)?.toInt() ?? 350,
      minIvPct: (m['minIvPct'] as num?)?.toDouble() ?? 7.5,
      maxIvPct: (m['maxIvPct'] as num?)?.toDouble() ?? 48.0,
      targetPct: (m['targetPct'] as num?)?.toDouble() ?? 14.0,
      stopLossPct: (m['stopLossPct'] as num?)?.toDouble() ?? 8.0,
      timeExitMinutes: (m['timeExitMinutes'] as num?)?.toInt() ?? 10,
      lookbackMinutes: (m['lookbackMinutes'] as num?)?.toInt() ?? 15,
      minNetEvInr: (m['minNetEvInr'] as num?)?.toDouble() ?? 15.0,
      perIndexOverrides: (m['perIndexOverrides'] as Map?) ?? const {},
    );
  }
}

class StrategySettingsEngine {
  static final StrategySettingsEngine instance = StrategySettingsEngine._();
  StrategySettingsEngine._();

  static const _kSettingsJson = 'v2_strategy_settings_json';
  static const _kChangeLogList = 'v2_strategy_changelog';

  StrategySettings current = const StrategySettings();
  final List changeLog = [];

  Future load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSettingsJson);
      if (raw != null && raw.isNotEmpty) {
        current = StrategySettings.fromMap(jsonDecode(raw) as Map);
      }
      final logs = prefs.getStringList(_kChangeLogList) ?? [];
      changeLog
        ..clear()
        ..addAll(logs);
    } catch (_) {}
  }

  Future updateAndPersist(StrategySettings next, {String note = 'Updated settings'}) async {
    final err = next.validate();
    if (err != null) return err;

    current = next;
    final ts = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final entry =
        '[$ts] $note (Target:${next.targetPct}%, SL:${next.stopLossPct}%, Lookback:${next.lookbackMinutes}m, OI:${next.oiChangeThreshold})';
    changeLog.insert(0, entry);
    if (changeLog.length > 40) {
      changeLog.removeLast();
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSettingsJson, jsonEncode(next.toMap()));
      await prefs.setStringList(
          _kChangeLogList, changeLog.map((e) => e.toString()).toList());
    } catch (_) {}
    return null;
  }

  Future resetToDefaults() async {
    await updateAndPersist(
      const StrategySettings(),
      note: 'Reset strategy settings to factory defaults',
    );
  }
}
