import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class DhanCredentials {
  final String clientId;
  final String pinOrSecret;
  final String totpSecret;
  final String accessToken;
  final int tokenGeneratedAtMs;

  const DhanCredentials({
    required this.clientId,
    required this.pinOrSecret,
    required this.totpSecret,
    required this.accessToken,
    required this.tokenGeneratedAtMs,
  });

  bool get isConfigured =>
      clientId.trim().isNotEmpty &&
      (accessToken.trim().isNotEmpty || totpSecret.trim().isNotEmpty);

  bool get isTokenFresh {
    if (accessToken.trim().isEmpty) return false;
    final ageHours =
        (DateTime.now().millisecondsSinceEpoch - tokenGeneratedAtMs) /
            (1000 * 3600);
    return ageHours < 20.0;
  }
}

class TotpAuthManager {
  static const _kClientId = 'dhan_client_id_v2';
  static const _kPinSecret = 'dhan_pin_secret_v2';
  static const _kTotpSecret = 'dhan_totp_secret_v2';
  static const _kAccessToken = 'dhan_access_token_v2';
  static const _kTokenTime = 'dhan_token_time_ms_v2';

  static String lastServerMessage = '';

  static Future<DhanCredentials> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString(_kClientId) ?? '';
    final pinOrSecret = prefs.getString(_kPinSecret) ?? '';
    final totpSecret = prefs.getString(_kTotpSecret) ?? '';
    final accessToken = prefs.getString(_kAccessToken) ?? '';
    final tokenTime = prefs.getInt(_kTokenTime) ?? 0;

    return DhanCredentials(
      clientId: clientId,
      pinOrSecret: pinOrSecret,
      totpSecret: totpSecret,
      accessToken: accessToken,
      tokenGeneratedAtMs: tokenTime,
    );
  }

  static Future<void> saveCredentials({
    required String clientId,
    required String pinOrSecret,
    required String totpSecret,
    required String accessToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kClientId, clientId.trim());
    await prefs.setString(_kPinSecret, pinOrSecret.trim());
    await prefs.setString(
      _kTotpSecret,
      totpSecret.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), ''),
    );
    if (accessToken.trim().isNotEmpty) {
      await prefs.setString(_kAccessToken, accessToken.trim());
      await prefs.setInt(_kTokenTime, DateTime.now().millisecondsSinceEpoch);
    }
  }

  static String generateTotpCode(String base32Secret, {DateTime? now}) {
    final clean =
        base32Secret.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    if (clean.isEmpty) return '000000';

    final keyBytes = _base32Decode(clean);
    if (keyBytes.isEmpty) return '000000';

    final timeSec = ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000);
    int counter = timeSec ~/ 30;

    final counterBytes = Uint8List(8);
    for (int i = 7; i >= 0; i--) {
      counterBytes[i] = counter & 0xff;
      counter >>= 8;
    }

    final hmac = Hmac(sha1, keyBytes);
    final hash = hmac.convert(counterBytes).bytes;
    final offset = hash[hash.length - 1] & 0x0f;
    final binary = ((hash[offset] & 0x7f) << 24) |
        ((hash[offset + 1] & 0xff) << 16) |
        ((hash[offset + 2] & 0xff) << 8) |
        (hash[offset + 3] & 0xff);

    final otp = binary % 1000000;
    return otp.toString().padLeft(6, '0');
  }

  static Future<DhanCredentials> ensureValidSession({bool forceRefresh = false}) async {
    final creds = await loadCredentials();
    if (!creds.isConfigured) {
      lastServerMessage = 'Credentials not configured.';
      return creds;
    }

    if (!forceRefresh && creds.isTokenFresh && creds.accessToken.isNotEmpty) {
      return creds;
    }

    if (creds.accessToken.isNotEmpty && creds.totpSecret.isEmpty) {
      lastServerMessage = 'Using direct 24h Access Token.';
      return creds;
    }

    if (creds.totpSecret.isNotEmpty && creds.pinOrSecret.isNotEmpty) {
      final totp = generateTotpCode(creds.totpSecret);
      try {
        final uri = Uri.parse(
          'https://auth.dhan.co/app/generateAccessToken?dhanClientId=${Uri.encodeComponent(creds.clientId)}&pin=${Uri.encodeComponent(creds.pinOrSecret)}&totp=$totp',
        );
        final resp = await http.post(
          uri,
          headers: {'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 12));

        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          if (body is Map &&
              (body['accessToken'] != null || body['token'] != null)) {
            final newToken =
                (body['accessToken'] ?? body['token']).toString().trim();
            if (newToken.isNotEmpty) {
              await saveCredentials(
                clientId: creds.clientId,
                pinOrSecret: creds.pinOrSecret,
                totpSecret: creds.totpSecret,
                accessToken: newToken,
              );
              lastServerMessage = 'Auto-TOTP token generated successfully!';
              return await loadCredentials();
            }
          }
          lastServerMessage = 'Dhan Auth Response: ${resp.body}';
        } else {
          lastServerMessage =
              'Dhan TOTP Auth HTTP ${resp.statusCode}: ${resp.body}';
        }
      } catch (e) {
        lastServerMessage = 'Network/Auth Error: $e';
      }
    }

    return creds;
  }

  static Uint8List _base32Decode(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    int buffer = 0;
    int bitsLeft = 0;
    final List<int> out = [];
    for (int i = 0; i < input.length; i++) {
      final val = alphabet.indexOf(input[i]);
      if (val < 0) continue;
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        out.add((buffer >> bitsLeft) & 0xff);
      }
    }
    return Uint8List.fromList(out);
  }
}
