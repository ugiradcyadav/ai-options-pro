import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';
import 'constituent_flow_engine.dart';

class ResolvedContract {
  final String securityId;
  final String tradingSymbol;
  final UnderlyingIndex index;
  final String expiryIso; // YYYY-MM-DD
  final int strike;
  final OptionType optionType;
  final int lotSize;
  final String exchangeSegment; // 'NFO' or 'BFO'

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

class ResolvedFutureContract {
  final String securityId;
  final String tradingSymbol;
  final UnderlyingIndex index;
  final String expiryIso;
  final int lotSize;
  final String exchangeSegment; // 'NFO' or 'BFO'

  const ResolvedFutureContract({
    required this.securityId,
    required this.tradingSymbol,
    required this.index,
    required this.expiryIso,
    required this.lotSize,
    required this.exchangeSegment,
  });
}

class ScripMasterEngine {
  static final ScripMasterEngine instance = ScripMasterEngine._();
  ScripMasterEngine._();

  static const String angelMasterUrl =
      'https://margincalculator.angelbroking.com/OpenAPI_File/files/OpenAPIScripMaster.json';

  final Map<String, ResolvedContract> _contractsByKey = {};
  final Map<String, String> _nseEquityTokens = {};
  final Map<UnderlyingIndex, List<ResolvedFutureContract>>
      _futuresByIndex = {
    for (final u in UnderlyingIndex.values) u: <ResolvedFutureContract>[],
  };
  final Map<UnderlyingIndex, List<String>> _expiriesByIndex = {
    for (final u in UnderlyingIndex.values) u: <String>[],
  };
  final Map<UnderlyingIndex, int> _lotSizeByIndex = {};

  bool isLoaded = false;
  String masterVersion = 'UNLOADED';
  String lastLoadError = '';

  static const Set<String> _allowedSymbols = {
    'NIFTY',
    'BANKNIFTY',
    'FINNIFTY',
    'SENSEX',
  };

  static const Map<String, int> _monthMap = {
    'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
    'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
  };

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

  static UnderlyingIndex? matchExactIndex(String rawName) {
    final clean = rawName.trim().toUpperCase();
    if (!_allowedSymbols.contains(clean)) return null;
    if (clean == 'NIFTY') return UnderlyingIndex.nifty50;
    if (clean == 'BANKNIFTY') return UnderlyingIndex.bankNifty;
    if (clean == 'FINNIFTY') return UnderlyingIndex.finNifty;
    if (clean == 'SENSEX') return UnderlyingIndex.sensex;
    return null;
  }

  String? getNseEquityToken(String symbol) =>
      _nseEquityTokens[symbol.trim().toUpperCase()];

  int get loadedEquityCount => _nseEquityTokens.length;

  ResolvedFutureContract? getNearestFutureForIndex(UnderlyingIndex index) {
    final list = _futuresByIndex[index];
    if (list == null || list.isEmpty) return null;
    return list.first;
  }

  Future<bool> loadOrRefreshMaster({bool forceDownload = false}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final todayStr = DateFormat('yyyyMMdd').format(
          DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)));
      final cacheFile =
          File(join(dir.path, 'angel_sadhu_master_v4_$todayStr.json'));
      final trackedEq = ConstituentFlowEngine.allTrackedEquitySymbols;

      String jsonBody = '';
      if (!forceDownload && await cacheFile.exists()) {
        jsonBody = await cacheFile.readAsString();
      } else {
        final resp = await http
            .get(Uri.parse(angelMasterUrl))
            .timeout(const Duration(seconds: 35));
        if (resp.statusCode == 200 && resp.body.isNotEmpty) {
          final decoded = jsonDecode(resp.body);
          if (decoded is List) {
            final filtered = <Map<String, dynamic>>[];
            for (final item in decoded) {
              if (item is Map) {
                final exch = (item['exch_seg'] ?? '').toString().toUpperCase();
                final inst =
                    (item['instrumenttype'] ?? '').toString().toUpperCase();
                final name = (item['name'] ?? '').toString().toUpperCase();
                final sym = (item['symbol'] ?? '').toString().toUpperCase();

                final isTargetFo = (exch == 'NFO' || exch == 'BFO') &&
                    (inst == 'OPTIDX' || inst == 'FUTIDX') &&
                    _allowedSymbols.contains(name);
                final isTargetEq = exch == 'NSE' &&
                    sym.endsWith('-EQ') &&
                    (trackedEq.contains(name) ||
                        trackedEq.contains(sym.substring(0, sym.length - 3)));

                if (isTargetFo || isTargetEq) {
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
      final futCount = _futuresByIndex.values.fold<int>(
          0, (sum, list) => sum + list.length);
      masterVersion =
          'ANGEL-v4-$todayStr ($count opt, $futCount fut, ${_nseEquityTokens.length} eq)';
      isLoaded = count > 0;
      lastLoadError =
          isLoaded ? '' : 'No index option contracts found in master';
      return isLoaded;
    } catch (e) {
      lastLoadError = 'Master load error: $e';
      return false;
    }
  }

  int loadFromAngelJsonList(List records, {DateTime? referenceNowUtc}) {
    _contractsByKey.clear();
    _nseEquityTokens.clear();
    for (final idx in UnderlyingIndex.values) {
      _expiriesByIndex[idx] = [];
      _futuresByIndex[idx] = [];
    }
    _lotSizeByIndex.clear();

    final nowIst = (referenceNowUtc ?? DateTime.now().toUtc())
        .add(const Duration(hours: 5, minutes: 30));
    final todayIso = DateFormat('yyyy-MM-dd').format(nowIst);
    final trackedEq = ConstituentFlowEngine.allTrackedEquitySymbols;

    final expirySets = <UnderlyingIndex, Set<String>>{
      for (final u in UnderlyingIndex.values) u: <String>{},
    };

    int loaded = 0;
    for (final raw in records) {
      if (raw is! Map) continue;
      final exch = (raw['exch_seg'] ?? '').toString().toUpperCase();
      final inst = (raw['instrumenttype'] ?? '').toString().toUpperCase();
      final token = (raw['token'] ?? '').toString().trim();
      final symbol = (raw['symbol'] ?? '').toString().trim().toUpperCase();
      final name = (raw['name'] ?? '').toString().trim().toUpperCase();

      if (exch == 'NSE' && symbol.endsWith('-EQ') && token.isNotEmpty) {
        final baseSym = symbol.substring(0, symbol.length - 3);
        if (trackedEq.contains(baseSym)) _nseEquityTokens[baseSym] = token;
        if (trackedEq.contains(name)) _nseEquityTokens[name] = token;
        continue;
      }

      if (exch != 'NFO' && exch != 'BFO') continue;
      final idx = matchExactIndex(name);
      if (idx == null) continue;
      if (idx == UnderlyingIndex.sensex && exch != 'BFO') continue;
      if (idx != UnderlyingIndex.sensex && exch != 'NFO') continue;

      final expIso = parseAngelExpiryToIso((raw['expiry'] ?? '').toString());
      final lotSize = int.tryParse((raw['lotsize'] ?? '0').toString()) ?? 0;
      if (token.isEmpty || expIso == null || lotSize <= 0) continue;
      if (expIso.compareTo(todayIso) < 0) continue;

      if (inst == 'FUTIDX') {
        _futuresByIndex[idx]!.add(ResolvedFutureContract(
          securityId: token,
          tradingSymbol: symbol,
          index: idx,
          expiryIso: expIso,
          lotSize: lotSize,
          exchangeSegment: exch,
        ));
        continue;
      }

      if (inst != 'OPTIDX') continue;

      final strikeRaw =
          double.tryParse((raw['strike'] ?? '0').toString()) ?? 0.0;
      final strike = strikeRaw > 100000
          ? (strikeRaw / 100.0).round()
          : strikeRaw.round();
      if (strike <= 0) continue;

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
        exchangeSegment: exch,
      );
      _contractsByKey[contract.contractKey] = contract;
      expirySets[idx]!.add(expIso);
      _lotSizeByIndex[idx] = lotSize;
      loaded++;
    }

    for (final idx in UnderlyingIndex.values) {
      final sorted = expirySets[idx]!.toList()..sort();
      _expiriesByIndex[idx] = sorted;
      _futuresByIndex[idx]!.sort((a, b) => a.expiryIso.compareTo(b.expiryIso));
    }
    isLoaded = loaded > 0;
    return loaded;
  }

  List<String> getExpiriesForIndex(UnderlyingIndex index) {
    return List<String>.unmodifiable(
        _expiriesByIndex[index] ?? const []);
  }

  int? getLotSizeForIndex(UnderlyingIndex index) => _lotSizeByIndex[index];

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
