// lib/main.dart
//
// ENTRYPOINT
// ----------
// Deliberately thin. Its only jobs are: (1) wrap the app in a
// `ProviderScope` so Riverpod providers work anywhere in the tree, and
// (2) wire up the app-wide theme and the initial route. No business
// logic, no service instantiation, no permission handling — all of that
// lives in the layers described in the README.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'ui/screens/swipe_screen.dart';

void main() {
  runApp(
    // ProviderScope is the root container for all Riverpod state. Every
    // provider defined across `state/` and `data/` is resolved lazily
    // the first time a widget below this point reads it.
    const ProviderScope(
      child: StorageSwipeApp(),
    ),
  );
}

class StorageSwipeApp extends StatelessWidget {
  const StorageSwipeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Storage Swipe',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const SwipeScreen(),
    );
  }
}
