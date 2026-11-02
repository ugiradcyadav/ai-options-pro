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
  final int lookbackMinutes; // 5, 15, or 60
  final double minNetEvInr;
  final Map<String, Map<String, double>> perIndexOverrides;

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
    final ov = perIndexOverrides[idx.label];
    if (ov != null && ov['targetPct'] != null && ov['targetPct']! > 0) {
      return ov['targetPct']!;
    }
    return targetPct;
  }

  double stopLossPctForIndex(UnderlyingIndex idx) {
    final ov = perIndexOverrides[idx.label];
    if (ov != null && ov['stopLossPct'] != null && ov['stopLossPct']! > 0) {
      return ov['stopLossPct']!;
    }
    return stopLossPct;
  }

  int oiThresholdForIndex(UnderlyingIndex idx) {
    final ov = perIndexOverrides[idx.label];
    if (ov != null && ov['oiChangeThreshold'] != null && ov['oiChangeThreshold']! > 0) {
      return ov['oiChangeThreshold']!.round();
    }
    return oiChangeThreshold;
  }

  /// Validates all parameters; returns null if valid, or human-readable error message
  String? validate() {
    if (oiChangeThreshold <= 0) return 'OI change threshold must be > 0.';
    if (minVolumeFilter < 0) return 'Volume filter cannot be negative.';
    if (minIvPct <= 1.0 || maxIvPct <= minIvPct || maxIvPct > 150.0) {
      return 'IV band must satisfy 1% < minIV < maxIV <= 150%.';
    }
    if (targetPct <= 1.0 || targetPct > 200.0) {
      return 'Target % must be between 1% and 200%.';
    }
    if (stopLossPct <= 0.5 || stopLossPct >= 95.0) {
      return 'Stop-Loss % must be between 0.5% and 95%.';
    }
    if (timeExitMinutes < 1 || timeExitMinutes > 375) {
      return 'Time exit must be between 1 and 375 minutes.';
    }
    if (lookbackMinutes != 5 && lookbackMinutes != 15 && lookbackMinutes != 60) {
      return 'Lookback window must be 5, 15, or 60 minutes.';
    }
    return null;
  }

  StrategySettings copyWith({
    int? oiChangeThreshold,
    int? minVolumeFilter,
    double? minIvPct,
    double? maxIvPct,
    double? targetPct,
    double? stopLossPct,
    int? timeExitMinutes,
    int? lookbackMinutes,
    double? minNetEvInr,
    Map<String, Map<String, double>>? perIndexOverrides,
  }) {
    return StrategySettings(
      oiChangeThreshold: oiChangeThreshold ?? this.oiChangeThreshold,
      minVolumeFilter: minVolumeFilter ?? this.minVolumeFilter,
      minIvPct: minIvPct ?? this.minIvPct,
      maxIvPct: maxIvPct ?? this.maxIvPct,
      targetPct: targetPct ?? this.targetPct,
      stopLossPct: stopLossPct ?? this.stopLossPct,
      timeExitMinutes: timeExitMinutes ?? this.timeExitMinutes,
      lookbackMinutes: lookbackMinutes ?? this.lookbackMinutes,
      minNetEvInr: minNetEvInr ?? this.minNetEvInr,
      perIndexOverrides: perIndexOverrides ?? this.perIndexOverrides,
    );
  }

  Map<String, dynamic> toMap() => {
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
    final rawOv = m['perIndexOverrides'] as Map? ?? {};
    final parsedOv = <String, Map<String, double>>{};
    for (final entry in rawOv.entries) {
      if (entry.value is Map) {
        final inner = <String, double>{};
        for (final ie in (entry.value as Map).entries) {
          inner[ie.key.toString()] = (ie.value as num).toDouble();
        }
        parsedOv[entry.key.toString()] = inner;
      }
    }
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
      perIndexOverrides: parsedOv,
    );
  }
}

class StrategySettingsEngine {
  static final StrategySettingsEngine instance = StrategySettingsEngine._();
  StrategySettingsEngine._();

  static const _kSettingsJson = 'v2_strategy_settings_json';
  static const _kChangeLogList = 'v2_strategy_changelog';

  StrategySettings current = const StrategySettings();
  final List<String> changeLog = [];

  Future<void> load() async {
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

  Future<String?> updateAndPersist(StrategySettings next, {String note = 'Updated settings'}) async {
    final err = next.validate();
    if (err != null) return err;

    current = next;
    final ts = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final entry = '[$ts] $note (Target:${next.targetPct}%, SL:${next.stopLossPct}%, Lookback:${next.lookbackMinutes}m, OI>=${next.oiChangeThreshold})';
    changeLog.insert(0, entry);
    if (changeLog.length > 40) {
      changeLog.removeLast();
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSettingsJson, jsonEncode(next.toMap()));
      await prefs.setStringList(_kChangeLogList, changeLog);
    } catch (_) {}
    return null;
  }

  Future<void> resetToDefaults() async {
    await updateAndPersist(
      const StrategySettings(),
      note: 'Reset strategy settings to factory defaults',
    );
  }
}
