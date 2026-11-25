import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_handler.dart';
import '../visualizers/animation_style.dart';
import '../visualizers/visualizer_service.dart';

enum AppRepeatState { off, all, one }

class AudioProvider extends ChangeNotifier with WidgetsBindingObserver {
  AudioProvider(this._handler) {
    _init();
    WidgetsBinding.instance.addObserver(this);
    _handler.onSkipToNext = skipNext;
    _handler.onSkipToPrevious = skipPrevious;
    _handler.onToggleShuffle = () async => toggleShuffle();
    _handler.onToggleRepeat = () async => toggleRepeat();
    // El FFT offline indexa sus frames con la posición REAL del reproductor:
    // cualquier seek se refleja en el siguiente frame, sin desfase acumulado.
    visualizerService.positionMsProvider = () => _player.position.inMilliseconds;
  }

  final ACARMusicHandler _handler;
  AudioPlayer get _player => _handler.player;

  List<SongModel> _queue = [];
  int _currentIndex = -1;
  bool _isShuffleOn = false;
  AppRepeatState _repeatMode = AppRepeatState.off;
  bool _isPlaying = false;

  final List<int> _shuffleHistory = [];
  static const int _maxHistory = 50;

  final Random _random = Random();

  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> durationNotifier = ValueNotifier(Duration.zero);

  Timer? _sleepTimer;
  Timer? _countdownTimer;
  final ValueNotifier<Duration> sleepRemainingNotifier =
      ValueNotifier(Duration.zero);
  int _sleepTimerMinutes = 0;

  SharedPreferences? _prefs;
  bool _restoreAttempted = false;
  bool _restoreInProgress = false;
  bool _restoringSession = false;

  bool _changingTrack = false;
  bool _handlingCompletion = false;
  bool _processingPending = false;

  /// Red de seguridad: si una carga se cuelga, el guard de cambio de pista se
  /// libera solo para que los botones Siguiente/Anterior sigan respondiendo.
  Timer? _trackChangeWatchdog;

  // Peticiones diferidas mientras se estaba cambiando de pista. Se acumulan
  // los pasos de skip relativos para no perder toques rápidos.
  int _pendingSkipSteps = 0;
  SongModel? _pendingSong;
  List<SongModel>? _pendingQueue;
  int _pendingIndex = -1;
  bool _pendingAddToHistory = true;

  VisualizerStyle _animationStyle = VisualizerStyle.vinyl;
  final VisualizerService visualizerService = VisualizerService();
  static const String _visualizerKey = 'visualizer_style_v1';

  VisualizerStyle get animationStyle => _animationStyle;

  set animationStyle(VisualizerStyle value) {
    _animationStyle = value;
    _saveVisualizerStyle();
    // Primero el pipeline de audio/visualizador y después el rebuild de la UI.
    _manageVisualizer();
    notifyListeners();
  }

  static const String _sessionKey = 'audio_session_v1';
  static const Duration _saveThrottle = Duration(milliseconds: 700);
  DateTime? _lastSessionSave;

  int get sleepTimerMinutes => _sleepTimerMinutes;
  List<SongModel> get queue => _queue;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _isPlaying;
  bool get isShuffleOn => _isShuffleOn;
  AppRepeatState get repeatMode => _repeatMode;
  Duration get position => positionNotifier.value;
  Duration get duration => durationNotifier.value;

  int? get androidAudioSessionId => _player.androidAudioSessionId;

  SongModel? get currentSong =>
      _currentIndex >= 0 && _currentIndex < _queue.length
          ? _queue[_currentIndex]
          : null;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<int?>? _audioSessionSub;
  int? _lastVisualizerSessionId;
  ProcessingState? _lastProcessingState;

  void _init() {
    unawaited(SharedPreferences.getInstance().then((prefs) {
      _prefs = prefs;
      _loadVisualizerStyle(prefs);
    }));

    _positionSub = _player.positionStream.listen((pos) {
      positionNotifier.value = pos;
      _scheduleSessionSave();
    });

    _durationSub = _player.durationStream
        .listen((dur) => durationNotifier.value = dur ?? Duration.zero);

    // just_audio puede crear un id de sesión nuevo AL cargar la pista. Sin
    // esta suscripción el Visualizer seguía enganchado a la sesión anterior
    // (o ni siquiera arrancaba) y las animaciones no respondían al audio.
    _audioSessionSub = _player.androidAudioSessionIdStream.listen((id) {
      if (id == null || id == _lastVisualizerSessionId) return;
      _lastVisualizerSessionId = id;
      _manageVisualizer(force: true);
    });

    // Única fuente de verdad para _isPlaying: el player real. No se filtran
    // eventos durante play/pause para que los controles de la notificación
    // mantengan el icono sincronizado con el audio.
    _playerStateSub = _player.playerStateStream.listen((state) {
      final wasPlaying = _isPlaying;
      _isPlaying = state.playing;
      if (wasPlaying != _isPlaying) {
        _manageVisualizer();
        notifyListeners();
      }
      _saveSession();
      // just_audio puede exponer el audio session id solo después de pasar a
      // ready: reintentar el arranque del FFT en esa transición.
      if (state.processingState == ProcessingState.ready &&
          _lastProcessingState != ProcessingState.ready &&
          !_changingTrack) {
        _manageVisualizer();
      }
      _lastProcessingState = state.processingState;
      if (state.processingState == ProcessingState.completed &&
          !_changingTrack &&
          !_restoringSession) {
        _onTrackCompleted();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      unawaited(_saveSession());
      unawaited(visualizerService.stop());
    } else if (state == AppLifecycleState.resumed) {
      _manageVisualizer();
    }
  }

  void bindLibrary({
    required List<SongModel> songs,
    required bool hasPermission,
    required bool isLoading,
  }) {
    if (!hasPermission || isLoading || songs.isEmpty) return;
    unawaited(_restoreSessionIfPossible(songs));
  }

  /// Carga y reproduce una pista. Valida el índice y el archivo ANTES de
  /// mutar el estado, para que la UI nunca muestre una canción que no sonó.
  Future<void> playSong(SongModel song, List<SongModel> newQueue, int index,
      {bool addToHistory = true}) async {
    if (index < 0 || index >= newQueue.length) return;
    final path = song.data;
    if (path.isEmpty || !File(path).existsSync()) return;

    if (_changingTrack) {
      // Se guarda la petición absoluta (tiene prioridad sobre los skips).
      _pendingSkipSteps = 0;
      _pendingSong = song;
      _pendingQueue = newQueue;
      _pendingIndex = index;
      _pendingAddToHistory = addToHistory;
      return;
    }

    _changingTrack = true;
    _handler.suppressBroadcast = true;
    _trackChangeWatchdog?.cancel();
    _trackChangeWatchdog = Timer(const Duration(seconds: 12), () {
      debugPrint('Watchdog: liberando cambio de pista bloqueado');
      _releaseTrackChangeGuard();
    });

    try {
      if (_isShuffleOn && addToHistory && _currentIndex >= 0) {
        _shuffleHistory.add(_currentIndex);
        if (_shuffleHistory.length > _maxHistory) _shuffleHistory.removeAt(0);
      }

      final queueChanged =
          _queue.length != newQueue.length || !_listsEqual(_queue, newQueue);
      // Un cambio de cola invalida el historial (sus índices ya no aplican).
      if (queueChanged) _shuffleHistory.clear();

      _queue = List.from(newQueue);
      _currentIndex = index;
      notifyListeners();

      if (queueChanged) {
        await _handler.setQueueAndCurrentSong(newQueue, index);
      } else {
        await _handler.updateCurrentSong(song, index);
      }

      await _player.setFilePath(path);

      _handler.suppressBroadcast = false;
      _handler.refreshPlaybackState();

      // NO esperar el Future de play(): en just_audio solo se completa al
      // pausar/finalizar la pista. Esperarlo aquí dejaba `_changingTrack` en
      // true y los skips se encolaban hasta que se tocaba pausa/reproducir.
      _requestPlay();
      unawaited(_saveSession());
    } catch (e) {
      debugPrint('Error reproduciendo: $e');
    } finally {
      _trackChangeWatchdog?.cancel();
      _trackChangeWatchdog = null;
      _releaseTrackChangeGuard();
      // No asignar `_isPlaying` desde `play()` sin await: just_audio solo
      // completa ese Future al pausar, así que aquí podía valer false aunque
      // la pista nueva ya estuviera sonando y el radial se congelaba. La única
      // fuente de verdad sigue siendo `playerStateStream`.
      // Reenganchar el FFT tras cada cambio de pista: el id de sesión puede
      // repetirse y el Visualizer nativo quedarse "pegado" a la pista anterior.
      _manageVisualizer(force: true);
    }
  }

  /// Libera el guard de cambio de pista y aplica las peticiones acumuladas.
  void _releaseTrackChangeGuard() {
    if (!_changingTrack) return;
    _changingTrack = false;
    _handler.suppressBroadcast = false;
    // Refrescar también en fallos/retornos tempranos para que la
    // notificación no conserve un estado obsoleto.
    _handler.refreshPlaybackState();
    notifyListeners();
    unawaited(_processPending());
  }

  /// `AudioPlayer.play()` devuelve un Future de LARGA duración: solo se
  /// completa al pausar, parar o terminar la pista. Nunca hay que await-earlo
  /// dentro de un flujo que deba terminar (cambio de pista, restauración...).
  void _requestPlay() {
    unawaited(_player.play().catchError((Object error) {
      debugPrint('play() error: $error');
    }));
  }

  /// Procesa en orden las peticiones que llegaron durante un cambio de pista.
  Future<void> _processPending() async {
    if (_processingPending) return;
    _processingPending = true;
    try {
      while (!_changingTrack &&
          (_pendingSkipSteps != 0 || _pendingSong != null)) {
        final steps = _pendingSkipSteps;
        final song = _pendingSong;
        final queue = _pendingQueue;
        final index = _pendingIndex;
        final history = _pendingAddToHistory;
        _pendingSkipSteps = 0;
        _pendingSong = null;
        _pendingQueue = null;
        _pendingIndex = -1;

        if (song != null && queue != null) {
          await playSong(song, queue, index, addToHistory: history);
        } else if (steps != 0) {
          await _skipBy(steps);
        }
      }
    } finally {
      _processingPending = false;
    }
  }

  Future<void> togglePlayPause() async {
    final wasPlaying = _player.playing;
    _isPlaying = !wasPlaying;
    _manageVisualizer();
    notifyListeners();

    try {
      if (wasPlaying) {
        await _player.pause();
      } else {
        _requestPlay();
      }
      _handler.refreshPlaybackState();
    } catch (e) {
      _isPlaying = wasPlaying;
      debugPrint('togglePlayPause error: $e');
    } finally {
      _isPlaying = _player.playing;
      notifyListeners();
      unawaited(_saveSession());
    }
  }

  void _manageVisualizer({bool force = false}) {
    if (!_animationStyle.usesFft) {
      // El vinilo y el minimalista no consumen FFT: no hay que crear el
      // Visualizer nativo ni mantener timers emitiendo frames.
      unawaited(visualizerService.stop());
      return;
    }
    final sessionId = _player.androidAudioSessionId;
    final path = currentSong?.data;
    if (sessionId != null || (path != null && path.isNotEmpty)) {
      unawaited(visualizerService.start(
        sessionId ?? 0,
        force: force,
        filePath: path,
      ));
      // El reproductor real manda; `_isPlaying` es el estado que ve la UI y
      // puede adelantarse un frame a `play()`/`pause()`.
      visualizerService.setPlaybackActive(_player.playing);
    } else {
      unawaited(visualizerService.stop());
    }
  }

  Future<void> seekTo(double progress) async {
    final dur = _player.duration;
    if (dur == null || dur.inMilliseconds == 0) return;
    final target = Duration(milliseconds: (progress * dur.inMilliseconds).round());
    if (target > dur) return;
    await _player.seek(target);
    unawaited(_saveSession());
  }

  Future<void> skipNext() async {
    if (_changingTrack) {
      _pendingSkipSteps++;
      return;
    }
    await _skipBy(1);
  }

  Future<void> skipPrevious() async {
    if (_changingTrack) {
      _pendingSkipSteps--;
      return;
    }
    // La posición real del player evita decidir con un notifier desactualizado.
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      unawaited(_saveSession());
      return;
    }
    await _skipBy(-1);
  }

  Future<void> _skipBy(int steps) async {
    if (_queue.isEmpty) return;

    if (_isShuffleOn) {
      for (var step = 0; step < steps.abs(); step++) {
        final forward = steps > 0;
        if (!forward && _shuffleHistory.isNotEmpty) {
          final prevIdx = _shuffleHistory.removeLast();
          if (prevIdx >= 0 && prevIdx < _queue.length) {
            await playSong(_queue[prevIdx], _queue, prevIdx,
                addToHistory: false);
            continue;
          }
        }
        int rand;
        do {
          rand = _random.nextInt(_queue.length);
        } while (_queue.length > 1 &&
            (rand == _currentIndex || _shuffleHistory.contains(rand)));
        await playSong(_queue[rand], _queue, rand);
      }
      return;
    }

    var target = _currentIndex + steps;
    if (_repeatMode == AppRepeatState.all) {
      target %= _queue.length;
      if (target < 0) target += _queue.length;
    } else {
      target = target.clamp(0, _queue.length - 1);
    }
    if (target == _currentIndex && steps != 0) {
      // No hay a dónde avanzar (cola de 1 o extremo sin repeat): reiniciar.
      await _player.seek(Duration.zero);
      unawaited(_saveSession());
      return;
    }
    await playSong(_queue[target], _queue, target, addToHistory: steps > 0);
  }

  void _onTrackCompleted() {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    try {
      switch (_repeatMode) {
        case AppRepeatState.one:
          // Con LoopMode.one just_audio no emite `completed`, pero se mantiene
          // el reinicio como fallback con guard de reentrada.
          unawaited(_player.seek(Duration.zero));
          unawaited(_player.play());
          unawaited(_saveSession());
          break;
        case AppRepeatState.all:
          unawaited(skipNext());
          break;
        case AppRepeatState.off:
          if (_currentIndex < _queue.length - 1) unawaited(skipNext());
          break;
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  void toggleShuffle() {
    _isShuffleOn = !_isShuffleOn;
    if (!_isShuffleOn) _shuffleHistory.clear();
    _syncHandlerPlaybackOptions();
    notifyListeners();
    unawaited(_saveSession());
  }

  void toggleRepeat() {
    _repeatMode = switch (_repeatMode) {
      AppRepeatState.off => AppRepeatState.all,
      AppRepeatState.all => AppRepeatState.one,
      AppRepeatState.one => AppRepeatState.off,
    };
    _syncHandlerPlaybackOptions();
    notifyListeners();
    unawaited(_saveSession());
  }

  void _syncHandlerPlaybackOptions() {
    _handler.updatePlaybackOptions(
      shuffleEnabled: _isShuffleOn,
      repeatMode: switch (_repeatMode) {
        AppRepeatState.one => AudioServiceRepeatMode.one,
        AppRepeatState.all => AudioServiceRepeatMode.all,
        AppRepeatState.off => AudioServiceRepeatMode.none,
      },
    );
    // LoopMode.one hace que just_audio reinicie la pista sin emitir `completed`.
    unawaited(_player.setLoopMode(
      _repeatMode == AppRepeatState.one ? LoopMode.one : LoopMode.off,
    ));
  }

  void setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _countdownTimer?.cancel();
    _sleepTimer = null;
    _countdownTimer = null;
    _sleepTimerMinutes = minutes;
    sleepRemainingNotifier.value = Duration(minutes: minutes);
    if (minutes > 0) {
      final endTime = DateTime.now().add(Duration(minutes: minutes));
      _sleepTimer = Timer(Duration(minutes: minutes), () async {
        await _player.pause();
        _countdownTimer?.cancel();
        _countdownTimer = null;
        _sleepTimerMinutes = 0;
        sleepRemainingNotifier.value = Duration.zero;
        _sleepTimer = null;
        _isPlaying = false;
        notifyListeners();
        unawaited(_saveSession());
      });
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final remaining = endTime.difference(DateTime.now());
        sleepRemainingNotifier.value =
            remaining.isNegative ? Duration.zero : remaining;
      });
    }
    notifyListeners();
  }

  void cancelSleepTimer() => setSleepTimer(0);

  Future<void> _restoreSessionIfPossible(List<SongModel> librarySongs) async {
    if (_restoreAttempted || _restoreInProgress) return;
    _restoreInProgress = true;
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs = prefs;

      final raw = prefs.getString(_sessionKey);
      if (raw == null) return;

      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return;

      final savedPath = map['currentPath'] as String?;
      final savedId = (map['currentId'] is num)
          ? (map['currentId'] as num).toInt()
          : null;
      if (savedPath == null && savedId == null) return;

      final songsById = <int, SongModel>{for (final s in librarySongs) s.id: s};
      final songsByPath = <String, SongModel>{
        for (final s in librarySongs) s.data: s
      };

      final restoredQueue = <SongModel>[];
      final queueIdsRaw = map['queueIds'];
      if (queueIdsRaw is List) {
        for (final rawId in queueIdsRaw) {
          if (rawId is! num) continue;
          final song = songsById[rawId.toInt()];
          if (song != null && !restoredQueue.any((s) => s.id == song.id)) {
            restoredQueue.add(song);
          }
        }
      }
      final queuePathsRaw = map['queuePaths'];
      if (queuePathsRaw is List) {
        for (final rawPath in queuePathsRaw) {
          if (rawPath is! String) continue;
          final song = songsByPath[rawPath];
          if (song != null && !restoredQueue.any((s) => s.id == song.id)) {
            restoredQueue.add(song);
          }
        }
      }

      SongModel? restoredSong = savedId != null ? songsById[savedId] : null;
      restoredSong ??= savedPath != null ? songsByPath[savedPath] : null;
      if (restoredSong == null) return;

      if (!restoredQueue.any((s) => s.id == restoredSong!.id)) {
        restoredQueue.add(restoredSong);
      }

      final savedIndex = (map['currentIndex'] is num)
          ? (map['currentIndex'] as num).toInt()
          : -1;
      final restoredIndex = savedIndex >= 0 &&
              savedIndex < restoredQueue.length &&
              restoredQueue[savedIndex].id == restoredSong.id
          ? savedIndex
          : restoredQueue.indexWhere((s) => s.id == restoredSong!.id);
      final wasPlaying = map['wasPlaying'] as bool? ?? false;

      _restoringSession = true;
      try {
        final hasActiveSource = _player.audioSource != null ||
            _player.processingState != ProcessingState.idle;
        if (!hasActiveSource) {
          _syncHandlerPlaybackOptions();
          await _handler.setQueueAndCurrentSong(
              restoredQueue, restoredIndex >= 0 ? restoredIndex : 0);
          await _player.setFilePath(restoredSong.data);

          final positionMs = (map['positionMs'] is num)
              ? (map['positionMs'] as num).toInt()
              : 0;
          final target = Duration(milliseconds: positionMs);
          final max = _player.duration ?? Duration.zero;
          if (target > Duration.zero && (max == Duration.zero || target < max)) {
            await _player.seek(target);
          }
          if (wasPlaying) _requestPlay();
          _handler.refreshPlaybackState();
        } else {
          await _handler.setQueueAndCurrentSong(
              restoredQueue, restoredIndex >= 0 ? restoredIndex : 0);
        }

        // El estado se confirma solo después de cargar el archivo con éxito.
        _queue = restoredQueue;
        _currentIndex = restoredIndex >= 0 ? restoredIndex : 0;
        _isShuffleOn = map['isShuffleOn'] as bool? ?? false;
        _repeatMode = _repeatModeFromName(map['repeatMode'] as String?);
        _syncHandlerPlaybackOptions();
        _isPlaying = _player.playing;
        notifyListeners();
      } finally {
        _restoringSession = false;
      }
    } catch (e) {
      debugPrint('Error restaurando sesión: $e');
    } finally {
      _restoreInProgress = false;
      _restoreAttempted = true;
      _manageVisualizer();
    }
  }

  AppRepeatState _repeatModeFromName(String? value) => switch (value) {
        'all' => AppRepeatState.all,
        'one' => AppRepeatState.one,
        _ => AppRepeatState.off,
      };

  /// Throttle (no debounce): con eventos de posición cada ~100 ms un debounce
  /// de 700 ms nunca llegaba a dispararse durante la reproducción.
  void _scheduleSessionSave() {
    if (currentSong == null || _restoringSession) return;
    final now = DateTime.now();
    if (_lastSessionSave != null &&
        now.difference(_lastSessionSave!) < _saveThrottle) {
      return;
    }
    _lastSessionSave = now;
    unawaited(_saveSession());
  }

  Future<void> _saveSession() async {
    if (_restoringSession) return;
    final song = currentSong;
    if (song == null) return;

    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;

    _lastSessionSave = DateTime.now();
    await prefs.setString(
      _sessionKey,
      jsonEncode(<String, dynamic>{
        'currentId': song.id,
        'currentPath': song.data,
        'currentIndex': _currentIndex,
        'positionMs': _player.position.inMilliseconds,
        'wasPlaying': _player.playing,
        'isShuffleOn': _isShuffleOn,
        'repeatMode': _repeatMode.name,
        'queueIds': _queue.map((s) => s.id).toList(),
        'queuePaths': _queue.map((s) => s.data).toList(),
      }),
    );
  }

  String formatDuration(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static bool _listsEqual(List<SongModel> a, List<SongModel> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _loadVisualizerStyle(SharedPreferences prefs) {
    var saved = prefs.getString(_visualizerKey);
    if (saved != null) {
      if (saved == 'modern') saved = 'minimalist';
      // El radial único pasó a ser la variante 1.
      if (saved == 'radialVisualizer') saved = 'radialBars';
      _animationStyle = VisualizerStyle.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => VisualizerStyle.vinyl,
      );
    }
  }

  void _saveVisualizerStyle() {
    unawaited(_prefs?.setString(_visualizerKey, _animationStyle.name));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _audioSessionSub?.cancel();
    _sleepTimer?.cancel();
    _countdownTimer?.cancel();
    _trackChangeWatchdog?.cancel();
    positionNotifier.dispose();
    durationNotifier.dispose();
    sleepRemainingNotifier.dispose();
    visualizerService.positionMsProvider = null;
    visualizerService.dispose();
    super.dispose();
  }
}
