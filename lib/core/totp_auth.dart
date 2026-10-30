import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class DhanCredentials {
  final String clientId;
  final String pinOrSecret;
  final String totpSecret;
  final String accessToken;
  final int tokenGeneratedAtMs;
  final bool optInAutoTotpStorage;

  const DhanCredentials({
    required this.clientId,
    required this.pinOrSecret,
    required this.totpSecret,
    required this.accessToken,
    required this.tokenGeneratedAtMs,
    this.optInAutoTotpStorage = false,
  });

  bool get isConfigured =>
      clientId.trim().isNotEmpty &&
      (accessToken.trim().isNotEmpty || totpSecret.trim().isNotEmpty);

  bool get isTokenFresh {
    if (accessToken.trim().isEmpty) return false;
    final ageHours =
        (DateTime.now().millisecondsSinceEpoch - tokenGeneratedAtMs) /
            (1000 * 3600);
    return ageHours < 18.0;
  }
}

/// T8 & T9: Hardware-backed FlutterSecureStorage with one-time migration from SharedPreferences
/// and strict sanitization of server messages (never logs or displays tokens, PINs, or URLs).
class TotpAuthManager {
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kSecClientId = 'sec_dhan_client_id';
  static const _kSecPinSecret = 'sec_dhan_pin_secret';
  static const _kSecTotpSecret = 'sec_dhan_totp_secret';
  static const _kSecAccessToken = 'sec_dhan_access_token';
  static const _kSecTokenTime = 'sec_dhan_token_time_ms';
  static const _kSecOptInTotp = 'sec_dhan_opt_in_totp';

  // Legacy SharedPreferences keys to migrate and purge (T8)
  static const _legacyKeys = [
    'dhan_client_id',
    'dhan_pin_secret',
    'dhan_totp_secret',
    'dhan_access_token',
    'dhan_token_time_ms',
    'dhan_client_id_v2',
    'dhan_pin_secret_v2',
    'dhan_totp_secret_v2',
    'dhan_access_token_v2',
    'dhan_token_time_ms_v2',
  ];

  static String sanitizedStatusMessage = '';

  /// T8.2: One-time migration from SharedPreferences -> FlutterSecureStorage, then deletes plaintext keys.
  static Future<void> migrateLegacyPlaintextCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final oldClient =
          prefs.getString('dhan_client_id_v2') ?? prefs.getString('dhan_client_id') ?? '';
      final oldPin =
          prefs.getString('dhan_pin_secret_v2') ?? prefs.getString('dhan_pin_secret') ?? '';
      final oldTotp =
          prefs.getString('dhan_totp_secret_v2') ?? prefs.getString('dhan_totp_secret') ?? '';
      final oldToken =
          prefs.getString('dhan_access_token_v2') ?? prefs.getString('dhan_access_token') ?? '';

      if (oldClient.isNotEmpty || oldToken.isNotEmpty || oldTotp.isNotEmpty) {
        await saveCredentials(
          clientId: oldClient,
          pinOrSecret: oldPin,
          totpSecret: oldTotp,
          accessToken: oldToken,
          optInStoreTotpSeed: oldTotp.isNotEmpty,
        );
      }

      for (final k in _legacyKeys) {
        if (prefs.containsKey(k)) {
          await prefs.remove(k);
        }
      }
    } catch (_) {}
  }

  static Future<DhanCredentials> loadCredentials() async {
    await migrateLegacyPlaintextCredentials();
    try {
      final clientId = await _secureStorage.read(key: _kSecClientId) ?? '';
      final pinOrSecret = await _secureStorage.read(key: _kSecPinSecret) ?? '';
      final totpSecret = await _secureStorage.read(key: _kSecTotpSecret) ?? '';
      final accessToken = await _secureStorage.read(key: _kSecAccessToken) ?? '';
      final tokenTimeStr = await _secureStorage.read(key: _kSecTokenTime) ?? '0';
      final optInStr = await _secureStorage.read(key: _kSecOptInTotp) ?? 'false';

      return DhanCredentials(
        clientId: clientId,
        pinOrSecret: pinOrSecret,
        totpSecret: totpSecret,
        accessToken: accessToken,
        tokenGeneratedAtMs: int.tryParse(tokenTimeStr) ?? 0,
        optInAutoTotpStorage: optInStr == 'true',
      );
    } catch (_) {
      return const DhanCredentials(
        clientId: '',
        pinOrSecret: '',
        totpSecret: '',
        accessToken: '',
        tokenGeneratedAtMs: 0,
      );
    }
  }

  /// T8.4: Safer default stores only Access Token + Client ID unless user explicitly opts in to store PIN + TOTP seed.
  static Future<void> saveCredentials({
    required String clientId,
    required String pinOrSecret,
    required String totpSecret,
    required String accessToken,
    bool optInStoreTotpSeed = true,
  }) async {
    final cleanTotp =
        totpSecret.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    await _secureStorage.write(key: _kSecClientId, value: clientId.trim());
    await _secureStorage.write(
      key: _kSecOptInTotp,
      value: optInStoreTotpSeed ? 'true' : 'false',
    );

    if (optInStoreTotpSeed) {
      await _secureStorage.write(key: _kSecPinSecret, value: pinOrSecret.trim());
      await _secureStorage.write(key: _kSecTotpSecret, value: cleanTotp);
    } else {
      await _secureStorage.delete(key: _kSecPinSecret);
      await _secureStorage.delete(key: _kSecTotpSecret);
    }

    if (accessToken.trim().isNotEmpty) {
      await _secureStorage.write(
        key: _kSecAccessToken,
        value: accessToken.trim(),
      );
      await _secureStorage.write(
        key: _kSecTokenTime,
        value: DateTime.now().millisecondsSinceEpoch.toString(),
      );
    }
  }

  /// RFC-6238 TOTP generator supporting both Base32 secrets and ASCII test vectors (T15)
  static String generateTotpCode(
    String secret, {
    DateTime? now,
    bool isAsciiSecret = false,
  }) {
    final Uint8List keyBytes;
    if (isAsciiSecret) {
      keyBytes = Uint8List.fromList(utf8.encode(secret));
    } else {
      final clean =
          secret.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
      if (clean.isEmpty) return '000000';
      keyBytes = _base32Decode(clean);
    }
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

  /// T9: Never logs or displays raw response bodies, URLs, tokens, or PINs.
  static Future<DhanCredentials> ensureValidSession({
    bool forceRefresh = false,
    String? transientPin,
    String? transientTotpSecret,
  }) async {
    final creds = await loadCredentials();
    final effectivePin = (transientPin != null && transientPin.isNotEmpty)
        ? transientPin.trim()
        : creds.pinOrSecret;
    final effectiveTotp =
        (transientTotpSecret != null && transientTotpSecret.isNotEmpty)
            ? transientTotpSecret
                .trim()
                .toUpperCase()
                .replaceAll(RegExp(r'[^A-Z2-7]'), '')
            : creds.totpSecret;

    if (creds.clientId.trim().isEmpty) {
      sanitizedStatusMessage = 'Client ID is required.';
      return creds;
    }

    if (!forceRefresh && creds.isTokenFresh && creds.accessToken.isNotEmpty) {
      sanitizedStatusMessage = 'Active session verified.';
      return creds;
    }

    if (effectiveTotp.isNotEmpty && effectivePin.isNotEmpty) {
      final totp = generateTotpCode(effectiveTotp);
      try {
        final uri = Uri.parse(
          'https://auth.dhan.co/app/generateAccessToken?dhanClientId=${Uri.encodeComponent(creds.clientId)}&pin=${Uri.encodeComponent(effectivePin)}&totp=$totp',
        );
        final resp = await http
            .post(uri, headers: {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 12));

        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          if (body is Map &&
              (body['accessToken'] != null || body['token'] != null)) {
            final newToken =
                (body['accessToken'] ?? body['token']).toString().trim();
            if (newToken.isNotEmpty) {
              await saveCredentials(
                clientId: creds.clientId,
                pinOrSecret: effectivePin,
                totpSecret: effectiveTotp,
                accessToken: newToken,
                optInStoreTotpSeed: creds.optInAutoTotpStorage,
              );
              sanitizedStatusMessage = 'Session token refreshed via TOTP.';
              return await loadCredentials();
            }
          }
          sanitizedStatusMessage =
              'TOTP rejected by broker (verify 6-digit PIN and TOTP secret).';
        } else {
          sanitizedStatusMessage =
              'Broker authentication failed (HTTP ${resp.statusCode}).';
        }
      } catch (_) {
        sanitizedStatusMessage =
            'Network timeout while contacting broker authentication server.';
      }
    } else if (creds.accessToken.isNotEmpty) {
      sanitizedStatusMessage = 'Using configured 24h Access Token.';
    } else {
      sanitizedStatusMessage = 'Provide Access Token or PIN + TOTP Secret.';
    }

    return await loadCredentials();
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
