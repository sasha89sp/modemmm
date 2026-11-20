import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../models/modem_models.dart';
import '../models/scenario_models.dart';
import 'app_paths.dart';

/// Локальное хранилище SQLite (UserData/modem_data.db):
/// SMS со всех SIM-карт с папками и «надгробиями», сценарии, прогоны, журналы и экспорт CSV.
class DatabaseService {
  Database? _db;

  Database get db {
    final instance = _db;
    if (instance == null) {
      throw StateError('База данных SQLite не инициализирована.');
    }
    return instance;
  }

  Future<void> init() async {
    await AppPaths.ensureDirectories();
    _db = sqlite3.open(AppPaths.databaseFile);
    db.execute('PRAGMA journal_mode = WAL;');

    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fingerprint TEXT UNIQUE NOT NULL,
        sim_imsi TEXT NOT NULL DEFAULT '',
        folder TEXT NOT NULL DEFAULT 'inbox',
        prev_folder TEXT NOT NULL DEFAULT 'inbox',
        address TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '',
        timestamp TEXT NOT NULL DEFAULT '',
        is_read INTEGER NOT NULL DEFAULT 0,
        modem_index INTEGER,
        delivery_status TEXT NOT NULL DEFAULT ''
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_tombstones (
        fingerprint TEXT PRIMARY KEY NOT NULL,
        deleted_at TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS scenarios (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        stop_on_error INTEGER NOT NULL DEFAULT 0,
        auto_run INTEGER NOT NULL DEFAULT 0,
        operator_filter TEXT NOT NULL DEFAULT '',
        steps_json TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS scenario_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at TEXT NOT NULL,
        scenario_name TEXT NOT NULL,
        operator_name TEXT NOT NULL,
        phone_number TEXT NOT NULL DEFAULT '',
        imei TEXT NOT NULL DEFAULT '',
        imsi TEXT NOT NULL DEFAULT '',
        first_balance REAL,
        last_balance REAL,
        balance_diff REAL,
        balance_match_status TEXT NOT NULL DEFAULT 'Н/Д',
        status TEXT NOT NULL DEFAULT 'УСПЕШНО',
        duration_sec INTEGER NOT NULL DEFAULT 0,
        error_text TEXT NOT NULL DEFAULT '',
        step_summary TEXT NOT NULL DEFAULT ''
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS operation_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL,
        category TEXT NOT NULL,
        action TEXT NOT NULL,
        result TEXT NOT NULL,
        details TEXT NOT NULL DEFAULT ''
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS system_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL
      );
    ''');

    _seedDefaultScenarioIfEmpty();
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  void _seedDefaultScenarioIfEmpty() {
    final res = db.select('SELECT COUNT(*) AS cnt FROM scenarios');
    final count = (res.first['cnt'] as int?) ?? 0;
    if (count > 0) return;

    final sample = ScenarioDefinition(
      id: 'default-balance-check',
      name: 'Проверка номера и сверка баланса',
      stopOnError: false,
      autoRunOnRegister: false,
      operatorFilter: '',
      steps: const [
        ScenarioStep(
          id: 'st-1',
          type: ScenarioStepType.detectOwnNumberUssd,
          title: 'Номер и первичный баланс',
          ussdCode: '*100#',
          ussdDcs: 15,
        ),
        ScenarioStep(
          id: 'st-2',
          type: ScenarioStepType.checkBalanceUssd,
          title: 'Первая проверка баланса',
          ussdCode: '*100#',
          ussdDcs: 15,
          waitSmsIfNoBalance: true,
          smsWaitTimeoutSec: 25,
          smsSenderFilter: '',
        ),
        ScenarioStep(
          id: 'st-3',
          type: ScenarioStepType.pause,
          title: 'Пауза перед повторной проверкой',
          pauseSec: 5,
        ),
        ScenarioStep(
          id: 'st-4',
          type: ScenarioStepType.checkBalanceUssd,
          title: 'Контрольная сверка баланса',
          ussdCode: '*100#',
          ussdDcs: 15,
          waitSmsIfNoBalance: false,
        ),
      ],
    );
    upsertScenario(sample);
  }

  static String nowIso() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  // ---------------- SMS + Tombstones ----------------

  static String buildSmsFingerprint({
    required String imsi,
    required String folder,
    required String address,
    required String timestamp,
    required String body,
  }) {
    final raw = '$imsi|$folder|${address.trim()}|${timestamp.trim()}|${body.trim()}';
    return base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
  }

  bool isTombstoned(String fingerprint) {
    final rows = db.select(
      'SELECT 1 FROM deleted_tombstones WHERE fingerprint = ? LIMIT 1',
      [fingerprint],
    );
    return rows.isNotEmpty;
  }

  /// Сохраняет SMS, если оно не в таблице надгробий и ещё не существует.
  /// Возвращает true, если сообщение действительно новое.
  bool insertSmsIfNew({
    required String simImsi,
    required String folder,
    required String address,
    required String body,
    required String timestamp,
    bool isRead = false,
    int? modemIndex,
    String deliveryStatus = '',
  }) {
    final fp = buildSmsFingerprint(
      imsi: simImsi,
      folder: folder,
      address: address,
      timestamp: timestamp,
      body: body,
    );
    if (isTombstoned(fp)) return false;

    final existing = db.select(
      'SELECT id FROM messages WHERE fingerprint = ? LIMIT 1',
      [fp],
    );
    if (existing.isNotEmpty) return false;

    db.execute(
      '''INSERT INTO messages
         (fingerprint, sim_imsi, folder, prev_folder, address, body, timestamp, is_read, modem_index, delivery_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        fp,
        simImsi,
        folder,
        folder,
        address,
        body,
        timestamp,
        isRead ? 1 : 0,
        modemIndex,
        deliveryStatus,
      ],
    );
    return true;
  }

  List<SmsRecord> getMessages({String? folder, String search = ''}) {
    final where = <String>[];
    final args = <Object?>[];

    if (folder != null && folder.isNotEmpty) {
      where.add('folder = ?');
      args.add(folder);
    }
    if (search.trim().isNotEmpty) {
      where.add('(address LIKE ? OR body LIKE ? OR sim_imsi LIKE ?)');
      final q = '%${search.trim()}%';
      args.addAll([q, q, q]);
    }

    final sql =
        'SELECT * FROM messages ${where.isNotEmpty ? 'WHERE ${where.join(' AND ')}' : ''} ORDER BY id DESC LIMIT 1000';
    final rows = db.select(sql, args);
    return rows.map(_mapSmsRow).toList();
  }

  int getUnreadInboxCount() {
    final rows = db.select(
      "SELECT COUNT(*) AS cnt FROM messages WHERE folder = 'inbox' AND is_read = 0",
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  void markSmsRead(List<int> ids, {bool read = true}) {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    db.execute(
      'UPDATE messages SET is_read = ? WHERE id IN ($placeholders)',
      [read ? 1 : 0, ...ids],
    );
  }

  void moveSmsToTrash(List<int> ids) {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    db.execute(
      "UPDATE messages SET prev_folder = CASE WHEN folder != 'trash' THEN folder ELSE prev_folder END, folder = 'trash', is_read = 1 WHERE id IN ($placeholders)",
      ids,
    );
  }

  void restoreSmsFromTrash(List<int> ids) {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    db.execute(
      "UPDATE messages SET folder = CASE WHEN prev_folder IN ('inbox','sent') THEN prev_folder ELSE 'inbox' END WHERE id IN ($placeholders)",
      ids,
    );
  }

  /// Окончательное удаление с записью «надгробий», чтобы сообщения с модема не вернулись.
  void deleteSmsPermanently(List<int> ids) {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = db.select(
      'SELECT fingerprint FROM messages WHERE id IN ($placeholders)',
      ids,
    );
    final ts = nowIso();
    for (final r in rows) {
      final fp = r['fingerprint']?.toString() ?? '';
      if (fp.isNotEmpty) {
        db.execute(
          'INSERT OR IGNORE INTO deleted_tombstones (fingerprint, deleted_at) VALUES (?, ?)',
          [fp, ts],
        );
      }
    }
    db.execute('DELETE FROM messages WHERE id IN ($placeholders)', ids);
  }

  SmsRecord _mapSmsRow(Row r) => SmsRecord(
        id: r['id'] as int,
        fingerprint: r['fingerprint'] as String,
        simImsi: r['sim_imsi'] as String,
        folder: r['folder'] as String,
        prevFolder: r['prev_folder'] as String,
        address: r['address'] as String,
        body: r['body'] as String,
        timestamp: r['timestamp'] as String,
        isRead: (r['is_read'] as int) == 1,
        modemIndex: r['modem_index'] as int?,
        deliveryStatus: r['delivery_status'] as String,
      );

  // ---------------- Scenarios ----------------

  List<ScenarioDefinition> getScenarios() {
    final rows = db.select('SELECT * FROM scenarios ORDER BY sort_order ASC, name ASC');
    return rows
        .map(
          (r) => ScenarioDefinition(
            id: r['id'] as String,
            name: r['name'] as String,
            stopOnError: (r['stop_on_error'] as int) == 1,
            autoRunOnRegister: (r['auto_run'] as int) == 1,
            operatorFilter: r['operator_filter'] as String,
            steps: ScenarioDefinition.decodeSteps(r['steps_json'] as String),
          ),
        )
        .toList();
  }

  void upsertScenario(ScenarioDefinition sc) {
    db.execute(
      '''INSERT INTO scenarios (id, name, stop_on_error, auto_run, operator_filter, steps_json)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           stop_on_error = excluded.stop_on_error,
           auto_run = excluded.auto_run,
           operator_filter = excluded.operator_filter,
           steps_json = excluded.steps_json''',
      [
        sc.id,
        sc.name,
        sc.stopOnError ? 1 : 0,
        sc.autoRunOnRegister ? 1 : 0,
        sc.operatorFilter,
        ScenarioDefinition.encodeSteps(sc.steps),
      ],
    );
  }

  void deleteScenario(String id) {
    db.execute('DELETE FROM scenarios WHERE id = ?', [id]);
  }

  // ---------------- Scenario Runs ----------------

  int insertScenarioRun(ScenarioRunRecord run) {
    db.execute(
      '''INSERT INTO scenario_runs (
        started_at, scenario_name, operator_name, phone_number, imei, imsi,
        first_balance, last_balance, balance_diff, balance_match_status,
        status, duration_sec, error_text, step_summary
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        run.startedAt,
        run.scenarioName,
        run.operatorName,
        run.phoneNumber,
        run.imei,
        run.imsi,
        run.firstBalance,
        run.lastBalance,
        run.balanceDiff,
        run.balanceMatchStatus,
        run.status,
        run.durationSec,
        run.errorText,
        run.stepSummary,
      ],
    );
    return db.lastInsertRowId;
  }

  List<ScenarioRunRecord> getScenarioRuns({bool ascending = false}) {
    final rows = db.select(
      'SELECT * FROM scenario_runs ORDER BY id ${ascending ? 'ASC' : 'DESC'} LIMIT 2000',
    );
    return rows
        .map(
          (r) => ScenarioRunRecord(
            id: r['id'] as int,
            startedAt: r['started_at'] as String,
            scenarioName: r['scenario_name'] as String,
            operatorName: r['operator_name'] as String,
            phoneNumber: r['phone_number'] as String,
            imei: r['imei'] as String,
            imsi: r['imsi'] as String,
            firstBalance: (r['first_balance'] as num?)?.toDouble(),
            lastBalance: (r['last_balance'] as num?)?.toDouble(),
            balanceDiff: (r['balance_diff'] as num?)?.toDouble(),
            balanceMatchStatus: r['balance_match_status'] as String,
            status: r['status'] as String,
            durationSec: r['duration_sec'] as int,
            errorText: r['error_text'] as String,
            stepSummary: r['step_summary'] as String,
          ),
        )
        .toList();
  }

  // ---------------- Logs & CSV Export ----------------

  void logOperation(
    String category,
    String action,
    String result, [
    String details = '',
  ]) {
    db.execute(
      'INSERT INTO operation_logs (created_at, category, action, result, details) VALUES (?, ?, ?, ?, ?)',
      [nowIso(), category, action, result, details],
    );
  }

  void logSystem(String level, String message) {
    db.execute(
      'INSERT INTO system_logs (created_at, level, message) VALUES (?, ?, ?)',
      [nowIso(), level, message],
    );
    // Ограничиваем таблицу системного лога последними 5000 записями
    db.execute(
      'DELETE FROM system_logs WHERE id NOT IN (SELECT id FROM system_logs ORDER BY id DESC LIMIT 5000)',
    );
  }

  List<OperationLogEntry> getOperationLogs({int limit = 500}) {
    final rows = db.select(
      'SELECT * FROM operation_logs ORDER BY id DESC LIMIT ?',
      [limit],
    );
    return rows
        .map(
          (r) => OperationLogEntry(
            id: r['id'] as int,
            createdAt: r['created_at'] as String,
            category: r['category'] as String,
            action: r['action'] as String,
            result: r['result'] as String,
            details: r['details'] as String,
          ),
        )
        .toList();
  }

  List<SystemLogEntry> getSystemLogs({int limit = 500, String? level}) {
    final rows = level != null && level.isNotEmpty
        ? db.select(
            'SELECT * FROM system_logs WHERE level = ? ORDER BY id DESC LIMIT ?',
            [level, limit],
          )
        : db.select(
            'SELECT * FROM system_logs ORDER BY id DESC LIMIT ?',
            [limit],
          );
    return rows
        .map(
          (r) => SystemLogEntry(
            id: r['id'] as int,
            createdAt: r['created_at'] as String,
            level: r['level'] as String,
            message: r['message'] as String,
          ),
        )
        .toList();
  }

  void clearSystemLogs() => db.execute('DELETE FROM system_logs');

  Future<String> exportOperationsToCsv() async {
    await AppPaths.ensureDirectories();
    final rows = getOperationLogs(limit: 5000);
    final stamp = nowIso().replaceAll(RegExp(r'[: ]'), '_');
    final filePath = p.join(AppPaths.exportsDir, 'operations_$stamp.csv');

    String esc(String v) => '"${v.replaceAll('"', '""')}"';
    final sb = StringBuffer('\uFEFFID;Дата;Категория;Действие;Результат;Детали\r\n');
    for (final r in rows) {
      sb.writeln(
        '${r.id};${esc(r.createdAt)};${esc(r.category)};${esc(r.action)};${esc(r.result)};${esc(r.details)}',
      );
    }
    await File(filePath).writeAsString(sb.toString(), encoding: utf8);
    return filePath;
  }
}
