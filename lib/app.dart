import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config.dart';
import 'state/session.dart';
import 'state/sync_controller.dart';
import 'ui/focus.dart';
import 'ui/router.dart';
import 'ui/theme.dart';

class InfoisApp extends ConsumerStatefulWidget {
  const InfoisApp({super.key});

  @override
  ConsumerState<InfoisApp> createState() => _InfoisAppState();
}

class _InfoisAppState extends ConsumerState<InfoisApp> with WidgetsBindingObserver {
  /// Sentuhan terakhir / saat aplikasi ditinggal ke latar (kunci otomatis tablet bersama).
  DateTime _lastActive = DateTime.now();
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _markForeground(true);
    _idleTimer = Timer.periodic(const Duration(seconds: 30), (_) => _lockIfIdle());
  }

  /// Kunci PIN aktif dan tablet tidak disentuh / ditinggal lebih dari batasnya.
  void _lockIfIdle() {
    final storage = ref.read(storageProvider);
    final minutes = storage.pinLockMinutes;
    if (storage.pinLock && minutes > 0 && DateTime.now().difference(_lastActive) >= Duration(minutes: minutes)) {
      ref.read(sessionProvider.notifier).lock();
    }
  }

  /// Tanda "aplikasi sedang dibuka" untuk sinkron latar (lihat background_sync).
  void _markForeground(bool active) {
    ref.read(storageProvider).markForeground(active).catchError((Object _) => false);
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Sinkron setiap kali aplikasi dibuka kembali.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _markForeground(true);
        _lockIfIdle();
        _lastActive = DateTime.now();
        ref.read(syncProvider.notifier).syncNow();
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _markForeground(false);
        _lastActive = DateTime.now();
        // Android memunculkan lagi keyboard untuk isian yang masih fokus saat
        // aplikasi dibuka kembali: lepas fokus sebelum ke latar.
        dismissKeyboard();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(syncProvider);
    return MaterialApp.router(
      title: AppConfig.name,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('id', 'ID'),
      supportedLocales: const [Locale('id', 'ID'), Locale('en')],
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _lastActive = DateTime.now(),
        child: TapToDismissKeyboard(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
