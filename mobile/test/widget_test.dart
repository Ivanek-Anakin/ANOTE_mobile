// Basic smoke test for ANOTE Mobile.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anote_mobile/main.dart';

void main() {
  testWidgets('AnoteApp renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: AnoteApp(initialThemeMode: ThemeMode.light),
      ),
    );
    await tester.pump();

    // Verify the app title is rendered.
    expect(find.text('ANOTE'), findsOneWidget);
  });
}
