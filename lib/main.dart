import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'audio/audio_handler.dart';
import 'audio/audio_provider.dart';
import 'library/library_provider.dart';
import 'theme/theme_provider.dart';

bool _audioServiceOk = false;
String _audioServiceError = '';

/// Guarda el último error capturado para mostrarlo en la UI.
/// Permite diagnosticar crashes sin USB debug.
const String _crashLogKey = 'last_crash_log';

Future<void> _saveCrashLog(String error) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = DateTime.now().toIso8601String();
    await prefs.setString(_crashLogKey, '[$timestamp]\n$error');
  } catch (_) {}
}

Future<void> main() async {
  // Deshabilita descarga de fuentes en tiempo de ejecución.
  // Previene ZoneError/SocketException cuando no hay red.
  // Manrope está bundled en el paquete google_fonts → funciona offline.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Zona de errores: captura TODO lo que Dart puede capturar,
  // incluyendo errores asíncronos y PlatformExceptions.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Captura errores de Flutter framework (rendering, etc.)
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _saveCrashLog(
          'FlutterError: ${details.exception}\n${details.stack ?? ""}');
    };

    // Captura errores de platform channels no manejados
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('⚠️ PlatformDispatcher error: $error\n$stack');
      _saveCrashLog('PlatformError: $error\n$stack');
      return true; // Marca como manejado — evita crash
    };

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    await _requestPermissions();

    final prefs = await SharedPreferences.getInstance();
    final initialTheme =
        ThemeProvider.modeFromName(prefs.getString(ThemeProvider.storageKey));

    ACARMusicHandler audioHandler;
    try {
      audioHandler = await AudioService.init(
        builder: () => ACARMusicHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.acar.music.playback',
          androidNotificationChannelName: 'ACARMusic',
          androidNotificationChannelDescription: 'Reproducción de música',
          androidNotificationIcon: 'drawable/ic_notification',
          androidStopForegroundOnPause: false,
          androidNotificationOngoing: false,
        ),
      );
      _audioServiceOk = true;
      _audioServiceError = '';
      debugPrint('✅ AudioService.init OK');
    } catch (e, st) {
      _audioServiceOk = false;
      _audioServiceError = 'ERROR: $e\n\nStackTrace:\n$st';
      debugPrint('❌ AudioService.init FALLÓ:\n$_audioServiceError');
      audioHandler = ACARMusicHandler();
    }

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider(initialTheme)),
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProxyProvider<LibraryProvider, AudioProvider>(
            create: (_) => AudioProvider(audioHandler),
            update: (_, library, audio) {
              audio!.bindLibrary(
                songs: library.allSongs,
                hasPermission: library.hasPermission,
                isLoading: library.isLoading,
              );
              return audio;
            },
          ),
        ],
        child: ACARMusicApp(
          audioServiceOk: _audioServiceOk,
          audioServiceError: _audioServiceError,
        ),
      ),
    );
  }, (error, stack) {
    // Captura errores no manejados en la zona (async sin try/catch)
    final msg = error.toString();
    // Ignorar todos los errores de carga de fuentes — no críticos.
    // Con Manrope bundled localmente, estos errores no deberían ocurrir,
    // pero si google_fonts intenta cargar variantes no bundled, los silenciamos.
    if (msg.contains('fonts.gstatic') ||
        msg.contains('Failed to load font') ||
        msg.contains('allowRuntimeFetching') ||
        msg.contains('was not found in the application assets') ||
        msg.contains('Ensure Manrope') ||
        msg.contains('GoogleFonts.config')) {
      debugPrint('⚠️ Font load error (ignorado): $msg');
      return;
    }
    debugPrint('⚠️ Zone error: $error\n$stack');
    _saveCrashLog('ZoneError: $error\n$stack');
  });
}

/// Único punto de solicitud de permisos al arrancar.
Future<void> _requestPermissions() async {
  for (final permission in [
    Permission.notification,
    Permission.audio,
    Permission.storage,
    // android.media.audiofx.Visualizer (FFT de los visualizadores) exige
    // RECORD_AUDIO en runtime. No se graba ni se envía audio a ningún sitio.
    Permission.microphone,
  ]) {
    final status = await permission.status;
    if (status.isGranted || status.isPermanentlyDenied) continue;
    await permission.request();
  }
  try {
    if (!(await Permission.ignoreBatteryOptimizations.isGranted)) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  } catch (_) {}
}
