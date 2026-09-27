import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';

class VisualizerService {
  static const _methodChannel = MethodChannel('com.acar.music/visualizer');
  static const _eventChannel = EventChannel('com.acar.music/visualizer_fft');

  final StreamController<List<double>> _controller =
      StreamController<List<double>>.broadcast();

  StreamSubscription? _nativeSub;
  Timer? _simulatedTimer;
  Timer? _silenceTimer;
  bool _started = false;
  bool _playbackActive = false;
  int? _activeSessionId;

  Stream<List<double>> get fftStream => _controller.stream;

  Future<bool> start(int audioSessionId) async {
    if (_started && _activeSessionId == audioSessionId) return true;
    if (_started) await stop();
    _started = true;
    _playbackActive = true;
    _activeSessionId = audioSessionId;

    bool nativeOk = false;
    try {
      nativeOk = await _methodChannel.invokeMethod<bool>('startVisualizer', {
            'audioSessionId': audioSessionId,
          }) ??
          false;
    } catch (_) {
      nativeOk = false;
    }

    if (nativeOk) {
      _nativeSub = _eventChannel.receiveBroadcastStream().listen(
        (data) {
          if (!_started || _controller.isClosed) return;
          _controller.add(
            _playbackActive
                ? (data as List<dynamic>)
                    .map((value) => (value as num).toDouble())
                    .toList(growable: false)
                : _silenceFrame,
          );
        },
        onError: (_) {
          if (_started) _startSimulated();
        },
        cancelOnError: false,
      );
    } else {
      _startSimulated();
    }
    return true;
  }

  void setPlaybackActive(bool active) {
    if (_playbackActive == active) return;
    _playbackActive = active;
    _silenceTimer?.cancel();
    _silenceTimer = null;

    if (!active) {
      _safeAdd(_silenceFrame);
      _silenceTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!_started || _playbackActive || _controller.isClosed) return;
        _controller.add(_silenceFrame);
      });
    }
  }

  List<double> get _silenceFrame => List<double>.filled(64, 0.0);

  Future<void> stop() async {
    _started = false;
    _playbackActive = false;
    _activeSessionId = null;
    await _safeCancelNativeSub();
    _simulatedTimer?.cancel();
    _simulatedTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _safeAdd(_silenceFrame);
    try {
      await _methodChannel.invokeMethod('stopVisualizer');
    } catch (_) {}
  }

  Future<void> _safeCancelNativeSub() async {
    final subscription = _nativeSub;
    _nativeSub = null;
    if (subscription == null) return;
    try {
      // EventChannel.cancel is asynchronous. Some Android audio engines
      // report MissingPluginException while the activity is being destroyed.
      await subscription.cancel();
    } catch (_) {
      // The simulated visualizer remains available as a fallback.
    }
  }

  void _safeAdd(List<double> data) {
    if (!_controller.isClosed) {
      _controller.add(data);
    }
  }

  void _startSimulated() {
    final rng = Random();
    double time = 0.0;
    // Simulado con pulso de beat (~128 BPM) para que radial/barras
    // se muevan al ritmo aunque el Visualizer nativo no esté disponible
    // (emulador, Samsung DSP bloqueado). Antes eran senos lentos de ~8s.
    const dt = 0.05;
    const beatFreq = 2.13; // 128 BPM

    _simulatedTimer?.cancel();
    _simulatedTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_started || _controller.isClosed) return;
      if (!_playbackActive) {
        _controller.add(_silenceFrame);
        return;
      }
      time += dt;
      // Envolvente de kick: pulso corto con decaimiento rápido.
      final phase = (time * beatFreq) % 1.0;
      final kick = pow(1.0 - phase, 2.2).toDouble();
      final hatPhase = (time * beatFreq * 2) % 1.0;
      final hat = pow(1.0 - hatPhase, 3.0).toDouble() * 0.5;
      final data = List<double>.generate(64, (i) {
        final freqRatio = i / 64;
        double value;
        if (freqRatio < 0.2) {
          // Graves siguen el kick.
          value = (0.15 + kick * 0.75 + rng.nextDouble() * 0.1)
              .clamp(0.05, 1.0);
        } else if (freqRatio > 0.7) {
          value = (0.08 + hat * 0.5 + rng.nextDouble() * 0.18)
              .clamp(0.05, 1.0);
        } else {
          value = (0.12 +
                  kick * 0.3 +
                  sin(time * 3.1 + i * 0.4) * 0.08 +
                  rng.nextDouble() * 0.15)
              .clamp(0.05, 1.0);
        }
        return value;
      });
      _controller.add(data);
    });
  }

  void dispose() {
    _started = false;
    _playbackActive = false;
    _activeSessionId = null;
    unawaited(_safeCancelNativeSub());
    _simulatedTimer?.cancel();
    _simulatedTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _controller.close();
    unawaited(_safeStopNative());
  }

  Future<void> _safeStopNative() async {
    try {
      await _methodChannel.invokeMethod('stopVisualizer');
    } catch (_) {}
  }
}
