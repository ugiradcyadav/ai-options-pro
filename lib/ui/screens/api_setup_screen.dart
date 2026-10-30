import 'package:flutter/material.dart';
import '../../core/totp_auth.dart';
import '../../data/dhan_data_engine.dart';
import '../../main.dart';

class ApiSetupScreen extends StatefulWidget {
  final VoidCallback onConnectedSuccess;
  final bool isFirstLaunch;

  const ApiSetupScreen({
    super.key,
    required this.onConnectedSuccess,
    this.isFirstLaunch = true,
  });

  @override
  State<ApiSetupScreen> createState() => _ApiSetupScreenState();
}

class _ApiSetupScreenState extends State<ApiSetupScreen> {
  final _clientIdCtrl = TextEditingController();
  final _pinSecretCtrl = TextEditingController();
  final _totpSecretCtrl = TextEditingController();
  final _accessTokenCtrl = TextEditingController();

  bool _loading = false;
  bool _isError = false;
  String _statusMessage = '';
  String _liveTotpPreview = '------';

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final creds = await TotpAuthManager.loadCredentials();
    if (!mounted) return;
    setState(() {
      _clientIdCtrl.text = creds.clientId;
      _pinSecretCtrl.text = creds.pinOrSecret;
      _totpSecretCtrl.text = creds.totpSecret;
      _accessTokenCtrl.text = creds.accessToken;
      if (creds.totpSecret.isNotEmpty) {
        _liveTotpPreview = TotpAuthManager.generateTotpCode(creds.totpSecret);
      }
    });
  }

  void _updateTotpPreview(String val) {
    if (val.trim().length >= 8) {
      setState(() {
        _liveTotpPreview = TotpAuthManager.generateTotpCode(val);
      });
    }
  }

  Future<void> _saveAndConnect() async {
    if (_clientIdCtrl.text.trim().isEmpty) {
      setState(() {
        _isError = true;
        _statusMessage = 'Error: Please enter your Dhan Client ID.';
      });
      return;
    }
    if (_totpSecretCtrl.text.trim().isEmpty &&
        _accessTokenCtrl.text.trim().isEmpty) {
      setState(() {
        _isError = true;
        _statusMessage =
            'Error: Enter either TOTP Secret + 6-digit PIN OR a Direct 24h Access Token.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _isError = false;
      _statusMessage =
          'Step 1/2: Authenticating with Dhan Server & verifying token...';
    });

    await TotpAuthManager.saveCredentials(
      clientId: _clientIdCtrl.text,
      pinOrSecret: _pinSecretCtrl.text,
      totpSecret: _totpSecretCtrl.text,
      accessToken: _accessTokenCtrl.text,
    );

    final refreshedCreds =
        await TotpAuthManager.ensureValidSession(forceRefresh: true);
    if (refreshedCreds.accessToken.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _isError = true;
        _statusMessage =
            'Dhan Token Generation Failed:\n${TotpAuthManager.lastServerMessage}\n\nTip: Check your 6-digit PIN & TOTP Secret, or paste a 24h Access Token from web.dhan.co -> DhanHQ Trading APIs.';
      });
      return;
    }

    setState(() {
      _statusMessage =
          'Step 2/2: Token acquired! Connecting to Dhan Live Feed & Fund API...';
    });

    final ok = await DhanDataEngine.instance.initializeAndStart();
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _loading = false;
        _isError = true;
        _statusMessage =
            'Dhan API Rejected Connection:\n${DhanDataEngine.instance.connectionStatusText}\n\nMake sure "Free Tier: Trading APIs" is subscribed on web.dhan.co.';
      });
      return;
    }

    setState(() {
      _loading = false;
      _isError = false;
      _statusMessage =
          'Verified & Connected to Dhan! Opening Live Terminal...';
    });

    widget.onConnectedSuccess();
    if (mounted && widget.isFirstLaunch) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainTerminalShell(appState: globalAppState),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080D1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1528),
        title: Text(
          widget.isFirstLaunch
              ? 'First-Launch Dhan API Setup'
              : 'Update Dhan API & Auto-TOTP',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF111C35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF1E325C)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.security, color: Color(0xFF2979FF), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Strict Dhan API Verification (Zero Bypass)',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 6),
                  Text(
                    'App verifies your live Dhan session before unlocking the terminal. Enter Client ID + PIN + TOTP Secret (or paste a 24h Access Token).',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildField(
              label: 'Dhan Client ID *',
              hint: 'e.g. 1101108080',
              controller: _clientIdCtrl,
              icon: Icons.badge_outlined,
            ),
            const SizedBox(height: 12),
            _buildField(
              label: 'Dhan 6-Digit Login PIN (for Auto-TOTP)',
              hint: 'Enter your 6-digit Dhan PIN',
              controller: _pinSecretCtrl,
              icon: Icons.lock_outline,
              obscure: true,
            ),
            const SizedBox(height: 12),
            _buildField(
              label: 'TOTP Base32 Secret Key (Auto-Login Every Day)',
              hint: 'e.g. TVTLGOXTN5OG3VUQ...',
              controller: _totpSecretCtrl,
              icon: Icons.timer_outlined,
              onChanged: _updateTotpPreview,
            ),
            if (_totpSecretCtrl.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  'Live Local RFC-6238 TOTP Code: $_liveTotpPreview',
                  style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            _buildField(
              label: 'Direct 24h Access Token (Optional / Instant Login)',
              hint: 'Paste JWT Access Token from web.dhan.co',
              controller: _accessTokenCtrl,
              icon: Icons.vpn_key_outlined,
            ),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _isError
                      ? const Color(0xFFD50000).withOpacity(0.15)
                      : const Color(0xFF00C853).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _isError
                        ? const Color(0xFFFF5252)
                        : const Color(0xFF00E676),
                  ),
                ),
                child: Text(
                  _statusMessage,
                  style: TextStyle(
                    color: _isError
                        ? const Color(0xFFFF5252)
                        : const Color(0xFF00E676),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1976D2),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _loading ? null : _saveAndConnect,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.bolt),
                label: Text(
                  _loading
                      ? 'Verifying with Dhan Server...'
                      : 'Verify & Start Live Data Engine',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required IconData icon,
    bool obscure = false,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          onChanged: onChanged,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
            prefixIcon: Icon(icon, color: Colors.white54, size: 18),
            filled: true,
            fillColor: const Color(0xFF111C35),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF1E325C)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF2979FF)),
            ),
          ),
        ),
      ],
    );
  }
}
