import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/session.dart';
import 'state/sync_controller.dart';
import 'ui/router.dart';
import 'ui/theme.dart';

class InfoisApp extends ConsumerStatefulWidget {
  const InfoisApp({super.key});

  @override
  ConsumerState<InfoisApp> createState() => _InfoisAppState();
}

class _InfoisAppState extends ConsumerState<InfoisApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _markForeground(true);
  }

  /// Tanda "aplikasi sedang dibuka" untuk sinkron latar (lihat background_sync).
  void _markForeground(bool active) {
    ref.read(storageProvider).markForeground(active).catchError((Object _) => false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Sinkron setiap kali aplikasi dibuka kembali.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _markForeground(true);
        ref.read(syncProvider.notifier).syncNow();
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _markForeground(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(syncProvider);
    return MaterialApp.router(
      title: 'Infois',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('id', 'ID'),
      supportedLocales: const [Locale('id', 'ID'), Locale('en')],
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      routerConfig: ref.watch(routerProvider),
    );
  }
}
