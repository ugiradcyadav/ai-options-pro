import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../core/models.dart';

class ForeverDatabase {
  static final ForeverDatabase instance = ForeverDatabase._();
  ForeverDatabase._();

  static const int _dbVersion = 3;
  static const String _dbFileName = 'ai_options_pro_forever.db';
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final fullPath = join(dbPath, _dbFileName);
    _db = await openDatabase(
      fullPath,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createCoreTables(db);
  }

  Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      // WP-2 Migration v3: Drop and recreate synthetic bar/signal/strategy tables empty
      await db.execute('DROP TABLE IF EXISTS one_min_bars');
      await db.execute('DROP TABLE IF EXISTS bars_1m');
      await db.execute('DROP TABLE IF EXISTS signals_log');
      await db.execute('DROP TABLE IF EXISTS saved_strategies');

      // Tag any existing legacy positions & trade_orders as legacy_unverified
      try {
        await db.execute(
            'ALTER TABLE positions ADD COLUMN legacy_unverified INTEGER DEFAULT 1');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE positions ADD COLUMN stop_loss_price REAL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE positions ADD COLUMN target_price REAL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE positions ADD COLUMN trading_symbol TEXT DEFAULT ""');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE positions ADD COLUMN opened_at_ms INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE positions ADD COLUMN closed_at_ms INTEGER');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE trade_orders ADD COLUMN filled_qty INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE trade_orders ADD COLUMN client_correlation_id TEXT DEFAULT ""');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE trade_orders ADD COLUMN security_id TEXT DEFAULT ""');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE trade_orders ADD COLUMN trading_symbol TEXT DEFAULT ""');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE trade_orders ADD COLUMN limit_price REAL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE trade_orders ADD COLUMN legacy_unverified INTEGER DEFAULT 1');
      } catch (_) {}

      await _createCoreTables(db);
    }
  }

  Future<void> _createCoreTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS one_min_bars (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contract_id TEXT NOT NULL,
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
        oi_change_1m INTEGER,
        oi_change_5m INTEGER,
        oi_change_15m INTEGER,
        oi_change_60m INTEGER,
        iv REAL,
        delta REAL NOT NULL,
        gamma REAL NOT NULL,
        theta REAL NOT NULL,
        vega REAL NOT NULL,
        spread_pct REAL,
        order_book_imbalance REAL,
        next_3m_return REAL DEFAULT 0,
        UNIQUE(contract_id, timestamp_ms)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS chain_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contract_id TEXT NOT NULL,
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        option_type TEXT NOT NULL,
        timestamp_ms INTEGER NOT NULL,
        ltp REAL NOT NULL,
        bid REAL,
        ask REAL,
        volume INTEGER NOT NULL,
        oi_lots INTEGER NOT NULL,
        source TEXT NOT NULL,
        UNIQUE(contract_id, timestamp_ms)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_chain_snap_lookup ON chain_snapshots(contract_id, timestamp_ms DESC)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS trade_orders (
        order_id TEXT PRIMARY KEY,
        client_correlation_id TEXT DEFAULT '',
        timestamp_ms INTEGER NOT NULL,
        security_id TEXT DEFAULT '',
        trading_symbol TEXT DEFAULT '',
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        option_type TEXT NOT NULL,
        side TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        filled_qty INTEGER NOT NULL DEFAULT 0,
        price REAL NOT NULL,
        limit_price REAL DEFAULT 0,
        status TEXT NOT NULL,
        mode TEXT NOT NULL,
        reason TEXT NOT NULL,
        legacy_unverified INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS positions (
        position_id TEXT PRIMARY KEY,
        security_id TEXT NOT NULL,
        trading_symbol TEXT DEFAULT '',
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        option_type TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        avg_entry_price REAL NOT NULL,
        current_ltp REAL NOT NULL,
        stop_loss_price REAL NOT NULL,
        target_price REAL NOT NULL,
        opened_at_ms INTEGER NOT NULL,
        closed_at_ms INTEGER,
        status TEXT NOT NULL,
        mode TEXT NOT NULL,
        realized_pnl REAL NOT NULL DEFAULT 0,
        legacy_unverified INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS signals_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_ms INTEGER NOT NULL,
        index_name TEXT NOT NULL,
        expiry TEXT NOT NULL,
        strike INTEGER NOT NULL,
        action TEXT NOT NULL,
        confidence_pct REAL NOT NULL,
        entry_premium REAL NOT NULL,
        stop_loss_premium REAL NOT NULL,
        target_premium REAL NOT NULL,
        risk_note TEXT NOT NULL,
        model_version TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS risk_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        max_risk_per_trade_pct REAL NOT NULL,
        max_capital_outlay_pct REAL NOT NULL,
        max_daily_loss_inr REAL NOT NULL,
        max_concurrent_positions INTEGER NOT NULL,
        kill_switch_active INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS saved_strategies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        config_json TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_ms INTEGER NOT NULL,
        category TEXT NOT NULL,
        message TEXT NOT NULL
      )
    ''');

    // WP-9: Enforce append-only immutability on audit_log via SQLite triggers
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_audit_log_no_update
      BEFORE UPDATE ON audit_log
      BEGIN
        SELECT RAISE(ABORT, 'audit_log is append-only');
      END;
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_audit_log_no_delete
      BEFORE DELETE ON audit_log
      BEGIN
        SELECT RAISE(ABORT, 'audit_log is append-only');
      END;
    ''');
  }

  Future<int> getDatabaseFileSizeBytes() async {
    final dbPath = await getDatabasesPath();
    final f = File(join(dbPath, _dbFileName));
    if (await f.exists()) {
      return f.length();
    }
    return 0;
  }

  Future<void> insertOneMinBar(OneMinEnrichedBar bar) async {
    final db = await database;
    await db.insert(
      'one_min_bars',
      bar.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<OneMinEnrichedBar>> getRecentBars({
    required String indexName,
    String? contractId,
    String? optionType,
    int limit = 200,
  }) async {
    final db = await database;
    final whereParts = <String>['index_name = ?'];
    final whereArgs = <Object>[indexName];
    if (contractId != null && contractId.isNotEmpty) {
      whereParts.add('contract_id = ?');
      whereArgs.add(contractId);
    }
    if (optionType != null && optionType.isNotEmpty) {
      whereParts.add('option_type = ?');
      whereArgs.add(optionType);
    }
    final rows = await db.query(
      'one_min_bars',
      where: whereParts.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'timestamp_ms DESC',
      limit: limit,
    );
    return rows.map((r) => OneMinEnrichedBar.fromMap(r)).toList();
  }

  /// WP-3: Persist raw 1-minute contract snapshot for real 5m/15m/60m OI differencing
  Future<void> insertChainSnapshot({
    required String contractId,
    required String indexName,
    required String expiry,
    required int strike,
    required String optionType,
    required int timestampMs,
    required double ltp,
    double? bid,
    double? ask,
    required int volume,
    required int oiLots,
    required String source,
  }) async {
    final db = await database;
    final minuteBucket = (timestampMs ~/ 60000) * 60000;
    await db.insert(
      'chain_snapshots',
      {
        'contract_id': contractId,
        'index_name': indexName,
        'expiry': expiry,
        'strike': strike,
        'option_type': optionType,
        'timestamp_ms': minuteBucket,
        'ltp': ltp,
        'bid': bid,
        'ask': ask,
        'volume': volume,
        'oi_lots': oiLots,
        'source': source,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// WP-3: Computes real OI difference over [minutesAgo]. Returns null if no real snapshot exists that far back.
  Future<int?> computeRealOiChange({
    required String contractId,
    required int currentOiLots,
    required int nowMs,
    required int minutesAgo,
  }) async {
    final db = await database;
    final targetMs = nowMs - (minutesAgo * 60000);
    final toleranceMs = 120000; // ±2 minutes window
    final rows = await db.query(
      'chain_snapshots',
      columns: ['oi_lots', 'timestamp_ms'],
      where: 'contract_id = ? AND timestamp_ms BETWEEN ? AND ?',
      whereArgs: [contractId, targetMs - toleranceMs, targetMs + toleranceMs],
      orderBy: 'ABS(timestamp_ms - ?) ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final pastOi = ((rows.first['oi_lots'] ?? 0) as num).toInt();
    return currentOiLots - pastOi;
  }

  Future<void> saveOrder(TradeOrder order) async {
    final db = await database;
    await db.insert(
      'trade_orders',
      order.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<TradeOrder>> getRecentOrders({int limit = 100}) async {
    final db = await database;
    final rows = await db.query(
      'trade_orders',
      orderBy: 'timestamp_ms DESC',
      limit: limit,
    );
    return rows.map((r) => TradeOrder.fromMap(r)).toList();
  }

  Future<void> upsertPosition(PositionRecord pos) async {
    final db = await database;
    await db.insert(
      'positions',
      pos.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<PositionRecord>> getAllPositions() async {
    final db = await database;
    final rows = await db.query('positions', orderBy: 'opened_at_ms DESC');
    return rows.map((r) => PositionRecord.fromMap(r)).toList();
  }

  /// WP-6: Realized net P&L of positions closed today (IST, UTC+5:30)
  Future<double> computeTodayNetRealizedPnlIst({int? nowMsOverride}) async {
    final db = await database;
    final nowUtc = DateTime.fromMillisecondsSinceEpoch(
      nowMsOverride ?? DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    );
    final istNow = nowUtc.add(const Duration(hours: 5, minutes: 30));
    final istMidnightUtc =
        DateTime.utc(istNow.year, istNow.month, istNow.day)
            .subtract(const Duration(hours: 5, minutes: 30));
    final startMs = istMidnightUtc.millisecondsSinceEpoch;

    final rows = await db.query(
      'positions',
      columns: ['realized_pnl'],
      where: "status = 'CLOSED' AND closed_at_ms >= ? AND legacy_unverified = 0",
      whereArgs: [startMs],
    );
    double sum = 0.0;
    for (final r in rows) {
      sum += ((r['realized_pnl'] ?? 0) as num).toDouble();
    }
    return sum;
  }

  Future<void> saveSignal(AiSignal sig) async {
    final db = await database;
    await db.insert('signals_log', {
      'timestamp_ms': sig.timestampMs,
      'index_name': sig.index.label,
      'expiry': sig.expiry,
      'strike': sig.strike,
      'action': sig.action.label,
      'confidence_pct': sig.confidencePct,
      'entry_premium': sig.entryPremium,
      'stop_loss_premium': sig.stopLossPremium,
      'target_premium': sig.targetPremium,
      'risk_note': sig.riskNote,
      'model_version': sig.modelVersion,
    });
  }

  Future<List<Map<String, dynamic>>> getRecentSignals(
      {int limit = 30}) async {
    final db = await database;
    final rows = await db.query(
      'signals_log',
      orderBy: 'timestamp_ms DESC',
      limit: limit,
    );
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> savePersistedRiskConfig(RiskConfig cfg) async {
    final db = await database;
    final map = cfg.toMap();
    map['id'] = 1;
    await db.insert(
      'risk_config',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<RiskConfig> loadPersistedRiskConfig() async {
    final db = await database;
    final rows = await db.query('risk_config', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return const RiskConfig();
    return RiskConfig.fromMap(rows.first);
  }

  Future<void> logAuditEvent({
    required String category,
    required String message,
  }) async {
    final db = await database;
    await db.insert('audit_log', {
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      'category': category,
      'message': message,
    });
  }

  Future<List<Map<String, dynamic>>> getAuditLogs(
      {int limit = 100}) async {
    final db = await database;
    final rows = await db.query(
      'audit_log',
      orderBy: 'timestamp_ms DESC',
      limit: limit,
    );
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<List<Map<String, dynamic>>> getSavedStrategies() async {
    final db = await database;
    final rows = await db.query('saved_strategies', orderBy: 'updated_at_ms DESC');
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }
}
