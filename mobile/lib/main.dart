import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config/constants.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  // Catch all uncaught Flutter framework errors.
  FlutterError.onError = (FlutterErrorDetails details) {
    // ignore: avoid_print
    print('[FLUTTER ERROR] ${details.exceptionAsString()}');
    // ignore: avoid_print
    print('[FLUTTER ERROR] ${details.stack}');
    FlutterError.presentError(details);
  };

  // Catch all uncaught async errors.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await _migrateBackendUrlIfNeeded();
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString('theme_mode');
    final themeMode = switch (themeName) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    // Also register a PlatformDispatcher error handler for isolate errors.
    PlatformDispatcher.instance.onError = (error, stack) {
      // ignore: avoid_print
      print('[PLATFORM ERROR] $error');
      // ignore: avoid_print
      print('[PLATFORM ERROR] $stack');
      return true;
    };

    runApp(
      ProviderScope(
        child: AnoteApp(initialThemeMode: themeMode),
      ),
    );
  }, (error, stack) {
    // ignore: avoid_print
    print('[ZONE ERROR] $error');
    // ignore: avoid_print
    print('[ZONE ERROR] $stack');
  });
}

Future<void> _migrateBackendUrlIfNeeded() async {
  const storage = FlutterSecureStorage();
  final storedUrl = await storage.read(key: AppConstants.secureStorageKeyUrl);
  final storedToken =
      await storage.read(key: AppConstants.secureStorageKeyToken);

  if (AppConstants.shouldMigrateBackendUrl(storedUrl)) {
    await storage.write(
      key: AppConstants.secureStorageKeyUrl,
      value: AppConstants.defaultBackendUrl,
    );
  }

  if (AppConstants.shouldMigrateBackendToken(storedToken)) {
    await storage.write(
      key: AppConstants.secureStorageKeyToken,
      value: AppConstants.defaultToken,
    );
  }
}

class AnoteApp extends ConsumerWidget {
  final ThemeMode initialThemeMode;

  const AnoteApp({super.key, required this.initialThemeMode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Override theme provider with saved value on first build
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'ANOTE',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
    );
  }
}

ThemeData _buildLightTheme() {
  const bg = Color(0xFFF1F5F9);
  const card = Color(0xFFFFFFFF);
  const border = Color(0xFFCBD5E1);
  const text = Color(0xFF1E293B);
  const accent = Color(0xFF0891B2);
  const danger = Color(0xFFDC2626);
  const success = Color(0xFF059669);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.light,
    surface: bg,
    onSurface: text,
    primary: accent,
    error: danger,
  ).copyWith(
    surface: bg,
    onSurface: text,
    primary: accent,
    onPrimary: Colors.white,
    error: danger,
    secondary: success,
    outline: border,
    surfaceContainerHighest: card,
  );

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: bg,
    cardTheme: const CardTheme(
      color: card,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: card,
      foregroundColor: text,
      elevation: 0,
    ),
    useMaterial3: true,
  );
}

ThemeData _buildDarkTheme() {
  const bgDark = Color(0xFF0F172A);
  const cardDark = Color(0xFF1E293B);
  const borderDark = Color(0xFF334155);
  const textDark = Color(0xFFF1F5F9);
  const accentDark = Color(0xFF06B6D4);
  const dangerDark = Color(0xFFEF4444);
  const successDark = Color(0xFF10B981);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: accentDark,
    brightness: Brightness.dark,
    surface: bgDark,
    onSurface: textDark,
    primary: accentDark,
    error: dangerDark,
  ).copyWith(
    surface: bgDark,
    onSurface: textDark,
    primary: accentDark,
    onPrimary: Colors.black,
    error: dangerDark,
    secondary: successDark,
    outline: borderDark,
    surfaceContainerHighest: cardDark,
  );

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: bgDark,
    cardTheme: const CardTheme(
      color: cardDark,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: cardDark,
      foregroundColor: textDark,
      elevation: 0,
    ),
    useMaterial3: true,
  );
}
