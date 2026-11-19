import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'http_safe_client.dart';
import 'models.dart';

class TotpAuthManager {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kClientId = 'sec_dhan_client_id';
  static const _kAccessToken = 'sec_dhan_access_token';
  static const _kPin = 'sec_dhan_pin';
  static const _kTotpSecret = 'sec_dhan_totp_secret';
  static const _kOptInTotp = 'sec_dhan_opt_in_totp';
  static const _kTokenExpiryMs = 'sec_dhan_token_expiry_ms';

  static String lastAuthError = '';

  static Future<void> saveCredentials({
    required String clientId,
    required String accessToken,
    String pin = '',
    String totpSecret = '',
    bool optInStoreTotp = false,
  }) async {
    await _secureStorage.write(key: _kClientId, value: clientId.trim());
    await _secureStorage.write(key: _kAccessToken, value: accessToken.trim());
    await _secureStorage.write(
        key: _kOptInTotp, value: optInStoreTotp ? 'true' : 'false');

    // WP-1: Never store PIN and TOTP seed together. Only store TOTP seed on explicit user opt-in.
    if (optInStoreTotp && totpSecret.trim().isNotEmpty) {
      final cleanSeed =
          totpSecret.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
      await _secureStorage.write(key: _kTotpSecret, value: cleanSeed);
      await _secureStorage.delete(key: _kPin);
    } else {
      await _secureStorage.delete(key: _kTotpSecret);
      if (pin.trim().isNotEmpty) {
        await _secureStorage.write(key: _kPin, value: pin.trim());
      } else {
        await _secureStorage.delete(key: _kPin);
      }
    }

    final expiryMs = DateTime.now()
        .add(const Duration(hours: 20))
        .millisecondsSinceEpoch;
    await _secureStorage.write(
        key: _kTokenExpiryMs, value: expiryMs.toString());
  }

  static Future<void> clearAllCredentials() async {
    await _secureStorage.delete(key: _kClientId);
    await _secureStorage.delete(key: _kAccessToken);
    await _secureStorage.delete(key: _kPin);
    await _secureStorage.delete(key: _kTotpSecret);
    await _secureStorage.delete(key: _kOptInTotp);
    await _secureStorage.delete(key: _kTokenExpiryMs);
  }

  static Future<DhanCredentials> loadCredentials() async {
    final clientId = await _secureStorage.read(key: _kClientId) ?? '';
    final accessToken = await _secureStorage.read(key: _kAccessToken) ?? '';
    final pin = await _secureStorage.read(key: _kPin) ?? '';
    final totpSecret = await _secureStorage.read(key: _kTotpSecret) ?? '';
    final expStr = await _secureStorage.read(key: _kTokenExpiryMs) ?? '0';
    return DhanCredentials(
      clientId: clientId,
      accessToken: accessToken,
      pin: pin,
      totpSecret: totpSecret,
      tokenExpiryMs: int.tryParse(expStr) ?? 0,
    );
  }

  static Future<DhanCredentials?> ensureValidSession() async {
    final creds = await loadCredentials();
    if (!creds.isConfigured) {
      lastAuthError = 'Broker credentials not configured.';
      return null;
    }
    return creds;
  }

  static Future<bool> verifyDhanSession(DhanCredentials creds) async {
    if (!creds.isConfigured) {
      lastAuthError = 'Missing client ID or access token.';
      return false;
    }
    try {
      final resp = await SafeBrokerHttp
          .get(
            Uri.parse('https://api.dhan.co/v2/fundlimit'),
            headers: {
              'Accept': 'application/json',
              'access-token': creds.accessToken,
              'client-id': creds.clientId,
            },
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        lastAuthError = '';
        return true;
      }
      // WP-1: Never expose resp.body in logs or UI
      lastAuthError = 'Authentication failed (HTTP ${resp.statusCode}).';
      return false;
    } catch (_) {
      lastAuthError = 'Network error while verifying broker session.';
      return false;
    }
  }

  /// RFC-6238 6-digit TOTP generator (HMAC-SHA1, 30-second window)
  static String generateTotpCode(String base32Secret, {int? timestampSec}) {
    final clean =
        base32Secret.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    if (clean.isEmpty) return '000000';
    final key = _decodeBase32(clean);
    final nowSec =
        timestampSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final counter = nowSec ~/ 30;

    final msg = Uint8List(8);
    int c = counter;
    for (int i = 7; i >= 0; i--) {
      msg[i] = c & 0xff;
      c = c >> 8;
    }

    final hmac = Hmac(sha1, key);
    final hash = hmac.convert(msg).bytes;
    final offset = hash[hash.length - 1] & 0x0f;
    final binary = ((hash[offset] & 0x7f) << 24) |
        ((hash[offset + 1] & 0xff) << 16) |
        ((hash[offset + 2] & 0xff) << 8) |
        (hash[offset + 3] & 0xff);
    final otp = binary % 1000000;
    return otp.toString().padLeft(6, '0');
  }

  static Uint8List _decodeBase32(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    int bits = 0;
    int value = 0;
    final out = <int>[];
    for (int i = 0; i < input.length; i++) {
      final idx = alphabet.indexOf(input[i]);
      if (idx < 0) continue;
      value = (value << 5) | idx;
      bits += 5;
      if (bits >= 8) {
        out.add((value >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return Uint8List.fromList(out);
  }
}
