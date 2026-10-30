import '../../main.dart';
import 'package:flutter/material.dart';
import '../../core/totp_auth.dart';
import '../../data/dhan_data_engine.dart';

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
  String _statusMessage = '';
  String _liveTotpPreview = '------';

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final creds = await TotpAuthManager.loadCredentials();
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
      setState(() => _statusMessage = 'Please enter your Dhan Client ID.');
      return;
    }
    if (_totpSecretCtrl.text.trim().isEmpty &&
        _accessTokenCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage =
          'Enter either TOTP Secret + PIN (for auto daily login) or Access Token.');
      return;
    }

    setState(() {
      _loading = true;
      _statusMessage = 'Generating TOTP & verifying Dhan live session...';
    });

    await TotpAuthManager.saveCredentials(
      clientId: _clientIdCtrl.text,
      pinOrSecret: _pinSecretCtrl.text,
      totpSecret: _totpSecretCtrl.text,
      accessToken: _accessTokenCtrl.text,
    );

    final ok = await DhanDataEngine.instance.initializeAndStart();
    if (!mounted) return;

    setState(() {
      _loading = false;
      _statusMessage = ok
          ? 'Connected to Dhan! Starting 1m Forever Engine...'
          : 'Credentials saved. Verify active market token or TOTP key.';
    });

    widget.onConnectedSuccess();
    if (mounted && widget.isFirstLaunch) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => MainTerminalShell(appState: globalAppState)));
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
                        'On-Device Encrypted Auto-TOTP Auth',
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
                    'Credentials are stored in Android Hardware Keystore (AES-256). App automatically refreshes your 24h Dhan token every morning using your TOTP secret.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildField(
              label: 'Dhan Client ID *',
              hint: 'e.g. 1100223344',
              controller: _clientIdCtrl,
              icon: Icons.badge_outlined,
            ),
            const SizedBox(height: 12),
            _buildField(
              label: 'Dhan 6-Digit PIN / API Secret (for Auto-TOTP)',
              hint: 'Enter your Dhan PIN',
              controller: _pinSecretCtrl,
              icon: Icons.lock_outline,
              obscure: true,
            ),
            const SizedBox(height: 12),
            _buildField(
              label: 'TOTP Base32 Secret Key (Auto-Login Every Day)',
              hint: 'e.g. JBSWY3DPEHPK3PXP...',
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
              label: 'Direct 24h Access Token (Optional Fallback)',
              hint: 'Paste JWT Access Token if not using TOTP',
              controller: _accessTokenCtrl,
              icon: Icons.vpn_key_outlined,
            ),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                _statusMessage,
                style: const TextStyle(color: Color(0xFFFFAB00), fontSize: 12),
              ),
            ],
            const SizedBox(height: 22),
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
                      ? 'Connecting to Dhan Feed...'
                      : 'Save & Start Live Data Engine',
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
