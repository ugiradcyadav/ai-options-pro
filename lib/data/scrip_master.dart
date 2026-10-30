import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../core/models.dart';

/// T3: Resolves (index, expiry, strike, optionType) to Dhan's real numeric security ID
/// and contract lot size from Dhan's official Scrip Master CSV. Fails closed if unresolvable.
class ScripMasterEngine {
  static final ScripMasterEngine instance = ScripMasterEngine._();
  ScripMasterEngine._();

  final Map<String, ResolvedContract> _contractCache = {};
  final Map<UnderlyingIndex, List<String>> _masterExpiries = {
    UnderlyingIndex.nifty50: [],
    UnderlyingIndex.bankNifty: [],
    UnderlyingIndex.finNifty: [],
  };
  String _lastSyncDateKey = '';

  String _makeLookupKey(
    UnderlyingIndex index,
    String expiryIso,
    int strike,
    OptionType type,
  ) {
    final t = type == OptionType.ce ? 'CE' : 'PE';
    return '${index.dhanSymbol}_${expiryIso}_${strike}_$t';
  }

  /// Parses CSV lines from Dhan's compact scrip master or test fixture (T3 Acceptance)
  void loadFromCsvContent(String csvContent) {
    final lines = const LineSplitter().convert(csvContent);
    final expSets = <UnderlyingIndex, Set<String>>{
      UnderlyingIndex.nifty50: <String>{},
      UnderlyingIndex.bankNifty: <String>{},
      UnderlyingIndex.finNifty: <String>{},
    };

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (!line.contains('OPTIDX')) continue;

      final cols = line.split(',');
      if (cols.length < 12) continue;

      // Standard Dhan compact scrip master columns:
      // [0] EXCH, [1] SEG, [2] SECURITY_ID, [3] INSTRUMENT, [4] EXPIRY_CODE,
      // [5] TRADING_SYMBOL, [6] LOT_UNITS, [7] CUSTOM_SYMBOL, [8] EXPIRY_DATE,
      // [9] STRIKE_PRICE, [10] OPTION_TYPE
      final secId = cols[2].trim();
      final sym = cols[5].trim().toUpperCase();
      final lotSize = (double.tryParse(cols[6].trim()) ?? 0).round();
      final rawExp = cols[8].trim();
      final strike = (double.tryParse(cols[9].trim()) ?? 0).round();
      final optTypeStr = cols[10].trim().toUpperCase();

      if (secId.isEmpty || strike <= 0 || lotSize <= 0) continue;
      if (optTypeStr != 'CE' && optTypeStr != 'PE') continue;

      UnderlyingIndex? idx;
      if (sym.startsWith('BANKNIFTY')) {
        idx = UnderlyingIndex.bankNifty;
      } else if (sym.startsWith('FINNIFTY')) {
        idx = UnderlyingIndex.finNifty;
      } else if (sym.startsWith('NIFTY')) {
        idx = UnderlyingIndex.nifty50;
      }
      if (idx == null) continue;

      final expiryIso = _normalizeExpiryIso(rawExp);
      if (expiryIso.isEmpty) continue;

      final optType = optTypeStr == 'CE' ? OptionType.ce : OptionType.pe;
      final contract = ResolvedContract(
        numericSecurityId: secId,
        tradingSymbol: sym,
        index: idx,
        expiryIso: expiryIso,
        strike: strike,
        optionType: optType,
        lotSize: lotSize,
      );

      final key = _makeLookupKey(idx, expiryIso, strike, optType);
      _contractCache[key] = contract;
      expSets[idx]!.add(expiryIso);
    }

    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
    for (final idx in UnderlyingIndex.values) {
      final sorted = expSets[idx]!
          .where((e) => e.compareTo(todayIso) >= 0)
          .toList()
        ..sort();
      if (sorted.isNotEmpty) {
        _masterExpiries[idx] = sorted;
      }
    }
  }

  String _normalizeExpiryIso(String raw) {
    final clean = raw.split(' ').first.trim();
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(clean)) {
      return clean;
    }
    return '';
  }

  /// Downloads Dhan Scrip Master once per trading day (streaming filter for OPTIDX)
  Future<void> refreshDailyScripMasterIfNeeded() async {
    final todayKey = DateFormat('yyyy-MM-dd').format(DateTime.now());
    if (_lastSyncDateKey == todayKey && _contractCache.isNotEmpty) return;

    try {
      final client = http.Client();
      final req = http.Request(
        'GET',
        Uri.parse('https://images.dhan.co/api-data/api-scrip-master.csv'),
      );
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 15));

      if (streamed.statusCode == 200) {
        final filteredLines = <String>['HEADER'];
        await streamed.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) {
          if (line.contains('OPTIDX') &&
              (line.contains('NIFTY') ||
                  line.contains('BANKNIFTY') ||
                  line.contains('FINNIFTY'))) {
            filteredLines.add(line);
          }
        });
        if (filteredLines.length > 1) {
          loadFromCsvContent(filteredLines.join('\n'));
          _lastSyncDateKey = todayKey;
        }
      }
      client.close();
    } catch (_) {}
  }

  /// T3.2 & T3.3: Resolves exact contract or returns null (caller must fail closed!)
  ResolvedContract? resolveContract({
    required UnderlyingIndex index,
    required String expiryIso,
    required int strike,
    required OptionType optionType,
  }) {
    final key = _makeLookupKey(index, expiryIso, strike, optionType);
    return _contractCache[key];
  }

  void registerDirectContract(ResolvedContract contract) {
    final key = _makeLookupKey(
      contract.index,
      contract.expiryIso,
      contract.strike,
      contract.optionType,
    );
    _contractCache[key] = contract;
  }

  List<String> getValidExpiries(UnderlyingIndex index) {
    return _masterExpiries[index] ?? const [];
  }
}
