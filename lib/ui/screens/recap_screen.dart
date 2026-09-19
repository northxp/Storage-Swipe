// lib/ui/screens/recap_screen.dart
//
// UI LAYER — SCREEN (VIEW)
// ---------------------------
// The gamification "payoff" screen: shown immediately after a successful
// `emptyTrash()` call, it reports the concrete result (MB freed) in a
// celebratory way. Purely presentational — it receives its data via
// constructor arguments rather than reading provider state itself, which
// keeps it trivially reusable/testable in isolation.

import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'swipe_screen.dart';

class RecapScreen extends StatelessWidget {
  const RecapScreen({super.key, required this.freedMegabytes});

  final double freedMegabytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.rocket_launch, color: AppColors.keep, size: 72),
              const SizedBox(height: 24),
              const Text(
                'Nice work!',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'You just freed up',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                '${freedMegabytes.toStringAsFixed(1)} MB',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const SwipeScreen()),
                    (route) => false,
                  ),
                  child: const Text('Keep Swiping'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
