import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

/// Animación "animation test": escena nocturna en primera persona frente a un
/// monitor ultrawide con un visualizador circular dorado, letras sincronizadas
/// y una transición de cámara (primer plano inclinado → plano abierto).
///
/// Toda la animación usa un único [AnimationController], por lo que respeta
/// `TickerMode` (se detiene en segundo plano) y el consume de batería es
/// predecible. El espectro se alimenta del FFT real del reproductor.
class AnimationTestVisualizer extends StatefulWidget {
  final int? albumId;
  final int? trackId;
  final double size;
  final bool isPlaying;
  final Stream<List<double>>? fftStream;
  final Color glowColor;

  const AnimationTestVisualizer({
    super.key,
    this.albumId,
    this.trackId,
    this.size = 260,
    this.isPlaying = true,
    this.fftStream,
    this.glowColor = const Color(0xFFFFB000),
  });

  @override
  State<AnimationTestVisualizer> createState() =>
      _AnimationTestVisualizerState();
}

class _AnimationTestVisualizerState extends State<AnimationTestVisualizer>
    with SingleTickerProviderStateMixin {
  static const List<String> _lyrics = [
    'NEON HORIZON',
    'SILENT MACHINES',
    'GOLDEN FREQUENCIES',
    'AFTER MIDNIGHT',
    'ECHOES IN THE DARK',
    'WE KEEP MOVING',
  ];

  static const Color _amber = Color(0xFFFFB000);
  static const Color _orange = Color(0xFFFF6A00);

  late final AnimationController _timeline;
  late final Animation<double> _camera;
  late final Animation<double> _watermark;
  late final Animation<double> _intro;

  final List<double> _levels = List<double>.filled(64, 0.0);
  final ValueNotifier<int> _fftTick = ValueNotifier(0);
  StreamSubscription<List<double>>? _fftSub;

  Timer? _lyricTimer;
  Timer? _clockTimer;
  int _lyricIndex = 0;
  DateTime _now = DateTime.now();

  bool get _active => widget.isPlaying;

  @override
  void initState() {
    super.initState();
    _timeline = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    );
    // 0:00-0:01,7 primer plano inclinado → 0:03,4 plano abierto.
    _camera = CurvedAnimation(
      parent: _timeline,
      curve: const Interval(0.12, 0.24, curve: Curves.easeOutCubic),
    );
    // Últimos segundos: la pantalla se oscurece y aparece la marca de agua.
    _watermark = CurvedAnimation(
      parent: _timeline,
      curve: const Interval(0.75, 0.88, curve: Curves.easeInOut),
    );
    _intro = CurvedAnimation(
      parent: _timeline,
      curve: const Interval(0.0, 0.08, curve: Curves.easeOut),
    );

    _subscribeFft();
    if (_active) _startTimers();
  }

  void _subscribeFft() {
    _fftSub?.cancel();
    final stream = widget.fftStream;
    if (stream == null) return;
    _fftSub = stream.listen(
      (data) {
        if (data.isEmpty) return;
        final count = data.length < _levels.length
            ? data.length
            : _levels.length;
        for (var i = 0; i < count; i++) {
          _levels[i] = data[i].clamp(0.0, 1.0).toDouble();
        }
        for (var i = count; i < _levels.length; i++) {
          _levels[i] = 0;
        }
        _fftTick.value++;
      },
      onError: (_) => _clearLevels(),
    );
  }

  void _clearLevels() {
    for (var i = 0; i < _levels.length; i++) {
      _levels[i] = 0;
    }
    _fftTick.value++;
  }

  void _startTimers() {
    if (!_timeline.isAnimating) _timeline.repeat();
    _lyricTimer?.cancel();
    _lyricTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      if (!mounted) return;
      setState(() => _lyricIndex = (_lyricIndex + 1) % _lyrics.length);
    });
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  void _stopTimers() {
    _timeline.stop();
    _lyricTimer?.cancel();
    _lyricTimer = null;
    _clockTimer?.cancel();
    _clockTimer = null;
    _clearLevels();
  }

  @override
  void didUpdateWidget(covariant AnimationTestVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fftStream != widget.fftStream) _subscribeFft();
    if (oldWidget.isPlaying != widget.isPlaying) {
      if (widget.isPlaying) {
        _startTimers();
      } else {
        _stopTimers();
      }
    }
  }

  @override
  void dispose() {
    _fftSub?.cancel();
    _lyricTimer?.cancel();
    _clockTimer?.cancel();
    _timeline.dispose();
    _fftTick.dispose();
    super.dispose();
  }

  /// Reinicia la secuencia, como el clic del cursor en el vídeo original.
  void _replay() {
    _lyricIndex = 0;
    _timeline
      ..reset()
      ..repeat();
    if (_lyricTimer == null) _startTimers();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return GestureDetector(
      onTap: _replay,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _timeline,
          builder: (context, _) {
            return Opacity(
              opacity: _intro.value,
              child: Transform(
                alignment: Alignment.center,
                transform: _cameraMatrix(s, _camera.value),
                child: _buildScene(s),
              ),
            );
          },
        ),
      ),
    );
  }

  Matrix4 _cameraMatrix(double s, double t) {
    final scale = _lerp(1.55, 1.0, t);
    final dx = _lerp(s * 0.22, 0.0, t);
    final dy = _lerp(-s * 0.04, 0.0, t);
    final rotateY = _lerp(-0.30, 0.0, t);
    final perspective = Matrix4.identity()..setEntry(3, 2, 0.0012);
    return perspective *
        Matrix4.translationValues(dx, dy, 0) *
        Matrix4.rotationY(rotateY) *
        Matrix4.diagonal3Values(scale, scale, 1);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  Widget _buildScene(double s) => SizedBox(
        width: s,
        height: s,
        child: Stack(
          children: [
            // Fondo espacial + horizonte del planeta gris.
            Positioned.fill(
              child: CustomPaint(painter: _SpacePainter()),
            ),
            // Monitor ultrawide con borde ámbar.
            Positioned(
              left: s * 0.04,
              right: s * 0.04,
              top: s * 0.10,
              bottom: s * 0.20,
              child: _buildMonitor(s),
            ),
            // Teclado mecánico con RGB sutil.
            Positioned(
              left: s * 0.16,
              right: s * 0.16,
              bottom: s * 0.045,
              height: s * 0.10,
              child: _buildKeyboard(),
            ),
            // Oscurecido final + marca de agua.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _watermark,
                  builder: (context, _) => Opacity(
                    opacity: _watermark.value,
                    child: Container(
                      color: const Color(0xFF000000),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'ACARMUSIC',
                              style: TextStyle(
                                color: _amber,
                                fontSize: s * 0.085,
                                fontWeight: FontWeight.w900,
                                letterSpacing: s * 0.02,
                              ),
                            ),
                            SizedBox(height: s * 0.02),
                            Text(
                              'SOUND IN MOTION',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: s * 0.032,
                                letterSpacing: s * 0.012,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildMonitor(double s) {
    final inner = s * 0.64;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(s * 0.045),
        border: Border.all(color: _amber.withAlpha(140), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: _amber.withAlpha(55),
            blurRadius: s * 0.09,
            spreadRadius: 1,
          ),
          const BoxShadow(color: Colors.black, blurRadius: 18),
        ],
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0A0B10), Color(0xFF050507)],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(s * 0.04),
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _SpacePainter())),
            // Letras, esquina superior izquierda.
            Positioned(
              left: s * 0.055,
              top: s * 0.055,
              child: _buildLyrics(s),
            ),
            // Reloj minimalista, esquina superior derecha.
            Positioned(
              right: s * 0.06,
              top: s * 0.055,
              child: Text(
                '${_now.hour.toString().padLeft(2, '0')}:'
                '${_now.minute.toString().padLeft(2, '0')}',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: s * 0.038,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1,
                ),
              ),
            ),
            // Visualizador circular + portada en el centro.
            Center(
              child: SizedBox(
                width: inner,
                height: inner,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: Size.square(inner),
                      painter: _GoldSpectrumPainter(
                        levels: _levels,
                        repaint: _fftTick,
                      ),
                    ),
                    _buildAlbum(s * 0.30),
                  ],
                ),
              ),
            ),
            // Barra de tareas centrada abajo.
            Positioned(
              left: 0,
              right: 0,
              bottom: s * 0.025,
              child: Center(child: _buildTaskbar(s)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbum(double diameter) => ClipOval(
        child: SizedBox(
          width: diameter,
          height: diameter,
          // La carátula es de la PISTA, no del álbum: con varias canciones de
          // un mismo disco se veía siempre la misma imagen.
          child: widget.trackId != null || widget.albumId != null
              ? QueryArtworkWidget(
                  key: ValueKey('test-art-${widget.trackId ?? widget.albumId}'),
                  id: widget.trackId ?? widget.albumId!,
                  type: widget.trackId != null
                      ? ArtworkType.AUDIO
                      : ArtworkType.ALBUM,
                  artworkFit: BoxFit.cover,
                  artworkWidth: diameter,
                  artworkHeight: diameter,
                  keepOldArtwork: true,
                  nullArtworkWidget: _albumPlaceholder(diameter),
                )
              : _albumPlaceholder(diameter),
        ),
      );

  Widget _albumPlaceholder(double d) => Container(
        color: const Color(0xFF2A0E0E),
        child: Icon(Icons.music_note_rounded,
            color: _orange.withAlpha(210), size: d * 0.4),
      );

  Widget _buildLyrics(double s) => SizedBox(
        width: s * 0.44,
        height: s * 0.24,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(3, (slot) {
            final index = (_lyricIndex - slot) % _lyrics.length;
            final text = _lyrics[index];
            final opacity = slot == 0 ? 1.0 : (slot == 1 ? 0.42 : 0.18);
            final offset = slot * s * 0.012;
            return AnimatedOpacity(
              duration: const Duration(milliseconds: 420),
              opacity: opacity,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 420),
                offset: Offset(0, offset / s),
                child: Padding(
                  padding: EdgeInsets.only(bottom: s * 0.018),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: slot == 0 ? Colors.white : Colors.white70,
                      fontSize: s * (slot == 0 ? 0.036 : 0.028),
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                      shadows: slot == 0
                          ? [
                              Shadow(
                                color: _amber.withAlpha(180),
                                blurRadius: s * 0.035,
                              )
                            ]
                          : null,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      );

  Widget _buildTaskbar(double s) => Container(
        padding: EdgeInsets.symmetric(
          horizontal: s * 0.03,
          vertical: s * 0.012,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(18),
          borderRadius: BorderRadius.circular(s * 0.03),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq_rounded,
                size: s * 0.035, color: _amber),
            SizedBox(width: s * 0.035),
            Icon(Icons.folder_rounded,
                size: s * 0.03, color: Colors.white60),
            SizedBox(width: s * 0.03),
            Icon(Icons.web_rounded, size: s * 0.03, color: Colors.white60),
            SizedBox(width: s * 0.03),
            Container(
              width: s * 0.018,
              height: s * 0.018,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.greenAccent,
              ),
            ),
          ],
        ),
      );

  Widget _buildKeyboard() => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: const Color(0xFF0C0C0F),
          border: Border.all(color: Colors.white12),
          boxShadow: [
            BoxShadow(
              color: _orange.withAlpha(35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Row(
          children: List.generate(14, (i) {
            final hue = (i * 27) % 360;
            final color = HSLColor.fromAHSL(0.55, hue.toDouble(), 0.8, 0.55)
                .toColor()
                .withAlpha(90);
            return Expanded(
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        ),
      );
}

/// Espacio oscuro con el horizonte curvo de un planeta gris.
class _SpacePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const bg = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF05060B), Color(0xFF0B0D14)],
    );
    canvas.drawRect(rect, Paint()..shader = bg.createShader(rect));

    final w = size.width;
    final h = size.height;
    final planet = Offset(w * 0.5, h * 1.42);
    final radius = w * 0.92;
    const gradient = RadialGradient(
      center: Alignment(-0.25, -0.6),
      radius: 0.9,
      colors: [Color(0xFF6E737D), Color(0xFF3A3D45), Color(0xFF121318)],
    );
    final shader =
        gradient.createShader(Rect.fromCircle(center: planet, radius: radius));
    canvas.drawCircle(planet, radius, Paint()..shader = shader);

    final craterPaint = Paint()..color = const Color(0x14FFFFFF);
    for (var i = 0; i < 7; i++) {
      final angle = i * 0.9;
      final cr = w * (0.012 + (i % 3) * 0.006);
      final cx = planet.dx + math.cos(angle) * radius * 0.55;
      final cy = planet.dy + math.sin(angle) * radius * 0.35;
      canvas.drawCircle(Offset(cx, cy), cr, craterPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Espectro radial dorado/naranja alimentado por el FFT real.
class _GoldSpectrumPainter extends CustomPainter {
  final List<double> levels;
  final ValueNotifier<int> repaint;

  _GoldSpectrumPainter({required this.levels, required this.repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final inner = radius * 0.60;
    final maxLen = radius * 0.30;
    final count = levels.length;

    for (var i = 0; i < count; i++) {
      final angle = (i / count) * math.pi * 2 - math.pi / 2;
      final level = levels[i].clamp(0.0, 1.0);
      final length = maxLen * (0.04 + level * 0.96);
      final start = Offset(
        center.dx + math.cos(angle) * inner,
        center.dy + math.sin(angle) * inner,
      );
      final end = Offset(
        center.dx + math.cos(angle) * (inner + length),
        center.dy + math.sin(angle) * (inner + length),
      );
      final color = Color.lerp(
        const Color(0xFFFF6A00),
        const Color(0xFFFFD95A),
        (level * 0.7 + (i / count) * 0.3).clamp(0.0, 1.0),
      )!;

      if (level > 0.12) {
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = color.withAlpha((70 * level).round())
            ..strokeWidth = radius * 0.055
            ..strokeCap = StrokeCap.round
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.05),
        );
      }
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = color.withAlpha((120 + 130 * level).round().clamp(90, 255))
          ..strokeWidth = radius * 0.022
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
