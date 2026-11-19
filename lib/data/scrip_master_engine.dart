import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';

class ResolvedContract {
  final String securityId;
  final String tradingSymbol;
  final UnderlyingIndex index;
  final String expiryIso; // YYYY-MM-DD
  final int strike;
  final OptionType optionType;
  final int lotSize;
  final String exchangeSegment;

  const ResolvedContract({
    required this.securityId,
    required this.tradingSymbol,
    required this.index,
    required this.expiryIso,
    required this.strike,
    required this.optionType,
    required this.lotSize,
    required this.exchangeSegment,
  });

  String get contractKey =>
      '${index.dhanSymbol}|$expiryIso|$strike|${optionType == OptionType.ce ? "CE" : "PE"}';
}

class ScripMasterEngine {
  static final ScripMasterEngine instance = ScripMasterEngine._();
  ScripMasterEngine._();

  static const String angelMasterUrl =
      'https://margincalculator.angelbroking.com/OpenAPI_File/files/OpenAPIScripMaster.json';

  final Map<String, ResolvedContract> _contractsByKey = {};
  final Map<UnderlyingIndex, List<String>> _expiriesByIndex = {
    UnderlyingIndex.nifty50: [],
    UnderlyingIndex.bankNifty: [],
    UnderlyingIndex.finNifty: [],
  };
  final Map<UnderlyingIndex, int> _lotSizeByIndex = {};

  bool isLoaded = false;
  String masterVersion = 'UNLOADED';
  String lastLoadError = '';

  static const Set<String> _allowedSymbols = {
    'NIFTY',
    'BANKNIFTY',
    'FINNIFTY',
  };

  static const Map<String, int> _monthMap = {
    'JAN': 1,
    'FEB': 2,
    'MAR': 3,
    'APR': 4,
    'MAY': 5,
    'JUN': 6,
    'JUL': 7,
    'AUG': 8,
    'SEP': 9,
    'OCT': 10,
    'NOV': 11,
    'DEC': 12,
  };

  /// Parses Angel One expiry format (e.g. "24NOV2026" or "24NOV26") into "YYYY-MM-DD"
  static String? parseAngelExpiryToIso(String raw) {
    final s = raw.trim().toUpperCase();
    final reg = RegExp(r'^(\d{1,2})([A-Z]{3})(\d{2,4})$');
    final m = reg.firstMatch(s);
    if (m == null) return null;
    final dd = int.tryParse(m.group(1) ?? '');
    final mon = _monthMap[m.group(2) ?? ''];
    var yy = int.tryParse(m.group(3) ?? '');
    if (dd == null || mon == null || yy == null) return null;
    if (yy < 100) yy += 2000;
    return '${yy.toString().padLeft(4, "0")}-${mon.toString().padLeft(2, "0")}-${dd.toString().padLeft(2, "0")}';
  }

  /// WP-4: Exact match only — explicitly excludes NIFTYNXT50, MIDCPNIFTY, etc.
  static UnderlyingIndex? matchExactIndex(String rawName) {
    final clean = rawName.trim().toUpperCase();
    if (!_allowedSymbols.contains(clean)) return null;
    if (clean == 'NIFTY') return UnderlyingIndex.nifty50;
    if (clean == 'BANKNIFTY') return UnderlyingIndex.bankNifty;
    if (clean == 'FINNIFTY') return UnderlyingIndex.finNifty;
    return null;
  }

  Future<bool> loadOrRefreshMaster({bool forceDownload = false}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final todayStr = DateFormat('yyyyMMdd').format(DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)));
      final cacheFile = File(join(dir.path, 'angel_nfo_master_$todayStr.json'));

      String jsonBody = '';
      if (!forceDownload && await cacheFile.exists()) {
        jsonBody = await cacheFile.readAsString();
      } else {
        final resp = await http
            .get(Uri.parse(angelMasterUrl))
            .timeout(const Duration(seconds: 25));
        if (resp.statusCode == 200 && resp.body.isNotEmpty) {
          // Filter down to OPTIDX for NIFTY/BANKNIFTY/FINNIFTY before caching on phone storage
          final decoded = jsonDecode(resp.body);
          if (decoded is List) {
            final filtered = <Map<String, dynamic>>[];
            for (final item in decoded) {
              if (item is Map) {
                final exch = (item['exch_seg'] ?? '').toString().toUpperCase();
                final inst = (item['instrumenttype'] ?? '').toString().toUpperCase();
                final name = (item['name'] ?? '').toString().toUpperCase();
                if (exch == 'NFO' &&
                    inst == 'OPTIDX' &&
                    _allowedSymbols.contains(name)) {
                  filtered.add(Map<String, dynamic>.from(item));
                }
              }
            }
            jsonBody = jsonEncode(filtered);
            await cacheFile.writeAsString(jsonBody);
          }
        } else {
          lastLoadError = 'Instrument master HTTP ${resp.statusCode}';
          return false;
        }
      }

      if (jsonBody.isEmpty) {
        lastLoadError = 'Empty instrument master payload';
        return false;
      }

      final count = loadFromAngelJsonList(jsonDecode(jsonBody) as List);
      masterVersion = 'ANGEL-NFO-$todayStr ($count contracts)';
      isLoaded = count > 0;
      lastLoadError = isLoaded ? '' : 'No index option contracts found in master';
      return isLoaded;
    } catch (e) {
      lastLoadError = 'Master load error: $e';
      return false;
    }
  }

  /// Pure deterministic parser (used both in production and in WP-4/WP-10 fixture unit tests)
  int loadFromAngelJsonList(List records, {DateTime? referenceNowUtc}) {
    _contractsByKey.clear();
    for (final idx in UnderlyingIndex.values) {
      _expiriesByIndex[idx] = [];
    }
    _lotSizeByIndex.clear();

    final nowIst = (referenceNowUtc ?? DateTime.now().toUtc())
        .add(const Duration(hours: 5, minutes: 30));
    final todayIso = DateFormat('yyyy-MM-dd').format(nowIst);

    final expirySets = <UnderlyingIndex, Set<String>>{
      UnderlyingIndex.nifty50: <String>{},
      UnderlyingIndex.bankNifty: <String>{},
      UnderlyingIndex.finNifty: <String>{},
    };

    int loaded = 0;
    for (final raw in records) {
      if (raw is! Map) continue;
      final exch = (raw['exch_seg'] ?? '').toString().toUpperCase();
      final inst = (raw['instrumenttype'] ?? '').toString().toUpperCase();
      if (exch != 'NFO' || inst != 'OPTIDX') continue;

      final idx = matchExactIndex((raw['name'] ?? '').toString());
      if (idx == null) continue;

      final token = (raw['token'] ?? '').toString().trim();
      final symbol = (raw['symbol'] ?? '').toString().trim().toUpperCase();
      final expIso = parseAngelExpiryToIso((raw['expiry'] ?? '').toString());
      final lotSize = int.tryParse((raw['lotsize'] ?? '0').toString()) ?? 0;
      final strikeRaw = double.tryParse((raw['strike'] ?? '0').toString()) ?? 0.0;
      // Angel master stores strike scaled by 100 (e.g. 2400000.00 -> 24000)
      final strike = strikeRaw > 100000 ? (strikeRaw / 100.0).round() : strikeRaw.round();

      if (token.isEmpty || expIso == null || lotSize <= 0 || strike <= 0) {
        continue;
      }
      if (expIso.compareTo(todayIso) < 0) continue;

      OptionType? optType;
      if (symbol.endsWith('CE')) {
        optType = OptionType.ce;
      } else if (symbol.endsWith('PE')) {
        optType = OptionType.pe;
      }
      if (optType == null) continue;

      final contract = ResolvedContract(
        securityId: token,
        tradingSymbol: symbol,
        index: idx,
        expiryIso: expIso,
        strike: strike,
        optionType: optType,
        lotSize: lotSize,
        exchangeSegment: 'NFO',
      );
      _contractsByKey[contract.contractKey] = contract;
      expirySets[idx]!.add(expIso);
      _lotSizeByIndex[idx] = lotSize;
      loaded++;
    }

    for (final idx in UnderlyingIndex.values) {
      final sorted = expirySets[idx]!.toList()..sort();
      _expiriesByIndex[idx] = sorted;
    }
    isLoaded = loaded > 0;
    return loaded;
  }

  List<String> getExpiriesForIndex(UnderlyingIndex index) {
    return List<String>.unmodifiable(_expiriesByIndex[index] ?? const []);
  }

  int? getLotSizeForIndex(UnderlyingIndex index) => _lotSizeByIndex[index];

  /// WP-4: Exact contract lookup by (index, expiry, strike, optionType). Returns null if unresolvable.
  ResolvedContract? resolveOptionContract({
    required UnderlyingIndex index,
    required String expiryIso,
    required int strike,
    required OptionType optionType,
  }) {
    final key =
        '${index.dhanSymbol}|$expiryIso|$strike|${optionType == OptionType.ce ? "CE" : "PE"}';
    return _contractsByKey[key];
  }
}
