import 'package:flutter/material.dart';
import '../../state/app_state.dart';
import 'positions_screen.dart';

class OrdersScreen extends StatelessWidget {
  final AppState appState;

  const OrdersScreen({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return PositionsScreen(
      appState: appState,
      initialTab: 'Orders',
    );
  }
}
