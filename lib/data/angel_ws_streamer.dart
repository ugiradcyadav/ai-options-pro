import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class DepthLevel {
  final double price;
  final int quantity;
  final int orders;

  const DepthLevel({
    required this.price,
    required this.quantity,
    required this.orders,
  });
}

class LiveWsTick {
  final int exchangeType; // 1=NSE_CM, 2=NSE_FO, 3=BSE_CM, 4=BSE_FO
  final String token;
  final double ltp;
  final double? openPrice;
  final double? highPrice;
  final double? lowPrice;
  final double? closePrice;
  final int? volume;
  final int? openInterestRaw;
  final double? totalBuyQty;
  final double? totalSellQty;
  final double? bestBid;
  final double? bestAsk;
  final int best5BidQty;
  final int best5AskQty;
  final List<DepthLevel> bids;
  final List<DepthLevel> asks;
  final int exchangeTimestampMs;
  final int receivedAtMs;

  const LiveWsTick({
    required this.exchangeType,
    required this.token,
    required this.ltp,
    this.openPrice,
    this.highPrice,
    this.lowPrice,
    this.closePrice,
    this.volume,
    this.openInterestRaw,
    this.totalBuyQty,
    this.totalSellQty,
    this.bestBid,
    this.bestAsk,
    this.best5BidQty = 0,
    this.best5AskQty = 0,
    this.bids = const [],
    this.asks = const [],
    required this.exchangeTimestampMs,
    required this.receivedAtMs,
  });

  double? get changePct {
    if (closePrice == null || closePrice! <= 0) return null;
    return ((ltp - closePrice!) / closePrice!) * 100.0;
  }
}

/// Angel One SmartStream WebSocket v2 binary tick streamer (SnapQuote Mode 3)
class AngelWsStreamer {
  static final AngelWsStreamer instance = AngelWsStreamer._();
  AngelWsStreamer._();

  static const String _wsUrl = 'wss://smartapisocket.angelone.in/smart-stream';
  static const int exchNseCm = 1;
  static const int exchNseFo = 2;
  static const int exchBseCm = 3;
  static const int exchBseFo = 4;

  WebSocket? _socket;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;
  bool isConnected = false;
  int totalTicksReceived = 0;
  int lastTickReceivedMs = 0;

  String _jwtToken = '';
  String _apiKey = '';
  String _clientCode = '';
  String _feedToken = '';

  Map<int, Set<String>> _subscribedTokens = {};
  void Function(LiveWsTick tick)? onTick;
  void Function(bool connected)? onConnectionChanged;

  Future<bool> connect({
    required String jwtToken,
    required String apiKey,
    required String clientCode,
    required String feedToken,
  }) async {
    if (jwtToken.isEmpty ||
        apiKey.isEmpty ||
        clientCode.isEmpty ||
        feedToken.isEmpty) {
      return false;
    }

    _jwtToken = jwtToken;
    _apiKey = apiKey;
    _clientCode = clientCode;
    _feedToken = feedToken;
    _manualDisconnect = false;

    await _closeSocketOnly();

    try {
      final ws = await WebSocket.connect(
        _wsUrl,
        headers: {
          'Authorization': _jwtToken,
          'x-api-key': _apiKey,
          'x-client-code': _clientCode,
          'x-feed-token': _feedToken,
        },
      ).timeout(const Duration(seconds: 8));

      _socket = ws;
      isConnected = true;
      onConnectionChanged?.call(true);

      ws.listen(
        _handleMessage,
        onError: (_) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );

      // Official SmartStream v2 heartbeat: 'ping' every 10 seconds
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        try {
          _socket?.add('ping');
        } catch (_) {}
      });

      if (_subscribedTokens.isNotEmpty) {
        _sendAction(action: 1, tokenMap: _subscribedTokens);
      }
      return true;
    } catch (_) {
      isConnected = false;
      onConnectionChanged?.call(false);
      _scheduleReconnect();
      return false;
    }
  }

  void subscribeTokens(Map<int, List<String>> tokensByExchange) {
    final nextMap = <int, Set<String>>{};
    tokensByExchange.forEach((exchType, list) {
      final clean = list.where((t) => t.trim().isNotEmpty).toSet();
      if (clean.isNotEmpty) nextMap[exchType] = clean;
    });

    // Unsubscribe stale tokens that are no longer needed
    if (isConnected && _socket != null && _subscribedTokens.isNotEmpty) {
      final toRemove = <int, Set<String>>{};
      _subscribedTokens.forEach((exch, oldSet) {
        final keep = nextMap[exch] ?? const <String>{};
        final diff = oldSet.difference(keep);
        if (diff.isNotEmpty) toRemove[exch] = diff;
      });
      if (toRemove.isNotEmpty) {
        _sendAction(action: 0, tokenMap: toRemove);
      }
    }

    _subscribedTokens = nextMap;
    if (isConnected && _socket != null && nextMap.isNotEmpty) {
      _sendAction(action: 1, tokenMap: nextMap);
    }
  }

  void _sendAction({
    required int action, // 1=Subscribe, 0=Unsubscribe
    required Map<int, Set<String>> tokenMap,
  }) {
    if (_socket == null) return;
    final tokenList = <Map<String, dynamic>>[];
    tokenMap.forEach((exchType, tokens) {
      if (tokens.isNotEmpty) {
        tokenList.add({
          'exchangeType': exchType,
          'tokens': tokens.toList(),
        });
      }
    });
    if (tokenList.isEmpty) return;

    final payload = jsonEncode({
      'correlationID': 'aiopt_${DateTime.now().millisecondsSinceEpoch % 100000}',
      'action': action,
      'params': {
        'mode': 3, // SnapQuote (LTP, OHLC, Volume, OI + Best 5 Bid/Ask Depth)
        'tokenList': tokenList,
      },
    });
    try {
      _socket!.add(payload);
    } catch (_) {}
  }

  void _handleMessage(dynamic data) {
    if (data is String) return; // 'pong' heartbeat
    if (data is List<int>) {
      final tick = parseBinaryPacket(Uint8List.fromList(data));
      if (tick != null) {
        totalTicksReceived++;
        lastTickReceivedMs = tick.receivedAtMs;
        onTick?.call(tick);
      }
    }
  }

  /// Official Angel SmartStream v2 Little-Endian binary decoder
  static LiveWsTick? parseBinaryPacket(Uint8List bytes) {
    if (bytes.length < 51) return null;
    try {
      final bd = ByteData.sublistView(bytes);
      final mode = bytes[0];
      final exchType = bytes[1];

      final tokenChars = <int>[];
      for (int i = 2; i < 27; i++) {
        if (bytes[i] == 0) break;
        tokenChars.add(bytes[i]);
      }
      final token = String.fromCharCodes(tokenChars).trim();
      if (token.isEmpty) return null;

      final exchTs = bd.getInt64(35, Endian.little);
      final ltpRaw = bd.getInt64(43, Endian.little);
      final ltp = ltpRaw / 100.0;
      if (ltp <= 0) return null;

      int? vol;
      double? totalBuy;
      double? totalSell;
      double? openP;
      double? highP;
      double? lowP;
      double? closeP;
      int? oiRaw;
      double? bestBid;
      double? bestAsk;
      int bidQtySum = 0;
      int askQtySum = 0;
      final bids = <DepthLevel>[];
      final asks = <DepthLevel>[];

      if (mode >= 2 && bytes.length >= 123) {
        vol = bd.getInt64(67, Endian.little);
        totalBuy = bd.getFloat64(75, Endian.little);
        totalSell = bd.getFloat64(83, Endian.little);
        final oRaw = bd.getInt64(91, Endian.little);
        final hRaw = bd.getInt64(99, Endian.little);
        final lRaw = bd.getInt64(107, Endian.little);
        final cRaw = bd.getInt64(115, Endian.little);
        if (oRaw > 0) openP = oRaw / 100.0;
        if (hRaw > 0) highP = hRaw / 100.0;
        if (lRaw > 0) lowP = lRaw / 100.0;
        if (cRaw > 0) closeP = cRaw / 100.0;
      }

      if (mode == 3 && bytes.length >= 139) {
        oiRaw = bd.getInt64(131, Endian.little);
      }

      if (mode == 3 && bytes.length >= 347) {
        // 10 packets of 20 bytes (147..347): flag==1 -> Buy/Bid, flag==0 -> Sell/Ask
        for (int i = 0; i < 10; i++) {
          final off = 147 + (i * 20);
          final flag = bd.getUint16(off, Endian.little);
          final qty = bd.getInt64(off + 2, Endian.little);
          final priceRaw = bd.getInt64(off + 10, Endian.little);
          final orders = bd.getUint16(off + 18, Endian.little);
          final price = priceRaw / 100.0;
          if (price <= 0 && qty <= 0) continue;

          final lvl = DepthLevel(price: price, quantity: qty, orders: orders);
          if (flag == 1) {
            bids.add(lvl);
            bidQtySum += qty;
          } else {
            asks.add(lvl);
            askQtySum += qty;
          }
        }
        if (bids.isNotEmpty && bids.first.price > 0) {
          bestBid = bids.first.price;
        }
        if (asks.isNotEmpty && asks.first.price > 0) {
          bestAsk = asks.first.price;
        }
      }

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      return LiveWsTick(
        exchangeType: exchType,
        token: token,
        ltp: ltp,
        openPrice: openP,
        highPrice: highP,
        lowPrice: lowP,
        closePrice: closeP,
        volume: vol,
        openInterestRaw: oiRaw,
        totalBuyQty: totalBuy,
        totalSellQty: totalSell,
        bestBid: bestBid,
        bestAsk: bestAsk,
        best5BidQty: bidQtySum,
        best5AskQty: askQtySum,
        bids: bids,
        asks: asks,
        exchangeTimestampMs: exchTs > 0 ? exchTs : nowMs,
        receivedAtMs: nowMs,
      );
    } catch (_) {
      return null;
    }
  }

  void _handleDisconnect() {
    isConnected = false;
    onConnectionChanged?.call(false);
    if (!_manualDisconnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (!_manualDisconnect && _jwtToken.isNotEmpty) {
        connect(
          jwtToken: _jwtToken,
          apiKey: _apiKey,
          clientCode: _clientCode,
          feedToken: _feedToken,
        );
      }
    });
  }

  Future<void> _closeSocketOnly() async {
    _heartbeatTimer?.cancel();
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    isConnected = false;
    await _closeSocketOnly();
  }
}
