import 'package:flutter/material.dart';
import 'core/totp_auth.dart';
import 'engine/strategy_settings.dart';
import 'data/angel_smartapi_engine.dart';
import 'state/app_state.dart';
import 'ui/screens/api_setup_screen.dart';
import 'ui/screens/backtest_screen.dart';
import 'ui/screens/charts_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/oi_analysis_screen.dart';
import 'ui/screens/option_chain_screen.dart';
import 'ui/screens/positions_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/screens/signals_screen.dart';

final AppState globalAppState = AppState();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AiOptionsProApp());
}

class AiOptionsProApp extends StatefulWidget {
  const AiOptionsProApp({super.key});

  @override
  State<AiOptionsProApp> createState() => _AiOptionsProAppState();
}

class _AiOptionsProAppState extends State<AiOptionsProApp> {
  bool _checkingAuth = true;
  bool _needsFirstLaunchSetup = false;

  @override
  void initState() {
    super.initState();
    _checkFirstLaunchGate();
  }

  Future<void> _checkFirstLaunchGate() async {
    try {
      await AngelSmartApiEngine.instance.loadSavedConfig();
      final creds = await TotpAuthManager.loadCredentials();
      if (!creds.isConfigured) {
        if (mounted) {
          setState(() {
            _needsFirstLaunchSetup = true;
            _checkingAuth = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _needsFirstLaunchSetup = false;
            _checkingAuth = false;
          });
        }
        // Start live engine non-blocking so Dashboard opens immediately
        globalAppState.initializeApp();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsFirstLaunchSetup = true;
          _checkingAuth = false;
        });
      }
    }
  }

  void _unlockAndOpenDashboard() {
    setState(() {
      _needsFirstLaunchSetup = false;
      _checkingAuth = false;
    });
    globalAppState.initializeApp();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Options Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080D1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1976D2),
          secondary: Color(0xFF00E676),
        ),
      ),
      home: _checkingAuth
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            )
          : _needsFirstLaunchSetup
              ? ApiSetupScreen(
                  isFirstLaunch: true,
                  onConnectedSuccess: _unlockAndOpenDashboard,
                )
              : MainTerminalShell(appState: globalAppState),
    );
  }
}

class MainTerminalShell extends StatefulWidget {
  final AppState appState;

  const MainTerminalShell({super.key, required this.appState});

  @override
  State<MainTerminalShell> createState() => _MainTerminalShellState();
}

class _MainTerminalShellState extends State<MainTerminalShell> {
  int _bottomNavIndex = 0;
  String _analyticsSubView = 'oi_analysis';
  String _moreSubView = 'settings';

  void _handleQuickAction(String dest) {
    setState(() {
      if (dest == 'oi_analysis' || dest == 'option_chain' || dest == 'charts') {
        _analyticsSubView = dest;
        _bottomNavIndex = 1;
      } else if (dest == 'signals') {
        _bottomNavIndex = 2;
      } else if (dest == 'positions') {
        _bottomNavIndex = 3;
      } else if (dest == 'backtest') {
        _moreSubView = 'backtest';
        _bottomNavIndex = 4;
      } else if (dest == 'settings') {
        _moreSubView = 'settings';
        _bottomNavIndex = 4;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        return Scaffold(
          appBar: _bottomNavIndex == 0
              ? null
              : AppBar(
                  backgroundColor: const Color(0xFF0B1325),
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => setState(() => _bottomNavIndex = 0),
                  ),
                  title: Text(
                    _currentHeaderTitle(),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  actions: _buildHeaderSwitcher(),
                ),
          body: SafeArea(child: _buildBody()),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _bottomNavIndex,
            onTap: (i) => setState(() => _bottomNavIndex = i),
            type: BottomNavigationBarType.fixed,
            backgroundColor: const Color(0xFF0B1325),
            selectedItemColor: const Color(0xFF40C4FF),
            unselectedItemColor: Colors.white54,
            selectedFontSize: 11,
            unselectedFontSize: 11,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.bar_chart_rounded),
                label: 'Charts',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.graphic_eq_rounded),
                label: 'Signals',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_outlined),
                label: 'Orders',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.menu_rounded),
                label: 'More',
              ),
            ],
          ),
        );
      },
    );
  }

  String _currentHeaderTitle() {
    if (_bottomNavIndex == 1) {
      if (_analyticsSubView == 'oi_analysis') return 'OI Analysis';
      if (_analyticsSubView == 'option_chain') return 'Option Chain';
      return 'Charts';
    }
    if (_bottomNavIndex == 2) return 'Signals';
    if (_bottomNavIndex == 3) return 'Positions';
    if (_bottomNavIndex == 4) {
      return _moreSubView == 'backtest' ? 'Backtesting' : 'Settings';
    }
    return 'AI Options Pro';
  }

  List<Widget> _buildHeaderSwitcher() {
    if (_bottomNavIndex == 1) {
      return [
        TextButton(
          onPressed: () => setState(() => _analyticsSubView = 'oi_analysis'),
          child: Text(
            'OI',
            style: TextStyle(
              color: _analyticsSubView == 'oi_analysis'
                  ? const Color(0xFF40C4FF)
                  : Colors.white54,
              fontSize: 12,
            ),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _analyticsSubView = 'option_chain'),
          child: Text(
            'Chain',
            style: TextStyle(
              color: _analyticsSubView == 'option_chain'
                  ? const Color(0xFF40C4FF)
                  : Colors.white54,
              fontSize: 12,
            ),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _analyticsSubView = 'charts'),
          child: Text(
            'Charts',
            style: TextStyle(
              color: _analyticsSubView == 'charts'
                  ? const Color(0xFF40C4FF)
                  : Colors.white54,
              fontSize: 12,
            ),
          ),
        ),
      ];
    }
    if (_bottomNavIndex == 4) {
      return [
        TextButton(
          onPressed: () => setState(() => _moreSubView = 'backtest'),
          child: Text(
            'Backtest',
            style: TextStyle(
              color: _moreSubView == 'backtest'
                  ? const Color(0xFF40C4FF)
                  : Colors.white54,
              fontSize: 12,
            ),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _moreSubView = 'settings'),
          child: Text(
            'Settings',
            style: TextStyle(
              color: _moreSubView == 'settings'
                  ? const Color(0xFF40C4FF)
                  : Colors.white54,
              fontSize: 12,
            ),
          ),
        ),
      ];
    }
    return const [];
  }

  Widget _buildBody() {
    switch (_bottomNavIndex) {
      case 0:
        return HomeScreen(
          appState: widget.appState,
          onNavigateQuickAction: _handleQuickAction,
        );
      case 1:
        if (_analyticsSubView == 'oi_analysis') {
          return OiAnalysisScreen(appState: widget.appState);
        } else if (_analyticsSubView == 'option_chain') {
          return OptionChainScreen(appState: widget.appState);
        }
        return ChartsScreen(appState: widget.appState);
      case 2:
        return SignalsScreen(appState: widget.appState);
      case 3:
        return PositionsScreen(appState: widget.appState);
      case 4:
        return _moreSubView == 'backtest'
            ? BacktestScreen(appState: widget.appState)
            : SettingsScreen(appState: widget.appState);
      default:
        return HomeScreen(
          appState: widget.appState,
          onNavigateQuickAction: _handleQuickAction,
        );
    }
  }
}
