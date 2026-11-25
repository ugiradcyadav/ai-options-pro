import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;

class ParticipantRow {
  final String participant; // 'FII' | 'DII' | 'Pro' | 'Client'
  final int futIndexLong;
  final int futIndexShort;
  final int optCallLong;
  final int optCallShort;
  final int optPutLong;
  final int optPutShort;

  const ParticipantRow({
    required this.participant,
    required this.futIndexLong,
    required this.futIndexShort,
    required this.optCallLong,
    required this.optCallShort,
    required this.optPutLong,
    required this.optPutShort,
  });

  int get netIndexFutures => futIndexLong - futIndexShort;
  int get netIndexCalls => optCallLong - optCallShort;
  int get netIndexPuts => optPutLong - optPutShort;

  double get futLongRatioPct {
    final tot = futIndexLong + futIndexShort;
    return tot > 0 ? (futIndexLong / tot) * 100.0 : 50.0;
  }
}

class ParticipantOiSnapshot {
  final String tradingDateLabel; // e.g. 25-11-2026
  final List<ParticipantRow> rows;
  final int fetchedAtMs;
  final String summaryNote;

  const ParticipantOiSnapshot({
    required this.tradingDateLabel,
    required this.rows,
    required this.fetchedAtMs,
    required this.summaryNote,
  });

  static const empty = ParticipantOiSnapshot(
    tradingDateLabel: '',
    rows: [],
    fetchedAtMs: 0,
    summaryNote: 'NO DATA — Official NSE Participant OI not loaded yet.',
  );

  bool get hasData => rows.isNotEmpty;

  ParticipantRow? get fii => _find('FII');
  ParticipantRow? get dii => _find('DII');
  ParticipantRow? get pro => _find('PRO');
  ParticipantRow? get client => _find('CLIENT');

  ParticipantRow? _find(String key) {
    for (final r in rows) {
      if (r.participant.toUpperCase() == key) return r;
    }
    return null;
  }
}

/// Fetches official NSE Clearing Participant-Wise OI CSV (FII / DII / Pro / Client)
class ParticipantOiEngine {
  static final ParticipantOiEngine instance = ParticipantOiEngine._();
  ParticipantOiEngine._();

  ParticipantOiSnapshot current = ParticipantOiSnapshot.empty;
  bool _inFlight = false;
  String lastError = '';

  static ParticipantOiSnapshot? parseNseCsv(String csvBody, String dateLabel) {
    final lines = csvBody
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 4) return null;

    final parsed = <ParticipantRow>[];
    int parseIntCol(List<String> cols, int idx) {
      if (idx >= cols.length) return 0;
      final clean = cols[idx].replaceAll('"', '').replaceAll(',', '').trim();
      return int.tryParse(clean) ?? (double.tryParse(clean)?.round() ?? 0);
    }

    for (final line in lines) {
      final cols = line.split(',');
      if (cols.length < 9) continue;
      final type = cols[0].replaceAll('"', '').trim();
      final upper = type.toUpperCase();
      if (upper != 'FII' &&
          upper != 'DII' &&
          upper != 'PRO' &&
          upper != 'CLIENT') {
        continue;
      }
      parsed.add(ParticipantRow(
        participant: type,
        futIndexLong: parseIntCol(cols, 1),
        futIndexShort: parseIntCol(cols, 2),
        optCallLong: parseIntCol(cols, 5),
        optPutLong: parseIntCol(cols, 6),
        optCallShort: parseIntCol(cols, 7),
        optPutShort: parseIntCol(cols, 8),
      ));
    }

    if (parsed.isEmpty) return null;

    ParticipantRow? fiiRow;
    for (final r in parsed) {
      if (r.participant.toUpperCase() == 'FII') {
        fiiRow = r;
        break;
      }
    }

    String note = 'NSE EOD ($dateLabel)';
    if (fiiRow != null) {
      final pct = fiiRow.futLongRatioPct;
      final posture = pct >= 55
          ? 'FII Bullish'
          : (pct <= 40 ? 'FII Heavily Short (Short-Cover Risk)' : 'FII Neutral/Bearish');
      note =
          'NSE EOD $dateLabel • FII Long ${pct.toStringAsFixed(1)}% (Net Fut ${fiiRow.netIndexFutures >= 0 ? "+" : ""}${fiiRow.netIndexFutures}) • $posture';
    }

    return ParticipantOiSnapshot(
      tradingDateLabel: dateLabel,
      rows: parsed,
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      summaryNote: note,
    );
  }

  /// Auto-walks back up to 7 calendar days to find the latest official NSE EOD CSV
  Future<ParticipantOiSnapshot> refreshLatest({bool force = false}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        current.hasData &&
        (nowMs - current.fetchedAtMs) < 300000) {
      return current;
    }
    if (_inFlight) return current;
    _inFlight = true;

    try {
      final nowIst =
          DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));

      for (int back = 0; back < 7; back++) {
        final d = nowIst.subtract(Duration(days: back));
        if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
          continue;
        }
        final ddmmyyyy = DateFormat('ddMMyyyy').format(d);
        final displayDate = DateFormat('dd-MMM-yyyy').format(d);
        final url = Uri.parse(
            'https://nsearchives.nseindia.com/content/nsccl/fao_participant_oi_$ddmmyyyy.csv');

        try {
          final resp = await http.get(
            url,
            headers: const {
              'User-Agent': 'Mozilla/5.0 (Linux; Android 13) SadhuAI/5.1',
              'Accept': 'text/csv,text/plain,*/*',
              'Referer': 'https://www.nseindia.com/',
            },
          ).timeout(const Duration(seconds: 6));

          if (resp.statusCode == 200 && resp.body.contains('FII')) {
            final snap = parseNseCsv(resp.body, displayDate);
            if (snap != null) {
              current = snap;
              lastError = '';
              return current;
            }
          }
        } catch (_) {}
      }

      lastError = 'NSE Participant OI archive unavailable right now.';
      return current;
    } finally {
      _inFlight = false;
    }
  }
}
