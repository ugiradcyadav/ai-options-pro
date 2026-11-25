import 'package:http/http.dart' as http;

class MarketNewsItem {
  final String source; // 'RBI' | 'NSE' | 'BSE'
  final String title;
  final String link;
  final String pubDateRaw;
  final int timestampMs;
  final bool isHighImpact;
  final String impactTag; // 'POLICY' | 'HEAVYWEIGHT' | 'F&O' | 'FILING'

  const MarketNewsItem({
    required this.source,
    required this.title,
    required this.link,
    required this.pubDateRaw,
    required this.timestampMs,
    required this.isHighImpact,
    required this.impactTag,
  });
}

/// Live official announcements aggregator: RBI Press Releases/Notifications + NSE Announcements + BSE Notices
class NewsWireEngine {
  static final NewsWireEngine instance = NewsWireEngine._();
  NewsWireEngine._();

  static const List<Map<String, String>> _feeds = [
    {'source': 'RBI', 'url': 'https://rbi.org.in/pressreleases_rss.xml'},
    {'source': 'RBI', 'url': 'https://rbi.org.in/notifications_rss.xml'},
    {
      'source': 'NSE',
      'url': 'https://nsearchives.nseindia.com/content/RSS/Online_announcements.xml'
    },
    {'source': 'BSE', 'url': 'https://www.bseindia.com/data/xml/notices.xml'},
  ];

  static const List<String> _policyKeywords = [
    'MPC',
    'REPO',
    'POLICY',
    'CRR',
    'SLR',
    'INFLATION',
    'FOREX',
    'LIQUIDITY',
    'VRR',
    'VRRR',
    'PENALTY',
    'BANKING',
    'NBFC',
    'SEBI',
  ];

  static const List<String> _heavyweightKeywords = [
    'HDFC BANK',
    'HDFCBANK',
    'RELIANCE',
    'ICICI BANK',
    'ICICIBANK',
    'INFOSYS',
    'TCS',
    'TATA CONSULTANCY',
    'STATE BANK',
    'SBIN',
    'BHARTI AIRTEL',
    'KOTAK',
    'AXIS BANK',
    'ITC',
    'LARSEN',
    'BAJAJ FINANCE',
  ];

  static const List<String> _foKeywords = [
    'DERIVATIVE',
    'F&O',
    'MWPL',
    'PRICE BAND',
    'SURVEILLANCE',
    'EXPIRY',
    'SETTLEMENT',
    'RESULT',
    'DIVIDEND',
    'MERGER',
    'ACQUISITION',
    'BONUS',
  ];

  List<MarketNewsItem> items = [];
  int lastFetchedMs = 0;
  bool _inFlight = false;
  String lastError = '';

  static String _unescapeXml(String s) {
    var out = s
        .replaceAll(RegExp(r'<!\[CDATA\['), '')
        .replaceAll(']]>', '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return out;
  }

  static String _extractTag(String block, String tag) {
    final reg = RegExp(
      '<$tag(?:\\s[^>]*)?>([\\s\\S]*?)</$tag>',
      caseSensitive: false,
    );
    final m = reg.firstMatch(block);
    return m != null ? _unescapeXml(m.group(1) ?? '') : '';
  }

  static const Map<String, int> _months = {
    'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
    'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
  };

  static int parsePubDateMs(String raw) {
    final clean = raw.trim();
    if (clean.isEmpty) return 0;
    final iso = DateTime.tryParse(clean);
    if (iso != null) return iso.millisecondsSinceEpoch;

    // RFC-822 style: "Wed, 25 Nov 2026 14:30:00 GMT" or "25 Nov 2026 10:15:00 +0530"
    final reg = RegExp(
        r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})(?:\s+(\d{2}):(\d{2})(?::(\d{2}))?)?');
    final m = reg.firstMatch(clean);
    if (m != null) {
      final dd = int.tryParse(m.group(1) ?? '') ?? 1;
      final mon = _months[(m.group(2) ?? '').toUpperCase()] ?? 1;
      final yyyy = int.tryParse(m.group(3) ?? '') ?? 2026;
      final hh = int.tryParse(m.group(4) ?? '0') ?? 0;
      final mm = int.tryParse(m.group(5) ?? '0') ?? 0;
      final ss = int.tryParse(m.group(6) ?? '0') ?? 0;
      final isGmt = clean.toUpperCase().contains('GMT') ||
          clean.toUpperCase().contains('UTC');
      final dt = isGmt
          ? DateTime.utc(yyyy, mon, dd, hh, mm, ss)
          : DateTime(yyyy, mon, dd, hh, mm, ss);
      return dt.millisecondsSinceEpoch;
    }
    return 0;
  }

  static List<MarketNewsItem> parseRssXml(
      String xmlBody, String source) {
    final out = <MarketNewsItem>[];
    final itemReg = RegExp(
      r'<item\b[^>]*>([\s\S]*?)</item>',
      caseSensitive: false,
    );
    final matches = itemReg.allMatches(xmlBody);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    int count = 0;
    for (final m in matches) {
      if (count >= 20) break;
      final block = m.group(1) ?? '';
      final title = _extractTag(block, 'title');
      if (title.isEmpty) continue;
      final link = _extractTag(block, 'link');
      final pubRaw = _extractTag(block, 'pubDate');
      final ts = parsePubDateMs(pubRaw);
      final upper = title.toUpperCase();

      String tag = 'FILING';
      bool highImpact = false;
      if (source == 'RBI' || _policyKeywords.any(upper.contains)) {
        tag = 'POLICY';
        highImpact = _policyKeywords.any(upper.contains);
      } else if (_heavyweightKeywords.any(upper.contains)) {
        tag = 'HEAVYWEIGHT';
        highImpact = true;
      } else if (_foKeywords.any(upper.contains)) {
        tag = 'F&O';
        highImpact = true;
      }

      out.add(MarketNewsItem(
        source: source,
        title: title,
        link: link,
        pubDateRaw: pubRaw,
        timestampMs: ts > 0 ? ts : (nowMs - count * 1000),
        isHighImpact: highImpact,
        impactTag: tag,
      ));
      count++;
    }
    return out;
  }

  Future<List<MarketNewsItem>> refresh(
      {bool force = false}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force && items.isNotEmpty && (nowMs - lastFetchedMs) < 60000) {
      return items;
    }
    if (_inFlight) return items;
    _inFlight = true;

    try {
      final results = await Future.wait(_feeds.map((f) async {
        try {
          final resp = await http.get(
            Uri.parse(f['url']!),
            headers: const {
              'User-Agent': 'Mozilla/5.0 (Linux; Android 13) SadhuAI/5.1',
              'Accept': 'application/rss+xml,application/xml,text/xml,*/*',
            },
          ).timeout(const Duration(seconds: 7));
          if (resp.statusCode == 200 && resp.body.isNotEmpty) {
            return parseRssXml(resp.body, f['source']!);
          }
        } catch (_) {}
        return const <MarketNewsItem>[];
      }));

      final merged = <MarketNewsItem>[];
      final seenTitles = <String>{};
      for (final list in results) {
        for (final it in list) {
          final key = '${it.source}|${it.title.toLowerCase()}';
          if (seenTitles.add(key)) {
            merged.add(it);
          }
        }
      }

      merged.sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
      if (merged.isNotEmpty) {
        items = merged.take(45).toList();
        lastFetchedMs = DateTime.now().millisecondsSinceEpoch;
        lastError = '';
      } else if (items.isEmpty) {
        lastError = 'Official RBI/NSE/BSE RSS feeds unreachable right now.';
      }
      return items;
    } finally {
      _inFlight = false;
    }
  }
}
