import 'dart:convert';
import 'package:http/http.dart' as http;

class MacroQuote {
  final String key;
  final String label;
  final String symbol;
  final String category; // 'FX' | 'YIELD' | 'COMMODITY' | 'GLOBAL_IDX'
  final double price;
  final double prevClose;
  final double changePct;
  final int marketTimeMs;
  final String unitPrefix;
  final String unitSuffix;

  const MacroQuote({
    required this.key,
    required this.label,
    required this.symbol,
    required this.category,
    required this.price,
    required this.prevClose,
    required this.changePct,
    required this.marketTimeMs,
    this.unitPrefix = '',
    this.unitSuffix = '',
  });

  String get formattedPrice =>
      '$unitPrefix${price.toStringAsFixed(price >= 1000 ? 0 : 2)}$unitSuffix';
}

class MacroSnapshot {
  final List<MacroQuote> quotes;
  final int fetchedAtMs;
  final String biasLabel; // 'RISK-ON' | 'RISK-OFF' | 'MIXED' | 'NO DATA'
  final List<String> activeFlags;

  const MacroSnapshot({
    required this.quotes,
    required this.fetchedAtMs,
    required this.biasLabel,
    required this.activeFlags,
  });

  static const empty = MacroSnapshot(
    quotes: [],
    fetchedAtMs: 0,
    biasLabel: 'NO DATA',
    activeFlags: [],
  );

  MacroQuote? byKey(String k) {
    for (final q in quotes) {
      if (q.key == k) return q;
    }
    return null;
  }
}

/// Fetches real near-real-time global macro cues: USD/INR, DXY, US10Y, Brent, Nasdaq/S&P Fut, Gold
class MacroDataEngine {
  static final MacroDataEngine instance = MacroDataEngine._();
  MacroDataEngine._();

  static const List<Map<String, String>> _instruments = [
    {
      'key': 'USDINR',
      'label': 'USD/INR',
      'sym': 'USDINR=X',
      'cat': 'FX',
      'pre': '₹',
      'suf': '',
    },
    {
      'key': 'DXY',
      'label': 'DXY',
      'sym': 'DX-Y.NYB',
      'cat': 'FX',
      'pre': '',
      'suf': '',
    },
    {
      'key': 'US10Y',
      'label': 'US 10Y',
      'sym': '^TNX',
      'cat': 'YIELD',
      'pre': '',
      'suf': '%',
    },
    {
      'key': 'BRENT',
      'label': 'BRENT',
      'sym': 'BZ=F',
      'cat': 'COMMODITY',
      'pre': '\$',
      'suf': '',
    },
    {
      'key': 'NQ',
      'label': 'NASDAQ FUT',
      'sym': 'NQ=F',
      'cat': 'GLOBAL_IDX',
      'pre': '',
      'suf': '',
    },
    {
      'key': 'ES',
      'label': 'S&P 500 FUT',
      'sym': 'ES=F',
      'cat': 'GLOBAL_IDX',
      'pre': '',
      'suf': '',
    },
    {
      'key': 'GOLD',
      'label': 'GOLD',
      'sym': 'GC=F',
      'cat': 'COMMODITY',
      'pre': '\$',
      'suf': '',
    },
  ];

  MacroSnapshot current = MacroSnapshot.empty;
  bool _inFlight = false;
  String lastError = '';

  Future<MacroSnapshot> refresh({bool force = false}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        current.quotes.isNotEmpty &&
        (nowMs - current.fetchedAtMs) < 30000) {
      return current;
    }
    if (_inFlight) return current;
    _inFlight = true;

    try {
      final futures = _instruments.map(_fetchSingleQuote).toList();
      final raw = await Future.wait(futures);
      final valid = raw.whereType<MacroQuote>().toList();

      if (valid.isEmpty) {
        lastError = 'Macro feeds unreachable right now.';
        return current;
      }

      lastError = '';
      current = _buildEvaluatedSnapshot(
        valid,
        DateTime.now().millisecondsSinceEpoch,
      );
      return current;
    } finally {
      _inFlight = false;
    }
  }

  Future<MacroQuote?> _fetchSingleQuote(
      Map<String, String> spec) async {
    final sym = spec['sym']!;
    final encoded = Uri.encodeComponent(sym);
    final url = Uri.parse(
        'https://query1.finance.yahoo.com/v8/finance/chart/$encoded?interval=5m&range=1d');
    try {
      final resp = await http.get(
        url,
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 13) SadhuAI/5.1',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      final resultList = body['chart']?['result'] as List?;
      if (resultList == null || resultList.isEmpty) return null;
      final meta = resultList.first['meta'] as Map?;
      if (meta == null) return null;

      final price = ((meta['regularMarketPrice'] ?? 0) as num).toDouble();
      final prev = ((meta['chartPreviousClose'] ??
              meta['previousClose'] ??
              price) as num)
          .toDouble();
      if (price <= 0) return null;

      final chgPct = prev > 0 ? ((price - prev) / prev) * 100.0 : 0.0;
      final mTimeSec = ((meta['regularMarketTime'] ?? 0) as num).toInt();

      return MacroQuote(
        key: spec['key']!,
        label: spec['label']!,
        symbol: sym,
        category: spec['cat']!,
        price: price,
        prevClose: prev,
        changePct: chgPct,
        marketTimeMs: mTimeSec > 0
            ? mTimeSec * 1000
            : DateTime.now().millisecondsSinceEpoch,
        unitPrefix: spec['pre'] ?? '',
        unitSuffix: spec['suf'] ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static MacroSnapshot _buildEvaluatedSnapshot(
      List<MacroQuote> quotes, int fetchedAtMs) {
    int riskScore = 0;
    final flags = <String>[];

    for (final q in quotes) {
      if (q.key == 'USDINR') {
        if (q.changePct >= 0.25) {
          riskScore -= 2;
          flags.add('INR Weak (${q.formattedPrice} +${q.changePct.toStringAsFixed(2)}%)');
        } else if (q.changePct <= -0.20) {
          riskScore += 1;
        }
      } else if (q.key == 'BRENT') {
        if (q.changePct >= 1.8) {
          riskScore -= 2;
          flags.add('Brent Spike (+${q.changePct.toStringAsFixed(1)}%)');
        } else if (q.changePct <= -1.5) {
          riskScore += 1;
        }
      } else if (q.key == 'US10Y') {
        if (q.changePct >= 1.5) {
          riskScore -= 1;
          flags.add('US10Y Rising (${q.formattedPrice})');
        }
      } else if (q.key == 'NQ' || q.key == 'ES') {
        if (q.changePct >= 0.5) {
          riskScore += 2;
        } else if (q.changePct <= -0.5) {
          riskScore -= 2;
          if (q.key == 'NQ') {
            flags.add('Nasdaq Fut Weak (${q.changePct.toStringAsFixed(2)}%)');
          }
        }
      } else if (q.key == 'DXY') {
        if (q.changePct >= 0.4) {
          riskScore -= 1;
          flags.add('Dollar Strong (+${q.changePct.toStringAsFixed(2)}%)');
        }
      }
    }

    final bias = riskScore >= 2
        ? 'RISK-ON'
        : (riskScore <= -2 ? 'RISK-OFF' : 'MIXED');
    if (flags.isEmpty) {
      flags.add('Global cues balanced — no macro shock detected.');
    }

    return MacroSnapshot(
      quotes: quotes,
      fetchedAtMs: fetchedAtMs,
      biasLabel: bias,
      activeFlags: flags,
    );
  }
}
