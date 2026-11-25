import 'dart:async';
import 'package:flutter/services.dart';

/// Origen del espectro. `auto` usa el Visualizer nativo y, si el DSP del
/// dispositivo bloquea la captura (Samsung), conmuta a un FFT calculado del
/// propio archivo de audio —siempre datos reales, nunca simulados.
enum FftSource { auto, native, offline }

/// Puente con la fuente de FFT: `android.media.audiofx.Visualizer` en vivo o
/// un espectro descodificado del archivo e indexado por posición de reproducción.
class VisualizerService {
  static const _methodChannel = MethodChannel('com.acar.music/visualizer');
  static const _eventChannel = EventChannel('com.acar.music/visualizer_fft');
  static const _offlineChannel = MethodChannel('com.acar.music/offline_fft');

  static const Duration _frameInterval = Duration(milliseconds: 33);
  static const Duration _watchdogInterval = Duration(milliseconds: 100);
  // Sin frames (DSP bloqueado) o ~0,4 s de energía casi nula con música sonando
  // => el nativo no está capturando ESTA pista.
  static const Duration _nativeTimeout = Duration(milliseconds: 600);
  static const int _zeroFramesToFallback = 20;
  static const double _minFrameEnergy = 0.006;
  static const Duration _prepareTimeout = Duration(seconds: 10);

  static final List<double> _silenceFrame = List<double>.unmodifiable(
    List<double>.filled(64, 0.0),
  );

  late final StreamController<List<double>> _controller =
      StreamController<List<double>>.broadcast(
    onCancel: () {
      if (!_controller.hasListener) _silenceTimer?.cancel();
    },
  );

  StreamSubscription<dynamic>? _nativeSub;
  Timer? _silenceTimer;
  Timer? _frameTimer;
  Timer? _nativeWatchdog;
  DateTime? _lastNativeFrameAt;
  DateTime? _nativeStartedAt;
  int _lowEnergyFrames = 0;
  bool _started = false;
  bool _playbackActive = false;
  int? _activeSessionId;
  String? _activePath;
  int _generation = 0;

  bool _offlineReady = false;
  bool _offlineSwitching = false;
  bool _frameInFlight = false;

  /// Preferencia de fuente. `auto` es el valor por defecto.
  FftSource preferredSource = FftSource.auto;

  /// Lo fija AudioProvider: posición real de just_audio en milisegundos.
  int Function()? positionMsProvider;

  /// `true` cuando el Visualizer nativo entregó datos.
  bool nativeAvailable = false;

  /// `true` cuando el espectro offline está listo y en uso.
  bool offlineAvailable = false;

  Stream<List<double>> get fftStream => _controller.stream;

  Future<bool> start(int audioSessionId,
      {bool force = false, String? filePath}) async {
    if (!force &&
        _started &&
        _activeSessionId == audioSessionId &&
        _activePath == filePath) {
      return true;
    }

    final gen = ++_generation;
    await _stopInternal();
    if (gen != _generation) return false;

    _started = true;
    _activeSessionId = audioSessionId;
    _activePath = filePath;
    _lowEnergyFrames = 0;
    _lastNativeFrameAt = null;
    _nativeStartedAt = DateTime.now();

    // La sesión global (0) ya se sabe que falla en Samsung: ir directo al FFT
    // del archivo. En modo offline explícito tampoco se molesta al nativo.
    final tryNative = audioSessionId != 0 && preferredSource != FftSource.offline;

    if (tryNative) {
      bool nativeOk = false;
      try {
        nativeOk = await _methodChannel.invokeMethod<bool>('startVisualizer', {
              'audioSessionId': audioSessionId,
            }) ??
            false;
      } catch (_) {
        nativeOk = false;
      }
      if (gen != _generation) return false;
      nativeAvailable = nativeOk;
      _lastNativeFrameAt = nativeOk ? DateTime.now() : null;

      if (nativeOk) {
        final sub = _eventChannel.receiveBroadcastStream().listen(
          (data) {
            if (!_started || gen != _generation || _controller.isClosed) return;
            final frame = (data as List<dynamic>)
                .map((value) => (value as num).toDouble())
                .toList(growable: false);
            _lastNativeFrameAt = DateTime.now();

            if (_playbackActive && preferredSource != FftSource.native) {
              // No basta con "todos a cero": si el nativo captura la mezcla
              // global o ruido de otro effect, entrega valores > 0 que no son
              // de esta pista y el viejo watchdog nunca conmutaba.
              final energy = frame.isEmpty
                  ? 0.0
                  : frame.fold<double>(0.0, (sum, v) => sum + v) /
                      frame.length;
              final silent = frame.every((v) => v <= 0.001);
              final unusable = silent || energy < _minFrameEnergy;
              _lowEnergyFrames = unusable ? _lowEnergyFrames + 1 : 0;
              if (_lowEnergyFrames >= _zeroFramesToFallback) {
                _lowEnergyFrames = 0;
                unawaited(_switchToOffline(gen));
                return;
              }
            }
            _controller.add(_playbackActive ? frame : _silenceFrame);
          },
          onError: (_) {
            nativeAvailable = false;
            if (gen == _generation && _started) {
              unawaited(_switchToOffline(gen));
            }
          },
        );
        if (gen != _generation) {
          await sub.cancel();
          return false;
        }
        _nativeSub = sub;
        _armNativeWatchdog(gen);
        return true;
      }
      // preferredSource == native: sin fuente, silencio (nunca datos falsos).
      if (preferredSource == FftSource.native) {
        _safeAdd(_silenceFrame);
        return false;
      }
    }

    if (_activePath != null) return _switchToOffline(gen);

    _safeAdd(_silenceFrame);
    return false;
  }

  /// Conmuta al espectro calculado del archivo (datos reales del audio).
  Future<bool> _switchToOffline(int gen) async {
    final path = _activePath;
    if (gen != _generation ||
        path == null ||
        _offlineSwitching ||
        _offlineReady) {
      return _offlineReady;
    }
    _offlineSwitching = true;
    try {
      // Preparar ANTES de soltar el nativo. Si la decodificación falla, la
      // pista conserva una fuente (silencio real, nunca datos inventados).
      final meta = await _offlineChannel
          .invokeMapMethod<String, dynamic>('prepare', {'path': path})
          .timeout(_prepareTimeout);
      if (gen != _generation || !_started) return false;
      if (meta == null || meta['frameCount'] is! int) {
        throw Exception('prepare sin metadatos');
      }

      final sub = _nativeSub;
      _nativeSub = null;
      nativeAvailable = false;
      _nativeWatchdog?.cancel();
      _nativeWatchdog = null;
      await sub?.cancel().catchError((_) {});
      await _safeStopNative();

      offlineAvailable = true;
      _offlineReady = true;
      _lowEnergyFrames = 0;
      _lastNativeFrameAt = null;
      // El último frame de la fuente anterior no debe quedar dibujado.
      _safeAdd(_silenceFrame);
      if (_playbackActive) _startFrameTimer();
      return true;
    } catch (_) {
      offlineAvailable = false;
      _offlineReady = false;
      _safeAdd(_silenceFrame);
      return false;
    } finally {
      // Siempre se libera, incluso si `prepare` se cancela o expira: antes un
      // await colgado dejaba este flag en true y el FFT offline moría para
      // toda la sesión.
      _offlineSwitching = false;
    }
  }

  /// Vigila la fuente nativa incluso cuando el callback NO llega (DSP que
  /// bloquea la captura silenciosamente). Sin este timer el watchdog anterior
  /// solo contaba frames a cero y nunca veía un canal muerto.
  void _armNativeWatchdog(int gen) {
    _nativeWatchdog?.cancel();
    _nativeWatchdog = Timer.periodic(_watchdogInterval, (_) {
      if (!_started ||
          gen != _generation ||
          !_playbackActive ||
          !nativeAvailable ||
          _offlineReady ||
          preferredSource == FftSource.native) {
        _nativeWatchdog?.cancel();
        _nativeWatchdog = null;
        return;
      }
      final now = DateTime.now();
      final last = _lastNativeFrameAt ?? _nativeStartedAt ?? now;
      final stale = now.difference(last) > _nativeTimeout;
      if (stale || _lowEnergyFrames >= _zeroFramesToFallback) {
        _lowEnergyFrames = 0;
        unawaited(_switchToOffline(gen));
      }
    });
  }

  void _startFrameTimer() {
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(_frameInterval, (_) => _tickOffline());
  }

  Future<void> _tickOffline() async {
    if (!_started || !_playbackActive || !_offlineReady ||
        _frameInFlight || _controller.isClosed) {
      return;
    }
    final gen = _generation;
    _frameInFlight = true;
    try {
      final ms = positionMsProvider?.call() ?? 0;
      final frame = await _offlineChannel.invokeListMethod<dynamic>(
        'getFrameAt',
        {'positionMs': ms},
      );
      if (gen != _generation || !_offlineReady || frame == null) return;
      _controller.add(
        frame.map((v) => (v as num).toDouble()).toList(growable: false),
      );
    } catch (_) {
      // Un fallo puntual no invalida la fuente: reintenta en el próximo tick.
    } finally {
      // Solo el tick de la generación vigente puede liberar el flag: si el
      // track cambió mientras esperábamos, un tick viejo no debe autorizar otro
      // tick nuevo simultáneo con el suyo.
      if (gen == _generation) _frameInFlight = false;
    }
  }

  /// Fuerza un reenganche aunque el id de sesión sea el mismo.
  Future<bool> restart(int audioSessionId, {String? filePath}) =>
      start(audioSessionId, force: true, filePath: filePath);

  void setPlaybackActive(bool active) {
    if (_playbackActive == active) return;
    _playbackActive = active;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _frameTimer?.cancel();
    _frameTimer = null;

    if (!active) {
      _safeAdd(_silenceFrame);
      if (!_controller.hasListener) return;
      _silenceTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!_started || _playbackActive || _controller.isClosed) return;
        _controller.add(_silenceFrame);
      });
    } else if (_offlineReady) {
      _startFrameTimer();
    } else if (nativeAvailable) {
      // El watchdog se auto-cancela al pausar: hay que volver a armarlo.
      _armNativeWatchdog(_generation);
    }
  }

  Future<void> stop() async {
    _generation++;
    await _stopInternal();
  }

  Future<void> _stopInternal() async {
    _started = false;
    _playbackActive = false;
    _activeSessionId = null;
    _activePath = null;
    nativeAvailable = false;
    offlineAvailable = false;
    _offlineReady = false;
    // Si un prepare estaba en vuelo, su finally ya no debe dejar el latch
    // colgado: la siguiente pista puede intentar el FFT offline de nuevo.
    _offlineSwitching = false;
    _frameInFlight = false;
    _lowEnergyFrames = 0;
    _lastNativeFrameAt = null;
    _frameTimer?.cancel();
    _frameTimer = null;
    _nativeWatchdog?.cancel();
    _nativeWatchdog = null;
    await _safeCancelNativeSub();
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _safeAdd(_silenceFrame);
    await _safeStopNative();
    await _safeReleaseOffline();
  }

  Future<void> _safeCancelNativeSub() async {
    final subscription = _nativeSub;
    _nativeSub = null;
    if (subscription == null) return;
    try {
      await subscription.cancel();
    } catch (_) {}
  }

  Future<void> _safeStopNative() async {
    try {
      await _methodChannel.invokeMethod('stopVisualizer');
    } catch (_) {}
  }

  Future<void> _safeReleaseOffline() async {
    try {
      await _offlineChannel.invokeMethod('release');
    } catch (_) {}
  }

  void _safeAdd(List<double> data) {
    if (!_controller.isClosed) _controller.add(data);
  }

  void dispose() {
    _generation++;
    _started = false;
    _playbackActive = false;
    _activeSessionId = null;
    _activePath = null;
    _offlineReady = false;
    _offlineSwitching = false;
    positionMsProvider = null;
    unawaited(_safeCancelNativeSub());
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _frameTimer?.cancel();
    _frameTimer = null;
    _nativeWatchdog?.cancel();
    _nativeWatchdog = null;
    _controller.close();
    unawaited(_safeStopNative());
    unawaited(_safeReleaseOffline());
  }
}
