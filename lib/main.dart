import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'data/dhan_data_engine.dart';
import 'data/forever_db.dart';
import 'engine/strategy_settings.dart';
import 'state/app_state.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/option_chain_screen.dart';
import 'ui/screens/positions_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/screens/signals_screen.dart';
import 'ui/theme/quant_theme.dart';

final AppState globalAppState = AppState();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // WP-9: Show UI shell immediately; run DB & broker initialization in background
  runApp(const AiOptionsProApp());
  unawaited(_bootstrapOnDevice());
}

Future<void> _bootstrapOnDevice() async {
  try {
    await ForeverDatabase.instance.database;
    await StrategySettingsEngine.instance.load();
    await globalAppState.initialize();
  } catch (e) {
    debugPrint('Background bootstrap note: $e');
  }
}

class AiOptionsProApp extends StatelessWidget {
  const AiOptionsProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Options Pro — Quant Terminal',
      debugShowCheckedModeBanner: false,
      theme: QuantTheme.buildTheme(),
      home: MainTerminalShell(appState: globalAppState),
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
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onStateChanged);
    DhanDataEngine.instance.disposeEngine();
    super.dispose();
  }

  void _switchToTab(int idx) {
    setState(() => _currentIndex = idx.clamp(0, 4));
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(appState: widget.appState, onNavigateTab: _switchToTab),
      OptionChainScreen(appState: widget.appState),
      SignalsScreen(appState: widget.appState),
      PositionsScreen(appState: widget.appState),
      SettingsScreen(appState: widget.appState),
    ];

    return Scaffold(
      backgroundColor: QuantTheme.bgMain,
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: pages,
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: QuantTheme.bgSecondary,
          border: Border(top: BorderSide(color: QuantTheme.border, width: 1.0)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: _switchToTab,
          type: BottomNavigationBarType.fixed,
          backgroundColor: QuantTheme.bgSecondary,
          selectedItemColor: QuantTheme.accent,
          unselectedItemColor: QuantTheme.textSecondary,
          selectedLabelStyle:
              QuantTheme.heading(size: 10, color: QuantTheme.accent),
          unselectedLabelStyle: QuantTheme.label(size: 10),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined, size: 20),
              activeIcon: Icon(Icons.dashboard, size: 20),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.candlestick_chart_outlined, size: 20),
              activeIcon: Icon(Icons.candlestick_chart, size: 20),
              label: 'Market',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.graphic_eq, size: 20),
              activeIcon: Icon(Icons.radar, size: 20),
              label: 'Signals',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.account_balance_wallet_outlined, size: 20),
              activeIcon: Icon(Icons.account_balance_wallet, size: 20),
              label: 'Orders',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.biotech_outlined, size: 20),
              activeIcon: Icon(Icons.biotech, size: 20),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}
