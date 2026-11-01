import 'package:flutter/material.dart';
import '../../core/totp_auth.dart';
import '../../data/angel_smartapi_engine.dart';
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
  String _selectedBroker = 'ANGEL'; // 'ANGEL' or 'DHAN'

  // Angel One Controllers
  final _angelApiKeyCtrl = TextEditingController();
  final _angelClientCodeCtrl = TextEditingController();
  final _angelPinCtrl = TextEditingController();
  final _angelTotpSecretCtrl = TextEditingController();

  // Dhan Controllers
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
    final broker = await AngelSmartApiEngine.getSelectedBroker();
    await AngelSmartApiEngine.instance.loadSavedConfig();
    final dhanCreds = await TotpAuthManager.loadCredentials();
    if (!mounted) return;
    setState(() {
      _selectedBroker = broker.toString();
      _angelApiKeyCtrl.text = AngelSmartApiEngine.instance.apiKey;
      _angelClientCodeCtrl.text = AngelSmartApiEngine.instance.clientCode;
      _angelPinCtrl.text = AngelSmartApiEngine.instance.pin;
      _angelTotpSecretCtrl.text = AngelSmartApiEngine.instance.totpSecret;

      _clientIdCtrl.text = dhanCreds.clientId;
      _pinSecretCtrl.text = dhanCreds.pinOrSecret;
      _totpSecretCtrl.text = dhanCreds.totpSecret;
      _accessTokenCtrl.text = dhanCreds.accessToken;

      final activeSecret = _selectedBroker == 'ANGEL'
          ? _angelTotpSecretCtrl.text
          : _totpSecretCtrl.text;
      if (activeSecret.isNotEmpty) {
        _liveTotpPreview = TotpAuthManager.generateTotpCode(activeSecret);
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
    setState(() {
      _loading = true;
      _isError = false;
      _statusMessage = _selectedBroker == 'ANGEL'
          ? 'Connecting to Angel One SmartAPI (Free Live Market Feed)...'
          : 'Connecting to Dhan API & Live Option Chain...';
    });

    if (_selectedBroker == 'ANGEL') {
      if (_angelApiKeyCtrl.text.trim().isEmpty ||
          _angelClientCodeCtrl.text.trim().isEmpty ||
          _angelPinCtrl.text.trim().isEmpty ||
          _angelTotpSecretCtrl.text.trim().isEmpty) {
        setState(() {
          _loading = false;
          _isError = true;
          _statusMessage =
              'Please fill all 4 Angel One fields (API Key, Client Code, PIN, and TOTP Secret).';
        });
        return;
      }

      final ok = await AngelSmartApiEngine.instance.loginAndSave(
        newApiKey: _angelApiKeyCtrl.text,
        newClientCode: _angelClientCodeCtrl.text,
        newPin: _angelPinCtrl.text,
        newTotpSecret: _angelTotpSecretCtrl.text,
      );

      if (!ok) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _isError = true;
          _statusMessage = AngelSmartApiEngine.instance.lastError;
        });
        return;
      }
    } else {
      await AngelSmartApiEngine.setSelectedBroker('DHAN');
      await TotpAuthManager.saveCredentials(
        clientId: _clientIdCtrl.text,
        pinOrSecret: _pinSecretCtrl.text,
        totpSecret: _totpSecretCtrl.text,
        accessToken: _accessTokenCtrl.text,
      );
      await TotpAuthManager.ensureValidSession(forceRefresh: true);
    }

    DhanDataEngine.instance.initializeAndStart();
    if (!mounted) return;

    setState(() {
      _loading = false;
      _isError = false;
      _statusMessage = 'Connected! Opening Live Option Terminal...';
    });

    widget.onConnectedSuccess();
    if (mounted) {
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
        title: const Text(
          'Broker API & Auto-TOTP Setup',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Broker Selector Tabs (Angel One Free Live Data vs Dhan)
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedBroker = 'ANGEL'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _selectedBroker == 'ANGEL'
                            ? const Color(0xFF00C853)
                            : const Color(0xFF111C35),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF1E325C)),
                      ),
                      child: const Text(
                        'Angel One (Free Data)',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedBroker = 'DHAN'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _selectedBroker == 'DHAN'
                            ? const Color(0xFF1976D2)
                            : const Color(0xFF111C35),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF1E325C)),
                      ),
                      child: const Text(
                        'Dhan API + NSE Feed',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (_selectedBroker == 'ANGEL') ...[
              _buildField(
                label: 'Angel One SmartAPI Key *',
                hint: '8-char API Key from smartapi.angelbroking.com',
                controller: _angelApiKeyCtrl,
                icon: Icons.vpn_key_outlined,
              ),
              const SizedBox(height: 12),
              _buildField(
                label: 'Angel One Client Code *',
                hint: 'e.g. A123456 or S123456',
                controller: _angelClientCodeCtrl,
                icon: Icons.badge_outlined,
              ),
              const SizedBox(height: 12),
              _buildField(
                label: 'Angel One 4-Digit Login PIN *',
                hint: 'Enter your Angel One MPIN',
                controller: _angelPinCtrl,
                icon: Icons.lock_outline,
                obscure: true,
              ),
              const SizedBox(height: 12),
              _buildField(
                label: 'Angel One TOTP Secret Key (26-char Base32) *',
                hint: 'From smartapi.angelbroking.com -> Enable TOTP',
                controller: _angelTotpSecretCtrl,
                icon: Icons.timer_outlined,
                onChanged: _updateTotpPreview,
              ),
            ] else ...[
              _buildField(
                label: 'Dhan Client ID *',
                hint: 'e.g. 1101108080',
                controller: _clientIdCtrl,
                icon: Icons.badge_outlined,
              ),
              const SizedBox(height: 12),
              _buildField(
                label: 'Dhan 6-Digit Login PIN',
                hint: 'Enter your 6-digit Dhan PIN',
                controller: _pinSecretCtrl,
                icon: Icons.lock_outline,
                obscure: true,
              ),
              const SizedBox(height: 12),
              _buildField(
                label: 'Dhan TOTP Base32 Secret Key',
                hint: 'e.g. TVTLGOXTN5OG3VUQ...',
                controller: _totpSecretCtrl,
                icon: Icons.timer_outlined,
                onChanged: _updateTotpPreview,
              ),
              const SizedBox(height: 12),
              _buildField(
                label: 'Direct 24h Access Token (Optional)',
                hint: 'Paste JWT Access Token',
                controller: _accessTokenCtrl,
                icon: Icons.vpn_key_outlined,
              ),
            ],

            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                'Live Local RFC-6238 TOTP Code: $_liveTotpPreview',
                style: const TextStyle(
                  color: Color(0xFF00E676),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _selectedBroker == 'ANGEL'
                      ? const Color(0xFF00C853)
                      : const Color(0xFF1976D2),
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
                      ? 'Connecting Live Feed...'
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
