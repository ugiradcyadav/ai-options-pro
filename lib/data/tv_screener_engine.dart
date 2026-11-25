import 'dart:convert';
import 'package:http/http.dart' as http;

class TvScannerStock {
  final String symbol;
  final String description;
  final double close;
  final double changePct;
  final double volume;
  final double relVolume;
  final double? rsi14;
  final String sector;
  final double recommendAll; // -1..+1

  const TvScannerStock({
    required this.symbol,
    required this.description,
    required this.close,
    required this.changePct,
    required this.volume,
    required this.relVolume,
    required this.rsi14,
    required this.sector,
    required this.recommendAll,
  });

  String get ratingLabel {
    if (recommendAll >= 0.5) return 'STRONG BUY';
    if (recommendAll >= 0.1) return 'BUY';
    if (recommendAll <= -0.5) return 'STRONG SELL';
    if (recommendAll <= -0.1) return 'SELL';
    return 'NEUTRAL';
  }
}

class TvScreenerEngine {
  static final TvScreenerEngine instance = TvScreenerEngine._();
  TvScreenerEngine._();

  static const String _scanUrl = 'https://scanner.tradingview.com/india/scan';

  List<TvScannerStock> lastResults = [];
  int lastFetchedMs = 0;
  String lastError = '';

  Future<List<TvScannerStock>> fetchTopNseMovers({
    String mode = 'GAINERS', // 'GAINERS' | 'LOSERS' | 'VOLUME'
    int limit = 15,
  }) async {
    final sortBy = mode == 'VOLUME' ? 'relative_volume_10d_calc' : 'change';
    final sortOrder = mode == 'LOSERS' ? 'asc' : 'desc';

    final payload = {
      'filter': [
        {'left': 'exchange', 'operation': 'equal', 'right': 'NSE'},
        {'left': 'type', 'operation': 'equal', 'right': 'stock'},
        {'left': 'volume', 'operation': 'greater', 'right': 500000},
        {'left': 'close', 'operation': 'greater', 'right': 50},
      ],
      'options': {'lang': 'en'},
      'markets': ['india'],
      'symbols': {'query': {'types': []}, 'tickers': []},
      'columns': [
        'name',
        'description',
        'close',
        'change',
        'volume',
        'relative_volume_10d_calc',
        'RSI',
        'sector',
        'Recommend.All',
      ],
      'sort': {'sortBy': sortBy, 'sortOrder': sortOrder},
      'range': [0, limit],
    };

    try {
      final resp = await http
          .post(
            Uri.parse(_scanUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0 (Linux; Android 14)',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 7));

      if (resp.statusCode != 200) {
        lastError = 'Screener HTTP ${resp.statusCode}';
        return [];
      }

      final decoded = jsonDecode(resp.body);
      final data = decoded['data'] as List? ?? [];
      final out = <TvScannerStock>[];

      for (final item in data) {
        if (item is! Map) continue;
        final d = item['d'] as List? ?? [];
        if (d.length < 9) continue;
        out.add(TvScannerStock(
          symbol: (d[0] ?? '').toString(),
          description: (d[1] ?? '').toString(),
          close: ((d[2] ?? 0) as num).toDouble(),
          changePct: ((d[3] ?? 0) as num).toDouble(),
          volume: ((d[4] ?? 0) as num).toDouble(),
          relVolume: ((d[5] ?? 0) as num).toDouble(),
          rsi14: d[6] is num ? (d[6] as num).toDouble() : null,
          sector: (d[7] ?? 'NSE').toString(),
          recommendAll: ((d[8] ?? 0) as num).toDouble(),
        ));
      }

      lastResults = out;
      lastFetchedMs = DateTime.now().millisecondsSinceEpoch;
      lastError = '';
      return out;
    } catch (_) {
      lastError = 'Screener network timeout.';
      return [];
    }
  }
}
