import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../core/models.dart';

class ForeverDatabase {
  static final ForeverDatabase instance = ForeverDatabase._();
  ForeverDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbFolder = await getDatabasesPath();
    final dbPath = p.join(dbFolder, 'ai_options_forever_v2.db');
    _db = await openDatabase(
      dbPath,
      version: 2,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode = WAL;');
        await db.rawQuery('PRAGMA synchronous = NORMAL;');
      },
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldV, newV) async {
        await _createTables(db);
      },
    );
    return _db!;
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bars_1m (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_ms INTEGER NOT NULL,
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        option_type TEXT NOT NULL,
        strike_offset INTEGER NOT NULL,
        underlying_spot REAL NOT NULL,
        open REAL NOT NULL,
        high REAL NOT NULL,
        low REAL NOT NULL,
        close REAL NOT NULL,
        interval_volume INTEGER NOT NULL,
        absolute_oi INTEGER NOT NULL,
        oi_change_1m INTEGER NOT NULL,
        oi_change_5m INTEGER NOT NULL,
        oi_change_15m INTEGER NOT NULL,
        oi_change_60m INTEGER NOT NULL,
        iv REAL NOT NULL,
        delta REAL NOT NULL,
        gamma REAL NOT NULL,
        theta REAL NOT NULL,
        vega REAL NOT NULL,
        spread_pct REAL NOT NULL,
        ob_imbalance REAL NOT NULL,
        next_3m_return REAL
      );
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_bars_lookup ON bars_1m(index_name, strike, option_type, timestamp_ms);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS signals_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_ms INTEGER NOT NULL,
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        action TEXT NOT NULL,
        confidence_pct REAL NOT NULL,
        htf_oi_reason TEXT NOT NULL,
        reasons TEXT NOT NULL,
        entry_premium REAL NOT NULL,
        sl_premium REAL NOT NULL,
        target_premium REAL NOT NULL,
        lot_size INTEGER NOT NULL,
        required_capital REAL NOT NULL,
        available_capital REAL NOT NULL,
        risk_ok INTEGER NOT NULL,
        risk_note TEXT NOT NULL,
        model_version TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS trade_orders (
        order_id TEXT PRIMARY KEY,
        correlation_id TEXT,
        timestamp_ms INTEGER NOT NULL,
        security_id TEXT,
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        option_type TEXT NOT NULL,
        side TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        filled_qty INTEGER NOT NULL,
        price REAL NOT NULL,
        status TEXT NOT NULL,
        mode TEXT NOT NULL,
        reason TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS positions (
        position_id TEXT PRIMARY KEY,
        security_id TEXT NOT NULL,
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        option_type TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        avg_entry_price REAL NOT NULL,
        current_ltp REAL NOT NULL,
        stop_loss_price REAL NOT NULL,
        target_price REAL NOT NULL,
        protective_sl_order_id TEXT,
        is_open INTEGER NOT NULL,
        exit_failed INTEGER DEFAULT 0,
        exit_failure_note TEXT DEFAULT '',
        mode TEXT NOT NULL,
        opened_at_ms INTEGER NOT NULL,
        closed_at_ms INTEGER,
        realized_pnl REAL NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS saved_strategies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        index_name TEXT NOT NULL,
        timeframe TEXT NOT NULL,
        win_rate REAL NOT NULL,
        net_pnl REAL NOT NULL,
        last_run_ms INTEGER NOT NULL
      );
    ''');

    // T5: Persistent Risk State table (Kill switch & daily limits survive restart)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS risk_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        kill_switch_active INTEGER NOT NULL DEFAULT 0,
        max_daily_loss_inr REAL NOT NULL DEFAULT 2500.0,
        max_concurrent_positions INTEGER NOT NULL DEFAULT 2,
        updated_at_ms INTEGER NOT NULL
      );
    ''');

    // T16: Append-only immutable Audit Log table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_ms INTEGER NOT NULL,
        ist_time TEXT NOT NULL,
        event_type TEXT NOT NULL,
        mode TEXT NOT NULL,
        summary TEXT NOT NULL,
        payload_json TEXT NOT NULL
      );
    ''');
  }

  /// T16: Append-only audit writer
  Future<void> appendAuditLog({
    required String eventType,
    required String mode,
    required String summary,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final istNow = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final istStr = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(istNow);
    await db.insert('audit_log', {
      'timestamp_ms': nowMs,
      'ist_time': istStr,
      'event_type': eventType,
      'mode': mode,
      'summary': summary,
      'payload_json': jsonEncode(payload),
    });
  }

  Future<List> getAuditLogs({int limit = 100}) async {
    final db = await database;
    return db.query('audit_log', orderBy: 'id DESC', limit: limit);
  }

  Future<String> exportAuditLogJson() async {
    final rows = await getAuditLogs(limit: 500);
    return const JsonEncoder.withIndent('  ').convert(rows);
  }

  /// T5.1: Load persisted RiskConfig including Kill Switch state
  Future<RiskConfig> loadPersistedRiskConfig() async {
    final db = await database;
    final rows = await db.query('risk_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) {
      return const RiskConfig();
    }
    final r = rows.first;
    return RiskConfig(
      killSwitchActive: ((r['kill_switch_active'] ?? 0) as int) == 1,
      maxDailyLossInr: ((r['max_daily_loss_inr'] ?? 2500.0) as num).toDouble(),
      maxConcurrentPositions:
          ((r['max_concurrent_positions'] ?? 2) as num).toInt(),
    );
  }

  /// T5.1: Save Kill Switch and Risk Limits persistently
  Future<void> savePersistedRiskConfig(RiskConfig cfg) async {
    final db = await database;
    await db.insert(
      'risk_state',
      {
        'id': 1,
        'kill_switch_active': cfg.killSwitchActive ? 1 : 0,
        'max_daily_loss_inr': cfg.maxDailyLossInr,
        'max_concurrent_positions': cfg.maxConcurrentPositions,
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// T5.2: Compute today's net realized P&L (wins + losses) from closed positions keyed to IST trading date
  Future<double> computeTodayNetRealizedPnlIst({String? mode}) async {
    final db = await database;
    final istNow = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final istMidnightUtc = DateTime.utc(istNow.year, istNow.month, istNow.day)
        .subtract(const Duration(hours: 5, minutes: 30));
    final startOfIstDayMs = istMidnightUtc.millisecondsSinceEpoch;

    final whereClause = mode != null
        ? 'is_open = 0 AND closed_at_ms >= ? AND mode = ?'
        : 'is_open = 0 AND closed_at_ms >= ?';
    final args = mode != null ? [startOfIstDayMs, mode] : [startOfIstDayMs];

    final rows = await db.query(
      'positions',
      columns: ['realized_pnl'],
      where: whereClause,
      whereArgs: args,
    );

    double netPnl = 0.0;
    for (final r in rows) {
      netPnl += ((r['realized_pnl'] ?? 0.0) as num).toDouble();
    }
    return netPnl;
  }

  Future<void> insertOneMinBar(OneMinEnrichedBar bar) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('bars_1m', bar.toMap());

      final threeMinAgoStart = bar.timestampMs - (4 * 60 * 1000);
      final threeMinAgoEnd = bar.timestampMs - (2 * 60 * 1000);
      final priorRows = await txn.query(
        'bars_1m',
        columns: ['id', 'close'],
        where:
            'index_name = ? AND strike = ? AND option_type = ? AND next_3m_return IS NULL AND timestamp_ms BETWEEN ? AND ?',
        whereArgs: [
          bar.indexName,
          bar.strike,
          bar.optionType,
          threeMinAgoStart,
          threeMinAgoEnd,
        ],
        limit: 1,
      );

      if (priorRows.isNotEmpty) {
        final priorId = priorRows.first['id'] as int;
        final priorClose = (priorRows.first['close'] as num).toDouble();
        if (priorClose > 0) {
          final retPct = ((bar.close - priorClose) / priorClose) * 100.0;
          await txn.update(
            'bars_1m',
            {'next_3m_return': retPct},
            where: 'id = ?',
            whereArgs: [priorId],
          );
        }
      }
    });
  }

  Future<List<OneMinEnrichedBar>> getRecentBars({
    required String indexName,
    int? strike,
    String? optionType,
    int limit = 240,
  }) async {
    final db = await database;
    final whereClauses = <String>['index_name = ?'];
    final args = <dynamic>[indexName];

    if (strike != null) {
      whereClauses.add('strike = ?');
      args.add(strike);
    }
    if (optionType != null) {
      whereClauses.add('option_type = ?');
      args.add(optionType);
    }

    final rows = await db.query(
      'bars_1m',
      where: whereClauses.join(' AND '),
      whereArgs: args,
      orderBy: 'timestamp_ms DESC',
      limit: limit,
    );
    return rows.reversed.map(OneMinEnrichedBar.fromMap).toList();
  }

  Future<List<OneMinEnrichedBar>> getFiveDayRecalibrationDataset() async {
    final db = await database;
    final cutoffMs =
        DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final rows = await db.query(
      'bars_1m',
      where: 'timestamp_ms >= ? AND next_3m_return IS NOT NULL',
      whereArgs: [cutoffMs],
      orderBy: 'timestamp_ms ASC',
      limit: 25000,
    );
    return rows.map(OneMinEnrichedBar.fromMap).toList();
  }

  Future<void> logSignal(AiSignal signal) async {
    final db = await database;
    await db.insert('signals_log', signal.toMap());
  }

  Future<List> getRecentSignals({int limit = 30}) async {
    final db = await database;
    return db.query('signals_log', orderBy: 'timestamp_ms DESC', limit: limit);
  }

  Future<void> saveOrder(TradeOrder order) async {
    final db = await database;
    await db.insert(
      'trade_orders',
      order.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<TradeOrder>> getOrders({String? mode, int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'trade_orders',
      where: mode != null ? 'mode = ?' : null,
      whereArgs: mode != null ? [mode] : null,
      orderBy: 'timestamp_ms DESC',
      limit: limit,
    );
    return rows.map(TradeOrder.fromMap).toList();
  }

  Future<void> upsertPosition(PositionRecord pos) async {
    final db = await database;
    await db.insert(
      'positions',
      pos.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<PositionRecord>> getPositions({
    required bool isOpen,
    String? mode,
  }) async {
    final db = await database;
    final clauses = <String>['is_open = ?'];
    final args = <dynamic>[isOpen ? 1 : 0];
    if (mode != null) {
      clauses.add('mode = ?');
      args.add(mode);
    }
    final rows = await db.query(
      'positions',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'opened_at_ms DESC',
    );
    return rows.map(PositionRecord.fromMap).toList();
  }

  Future<void> saveStrategyResult({
    required String name,
    required String indexName,
    required String timeframe,
    required double winRate,
    required double netPnl,
  }) async {
    final db = await database;
    await db.insert('saved_strategies', {
      'name': name,
      'index_name': indexName,
      'timeframe': timeframe,
      'win_rate': winRate,
      'net_pnl': netPnl,
      'last_run_ms': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List> getSavedStrategies() async {
    final db = await database;
    return db.query('saved_strategies', orderBy: 'last_run_ms DESC', limit: 20);
  }

  Future<double> getDatabaseSizeMb() async {
    final dbFolder = await getDatabasesPath();
    final file = File(p.join(dbFolder, 'ai_options_forever_v2.db'));
    if (!await file.exists()) return 0.1;
    final bytes = await file.length();
    return bytes / (1024.0 * 1024.0);
  }
}
