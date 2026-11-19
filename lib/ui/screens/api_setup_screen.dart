import 'package:flutter/material.dart';
import '../../core/totp_auth.dart';
import '../../data/angel_smartapi_engine.dart';
import '../../data/dhan_data_engine.dart';
import '../theme/quant_theme.dart';

class ApiSetupScreen extends StatefulWidget {
  final VoidCallback onConnectedSuccess;

  const ApiSetupScreen({
    super.key,
    required this.onConnectedSuccess,
  });

  @override
  State<ApiSetupScreen> createState() => _ApiSetupScreenState();
}

class _ApiSetupScreenState extends State<ApiSetupScreen> {
  String _selectedBroker = 'ANGEL'; // 'ANGEL' | 'DHAN'
  bool _isBusy = false;
  String _statusMessage = '';
  bool _statusIsError = false;

  // Angel One fields
  final _angelApiKeyCtrl = TextEditingController();
  final _angelClientCodeCtrl = TextEditingController();
  final _angelPinCtrl = TextEditingController();
  final _angelOtpCtrl = TextEditingController();
  final _angelTotpSeedCtrl = TextEditingController();
  bool _angelOptInTotp = false;

  // Dhan fields
  final _dhanClientIdCtrl = TextEditingController();
  final _dhanAccessTokenCtrl = TextEditingController();
  final _dhanPinCtrl = TextEditingController();
  final _dhanTotpSeedCtrl = TextEditingController();
  bool _dhanOptInTotp = false;

  @override
  void initState() {
    super.initState();
    _loadNonSecretFields();
  }

  Future<void> _loadNonSecretFields() async {
    final broker = await AngelSmartApiEngine.getSelectedBroker();
    await AngelSmartApiEngine.instance.loadSavedConfig();
    final dhanCreds = await TotpAuthManager.loadCredentials();

    if (!mounted) return;
    setState(() {
      _selectedBroker = broker;
      _angelApiKeyCtrl.text = AngelSmartApiEngine.instance.apiKey;
      _angelClientCodeCtrl.text = AngelSmartApiEngine.instance.clientCode;
      _dhanClientIdCtrl.text = dhanCreds.clientId;
    });
  }

  Future<void> _connectAngelOne() async {
    setState(() {
      _isBusy = true;
      _statusMessage = 'Authenticating Angel One SmartAPI...';
      _statusIsError = false;
    });

    final ok = await AngelSmartApiEngine.instance.loginAndSave(
      newApiKey: _angelApiKeyCtrl.text,
      newClientCode: _angelClientCodeCtrl.text,
      newPin: _angelPinCtrl.text,
      newTotpSecret: _angelOptInTotp ? _angelTotpSeedCtrl.text : '',
      oneTimeOtp: _angelOtpCtrl.text,
      optInStoreTotp: _angelOptInTotp,
    );

    if (ok) {
      await DhanDataEngine.instance.initializeAndStart();
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _statusMessage = 'Angel One connected & session stored securely.';
        _statusIsError = false;
      });
      widget.onConnectedSuccess();
      if (mounted) Navigator.of(context).pop();
    } else {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _statusMessage = AngelSmartApiEngine.instance.lastError.isNotEmpty
            ? AngelSmartApiEngine.instance.lastError
            : 'Angel One authentication failed.';
        _statusIsError = true;
      });
    }
  }

  Future<void> _connectDhan() async {
    setState(() {
      _isBusy = true;
      _statusMessage = 'Verifying Dhan API session...';
      _statusIsError = false;
    });

    await AngelSmartApiEngine.setSelectedBroker('DHAN');
    await TotpAuthManager.saveCredentials(
      clientId: _dhanClientIdCtrl.text,
      accessToken: _dhanAccessTokenCtrl.text,
      pin: _dhanOptInTotp ? '' : _dhanPinCtrl.text,
      totpSecret: _dhanOptInTotp ? _dhanTotpSeedCtrl.text : '',
      optInStoreTotp: _dhanOptInTotp,
    );

    final creds = await TotpAuthManager.ensureValidSession();
    final ok =
        creds != null && await TotpAuthManager.verifyDhanSession(creds);

    if (ok) {
      await DhanDataEngine.instance.initializeAndStart();
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _statusMessage = 'Dhan session verified & saved in encrypted storage.';
        _statusIsError = false;
      });
      widget.onConnectedSuccess();
      if (mounted) Navigator.of(context).pop();
    } else {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _statusMessage = TotpAuthManager.lastAuthError.isNotEmpty
            ? TotpAuthManager.lastAuthError
            : 'Dhan authentication failed.';
        _statusIsError = true;
      });
    }
  }

  @override
  void dispose() {
    _angelApiKeyCtrl.dispose();
    _angelClientCodeCtrl.dispose();
    _angelPinCtrl.dispose();
    _angelOtpCtrl.dispose();
    _angelTotpSeedCtrl.dispose();
    _dhanClientIdCtrl.dispose();
    _dhanAccessTokenCtrl.dispose();
    _dhanPinCtrl.dispose();
    _dhanTotpSeedCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: QuantTheme.bgMain,
      appBar: AppBar(
        title: const Text('Broker API Setup (Encrypted)'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Broker Selector
            Row(
              children: ['ANGEL', 'DHAN'].map((b) {
                final active = _selectedBroker == b;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedBroker = b),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: active ? QuantTheme.accent : QuantTheme.bgPanel,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: active ? QuantTheme.accent : QuantTheme.border,
                        ),
                      ),
                      child: Text(
                        b == 'ANGEL' ? 'Angel One SmartAPI' : 'Dhan HQ API',
                        style: QuantTheme.heading(
                          size: 12,
                          color: active
                              ? QuantTheme.bgMain
                              : QuantTheme.textPrimary,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),

            QuantPanel(
              backgroundColor: QuantTheme.bgSecondary,
              child: Text(
                'Security Policy (WP-1): Credentials are stored in Android EncryptedSharedPreferences. PIN and TOTP seed are never stored together.',
                style: QuantTheme.label(size: 10, color: QuantTheme.accent),
              ),
            ),
            const SizedBox(height: 12),

            if (_selectedBroker == 'ANGEL') ...[
              _inputField('Angel API Key', _angelApiKeyCtrl),
              const SizedBox(height: 10),
              _inputField('Client Code', _angelClientCodeCtrl),
              const SizedBox(height: 10),
              _inputField('MPIN (Used for login)', _angelPinCtrl,
                  obscure: true),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Opt-in: Store TOTP Seed (Disables PIN storage)',
                    style: QuantTheme.label(
                        size: 11, color: QuantTheme.textPrimary)),
                value: _angelOptInTotp,
                activeColor: QuantTheme.accent,
                onChanged: (v) => setState(() => _angelOptInTotp = v),
              ),
              if (_angelOptInTotp)
                _inputField('TOTP Base32 Secret Seed', _angelTotpSeedCtrl,
                    obscure: true)
              else
                _inputField('Current 6-Digit Authenticator OTP', _angelOtpCtrl,
                    keyboardType: TextInputType.number),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: QuantTheme.positive,
                    foregroundColor: QuantTheme.bgMain,
                  ),
                  onPressed: _isBusy ? null : _connectAngelOne,
                  child: Text(
                    _isBusy
                        ? 'Connecting...'
                        : 'Verify & Save Angel One Session',
                    style:
                        QuantTheme.heading(size: 12, color: QuantTheme.bgMain),
                  ),
                ),
              ),
            ] else ...[
              _inputField('Dhan Client ID', _dhanClientIdCtrl),
              const SizedBox(height: 10),
              _inputField('Dhan Access Token', _dhanAccessTokenCtrl,
                  obscure: true),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Opt-in: Store TOTP Seed (Disables PIN storage)',
                    style: QuantTheme.label(
                        size: 11, color: QuantTheme.textPrimary)),
                value: _dhanOptInTotp,
                activeColor: QuantTheme.accent,
                onChanged: (v) => setState(() => _dhanOptInTotp = v),
              ),
              if (_dhanOptInTotp)
                _inputField('TOTP Base32 Secret Seed', _dhanTotpSeedCtrl,
                    obscure: true)
              else
                _inputField('PIN (Optional)', _dhanPinCtrl, obscure: true),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: QuantTheme.accent,
                    foregroundColor: QuantTheme.bgMain,
                  ),
                  onPressed: _isBusy ? null : _connectDhan,
                  child: Text(
                    _isBusy ? 'Verifying...' : 'Verify & Save Dhan Session',
                    style:
                        QuantTheme.heading(size: 12, color: QuantTheme.bgMain),
                  ),
                ),
              ),
            ],

            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 12),
              QuantPanel(
                borderColor: _statusIsError
                    ? QuantTheme.negative
                    : QuantTheme.positive,
                child: Text(
                  _statusMessage,
                  style: QuantTheme.mono(
                    size: 11,
                    color: _statusIsError
                        ? QuantTheme.negative
                        : QuantTheme.positive,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _inputField(
    String label,
    TextEditingController ctrl, {
    bool obscure = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: QuantTheme.mono(size: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: QuantTheme.label(size: 11),
        filled: true,
        fillColor: QuantTheme.bgPanel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: QuantTheme.border),
        ),
      ),
    );
  }
}
