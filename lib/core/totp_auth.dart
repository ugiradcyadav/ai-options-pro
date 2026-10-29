import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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
    return ageHours < 22.0;
  }
}

class TotpAuthManager {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kClientId = 'dhan_client_id';
  static const _kPinSecret = 'dhan_pin_secret';
  static const _kTotpSecret = 'dhan_totp_secret';
  static const _kAccessToken = 'dhan_access_token';
  static const _kTokenTime = 'dhan_token_time_ms';

  static Future<DhanCredentials> loadCredentials() async {
    final clientId = await _storage.read(key: _kClientId) ?? '';
    final pinOrSecret = await _storage.read(key: _kPinSecret) ?? '';
    final totpSecret = await _storage.read(key: _kTotpSecret) ?? '';
    final accessToken = await _storage.read(key: _kAccessToken) ?? '';
    final tokenTimeStr = await _storage.read(key: _kTokenTime) ?? '0';
    return DhanCredentials(
      clientId: clientId,
      pinOrSecret: pinOrSecret,
      totpSecret: totpSecret,
      accessToken: accessToken,
      tokenGeneratedAtMs: int.tryParse(tokenTimeStr) ?? 0,
    );
  }

  static Future<void> saveCredentials({
    required String clientId,
    required String pinOrSecret,
    required String totpSecret,
    required String accessToken,
  }) async {
    await _storage.write(key: _kClientId, value: clientId.trim());
    await _storage.write(key: _kPinSecret, value: pinOrSecret.trim());
    await _storage.write(
        key: _kTotpSecret, value: totpSecret.trim().replaceAll(' ', ''));
    if (accessToken.trim().isNotEmpty) {
      await _storage.write(key: _kAccessToken, value: accessToken.trim());
      await _storage.write(
        key: _kTokenTime,
        value: DateTime.now().millisecondsSinceEpoch.toString(),
      );
    }
  }

  static Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  /// Generates RFC-6238 6-digit TOTP code locally from Base32 secret
  static String generateTotpCode(String base32Secret, {DateTime? now}) {
    final clean = base32Secret.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    if (clean.isEmpty) return '000000';

    final keyBytes = _base32Decode(clean);
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

  /// Exchanges TOTP + PIN with Dhan Auth Endpoint or verifies existing Access Token
  static Future<DhanCredentials> ensureValidSession() async {
    final creds = await loadCredentials();
    if (!creds.isConfigured) return creds;

    if (creds.isTokenFresh) {
      return creds;
    }

    if (creds.totpSecret.isNotEmpty && creds.pinOrSecret.isNotEmpty) {
      try {
        final totp = generateTotpCode(creds.totpSecret);
        final uri = Uri.parse(
          'https://auth.dhan.co/app/generateAccessToken?dhanClientId=${Uri.encodeComponent(creds.clientId)}&pin=${Uri.encodeComponent(creds.pinOrSecret)}&totp=$totp',
        );
        final resp = await http.post(uri).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          final newToken = (body['accessToken'] ?? body['token'] ?? '').toString();
          if (newToken.isNotEmpty) {
            await saveCredentials(
              clientId: creds.clientId,
              pinOrSecret: creds.pinOrSecret,
              totpSecret: creds.totpSecret,
              accessToken: newToken,
            );
            return await loadCredentials();
          }
        }
      } catch (_) {
        // Fallback to existing token verification
      }
    }
    return creds;
  }

  static Uint8List _base32Decode(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    int buffer = 0;
    int bitsLeft = 0;
    final out = <int>[];
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
