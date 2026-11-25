import '../core/models.dart';
import 'angel_smartapi_engine.dart';
import 'scrip_master_engine.dart';

class ConstituentFlowItem {
  final String symbol;
  final double ltp;
  final double open;
  final double high;
  final double low;
  final double changePct;
  final int volume;
  final double turnoverCr; // Real ltp * volume / 1e7
  final double rangePressure; // 0..1 position inside day H-L range

  const ConstituentFlowItem({
    required this.symbol,
    required this.ltp,
    required this.open,
    required this.high,
    required this.low,
    required this.changePct,
    required this.volume,
    required this.turnoverCr,
    required this.rangePressure,
  });

  bool get isInflow => changePct >= 0.0;
}

class IndexConstituentFlowSnapshot {
  final UnderlyingIndex index;
  final List<ConstituentFlowItem> items;
  final int fetchedAtMs;
  final String errorNote;

  const IndexConstituentFlowSnapshot({
    required this.index,
    required this.items,
    required this.fetchedAtMs,
    this.errorNote = '',
  });

  List<ConstituentFlowItem> get inflows =>
      items.where((e) => e.isInflow).toList()
        ..sort((a, b) => b.turnoverCr.compareTo(a.turnoverCr));

  List<ConstituentFlowItem> get outflows =>
      items.where((e) => !e.isInflow).toList()
        ..sort((a, b) => b.turnoverCr.compareTo(a.turnoverCr));

  double get inflowTurnoverCr =>
      inflows.fold(0.0, (sum, e) => sum + e.turnoverCr);

  double get outflowTurnoverCr =>
      outflows.fold(0.0, (sum, e) => sum + e.turnoverCr);
}

/// Real per-index constituent money flow (NIFTY 50, BANKNIFTY 12, FINNIFTY 20, SENSEX 30)
class ConstituentFlowEngine {
  static final ConstituentFlowEngine instance = ConstituentFlowEngine._();
  ConstituentFlowEngine._();

  static const Map<UnderlyingIndex, List<String>> constituentsByIndex = {
    UnderlyingIndex.nifty50: [
      'ADANIENT', 'ADANIPORTS', 'APOLLOHOSP', 'ASIANPAINT', 'AXISBANK',
      'BAJAJ-AUTO', 'BAJFINANCE', 'BAJAJFINSV', 'BEL', 'BHARTIARTL',
      'CIPLA', 'COALINDIA', 'DRREDDY', 'EICHERMOT', 'ETERNAL',
      'GRASIM', 'HCLTECH', 'HDFCBANK', 'HDFCLIFE', 'HEROMOTOCO',
      'HINDALCO', 'HINDUNILVR', 'ICICIBANK', 'INDUSINDBK', 'INFY',
      'ITC', 'JIOFIN', 'JSWSTEEL', 'KOTAKBANK', 'LT',
      'M&M', 'MARUTI', 'NESTLEIND', 'NTPC', 'ONGC',
      'POWERGRID', 'RELIANCE', 'SBILIFE', 'SHRIRAMFIN', 'SBIN',
      'SUNPHARMA', 'TCS', 'TATACONSUM', 'TATAMOTORS', 'TATASTEEL',
      'TECHM', 'TITAN', 'TRENT', 'ULTRACEMCO', 'WIPRO',
    ],
    UnderlyingIndex.bankNifty: [
      'HDFCBANK', 'ICICIBANK', 'SBIN', 'KOTAKBANK', 'AXISBANK', 'INDUSINDBK',
      'BANKBARODA', 'PNB', 'FEDERALBNK', 'IDFCFIRSTB', 'AUBANK', 'CANBK',
    ],
    UnderlyingIndex.finNifty: [
      'HDFCBANK', 'ICICIBANK', 'KOTAKBANK', 'AXISBANK', 'SBIN',
      'BAJFINANCE', 'BAJAJFINSV', 'SBILIFE', 'HDFCLIFE', 'ICICIGI',
      'ICICIPRULI', 'SHRIRAMFIN', 'CHOLAFIN', 'PFC', 'RECLTD',
      'MUTHOOTFIN', 'SBICARD', 'LICHSGFIN', 'HDFCAMC', 'JIOFIN',
    ],
    UnderlyingIndex.sensex: [
      'RELIANCE', 'HDFCBANK', 'ICICIBANK', 'INFY', 'TCS',
      'BHARTIARTL', 'ITC', 'LT', 'SBIN', 'AXISBANK',
      'KOTAKBANK', 'BAJFINANCE', 'M&M', 'HINDUNILVR', 'SUNPHARMA',
      'MARUTI', 'NTPC', 'HCLTECH', 'TITAN', 'TATAMOTORS',
      'ULTRACEMCO', 'POWERGRID', 'ASIANPAINT', 'BAJAJFINSV', 'ADANIPORTS',
      'TATASTEEL', 'TECHM', 'NESTLEIND', 'INDUSINDBK', 'ETERNAL',
    ],
  };

  static Set<String> get allTrackedEquitySymbols {
    final s = <String>{};
    for (final list in constituentsByIndex.values) {
      s.addAll(list);
    }
    s.add('ZOMATO'); // Legacy alias fallback for ETERNAL if broker master hasn't renamed
    return s;
  }

  final Map<UnderlyingIndex, IndexConstituentFlowSnapshot> _cache = {};
  final Map<UnderlyingIndex, bool> _inFlight = {};

  IndexConstituentFlowSnapshot? getSnapshot(UnderlyingIndex idx) => _cache[idx];

  Future<IndexConstituentFlowSnapshot?> refreshForIndex(
    UnderlyingIndex index, {
    bool force = false,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final prev = _cache[index];
    if (!force && prev != null && (nowMs - prev.fetchedAtMs) < 8000) {
      return prev;
    }
    if (_inFlight[index] == true) return prev;

    final angel = AngelSmartApiEngine.instance;
    if (!angel.isConfigured || angel.jwtToken.isEmpty) return prev;

    final master = ScripMasterEngine.instance;
    if (!master.isLoaded) return prev;

    _inFlight[index] = true;
    try {
      final symbols = constituentsByIndex[index] ?? const <String>[];
      final tokenToSym = <String, String>{};
      final tokens = <String>[];

      for (final sym in symbols) {
        String? tok = master.getNseEquityToken(sym);
        if (tok == null && sym == 'ETERNAL') {
          tok = master.getNseEquityToken('ZOMATO');
        }
        if (tok != null && tok.isNotEmpty) {
          tokenToSym[tok] = sym;
          tokens.add(tok);
        }
      }

      if (tokens.isEmpty) {
        final emptySnap = IndexConstituentFlowSnapshot(
          index: index,
          items: const [],
          fetchedAtMs: nowMs,
          errorNote: 'Refresh Scrip Master to resolve ${index.label} constituent tokens.',
        );
        _cache[index] = emptySnap;
        return emptySnap;
      }

      final fetched = await angel.fetchBatchMarketQuotes(
        exchange: 'NSE',
        tokens: tokens,
      );

      final items = <ConstituentFlowItem>[];
      for (final raw in fetched) {
        final tok = (raw['symbolToken'] ?? '').toString();
        final sym = tokenToSym[tok];
        if (sym == null) continue;

        final ltp = ((raw['ltp'] ?? 0) as num).toDouble();
        if (ltp <= 0) continue;
        final open = ((raw['open'] ?? ltp) as num).toDouble();
        final high = ((raw['high'] ?? ltp) as num).toDouble();
        final low = ((raw['low'] ?? ltp) as num).toDouble();
        final chgPct = ((raw['percentChange'] ?? 0) as num).toDouble();
        final vol = ((raw['tradeVolume'] ?? 0) as num).toInt();
        final turnCr = (ltp * vol) / 10000000.0;
        final range = high - low;
        final pressure = range > 1e-6
            ? ((ltp - low) / range).clamp(0.0, 1.0).toDouble()
            : (chgPct >= 0 ? 0.6 : 0.4);

        items.add(ConstituentFlowItem(
          symbol: sym,
          ltp: ltp,
          open: open,
          high: high,
          low: low,
          changePct: chgPct,
          volume: vol,
          turnoverCr: turnCr,
          rangePressure: pressure,
        ));
      }

      items.sort((a, b) => b.changePct.compareTo(a.changePct));
      final snap = IndexConstituentFlowSnapshot(
        index: index,
        items: items,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      _cache[index] = snap;
      return snap;
    } finally {
      _inFlight[index] = false;
    }
  }
}
