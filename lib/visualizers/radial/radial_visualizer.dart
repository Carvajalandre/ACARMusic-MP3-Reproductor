import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../../theme/app_theme.dart';
import '../animation_style.dart';
import 'radial_audio.dart';
import 'radial_math.dart';

class RadialVisualizer extends StatefulWidget {
  final RadialVariant variant;
  final Stream<List<double>> fftStream;
  final bool isPlaying;
  final Color glowColor;

  /// Identidad de la pista: paleta, rotación y carátula del espectro.
  final int? albumId;
  final int? trackId;

  const RadialVisualizer({
    super.key,
    this.variant = RadialVariant.bars,
    required this.fftStream,
    this.isPlaying = true,
    this.glowColor = AppTheme.primary,
    this.albumId,
    this.trackId,
  });

  @override
  State<RadialVisualizer> createState() => _RadialVisualizerState();
}

class _RadialVisualizerState extends State<RadialVisualizer>
    with SingleTickerProviderStateMixin {
  static const int _barCount = 64;
  // Bandas bajas del FFT nativo (40 Hz ~ 160 Hz): donde está el kick.
  static const int _bassBands = 10;

  final List<double> _levels = List.filled(_barCount, 0.0);
  final List<double> _targets = List.filled(_barCount, 0.0);
  final List<double> _peaks = List.filled(_barCount, 0.0);
  final RadialBeatDetector _beat = RadialBeatDetector();

  StreamSubscription<List<double>>? _subscription;

  // AnimationController en vez de Timer.periodic: TickerMode (app.dart) y el
  // framework silencian el ticker automáticamente en segundo plano.
  late final AnimationController _ticker;

  late List<Color> _palette;
  double _rotation = 0.0;
  DateTime _lastTick = DateTime.now();
  DateTime? _lastFftAt;

  int? get _seed => widget.trackId ?? widget.albumId;

  @override
  void initState() {
    super.initState();
    _configureIdentity();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 33),
    )..repeat();
    _ticker.addListener(_tick);
    _subscribe();
  }

  void _subscribe() {
    _subscription = widget.fftStream.listen(
      _processFftData,
      onError: (_) => _resetLevels(),
    );
  }

  /// Cada pista tiene su propia paleta (color de la carátula + desplazamiento
  /// determinista) y su propia orientación. El audio sigue siendo real: esto
  /// solo cambia la presentación, nunca los valores del FFT.
  void _configureIdentity() {
    _palette = buildRadialPalette(widget.glowColor, _seed);
    _rotation = radialRotationFor(_seed);
  }

  @override
  void didUpdateWidget(covariant RadialVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.glowColor != widget.glowColor ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.trackId != widget.trackId) {
      // Identidad nueva: paleta, orientación y carátula nuevas, pero también
      // niveles/picos/golpe nuevos. Sin esto, una pista podía heredar la
      // forma de la anterior aunque el FFT ya estuviera en la nueva.
      _configureIdentity();
      _resetLevels();
    }
    if (oldWidget.isPlaying && !widget.isPlaying) _resetLevels();
    if (oldWidget.fftStream != widget.fftStream) {
      unawaited(_subscription?.cancel());
      _resetLevels();
      _subscribe();
    }
  }

  void _resetLevels() {
    for (var i = 0; i < _barCount; i++) {
      _levels[i] = 0.0;
      _targets[i] = 0.0;
      _peaks[i] = 0.0;
    }
    _beat.reset();
    _lastFftAt = null;
  }

  void _processFftData(List<double> data) {
    if (data.isEmpty) return;
    final now = DateTime.now();
    if (!widget.isPlaying) {
      _targets.fillRange(0, _barCount, 0.0);
      _beat.reset();
      _lastFftAt = null;
      return;
    }

    // El nativo entrega 64 bandas logarítmicas: se usan 1:1 alrededor de todo
    // el círculo. Remuestreo lineal solo si el nativo entrega otro tamaño.
    final mapped = mapRadialBands(data, _barCount);
    for (var i = 0; i < _barCount; i++) {
      _targets[i] = mapped[i];
    }

    var bass = 0.0;
    final count = min(_bassBands, mapped.length);
    for (var i = 0; i < count; i++) {
      bass += mapped[i];
    }
    // La media móvil del detector se actualiza con el tiempo REAL entre
    // frames: nativo (50 Hz), offline (~43 Hz) y ticker (~60 Hz) pueden tener
    // ritmos distintos y la sensibilidad no debe depender de ellos.
    _beat.observe(
      bass / count,
      now,
      sinceLastFrame: _lastFftAt == null ? null : now.difference(_lastFftAt!),
    );
    _lastFftAt = now;
  }

  void _tick() {
    if (!mounted) return;
    final now = DateTime.now();
    final elapsed = now.difference(_lastTick);
    _lastTick = now;

    final pulseBefore = _beat.pulse;
    _beat.decay(elapsed);
    var changed = _beat.pulse != pulseBefore;

    // Repintar si CUALQUIER nivel cambió, por pequeño que sea. El umbral que
    // había aquí (0,001 por tick) dejaba derivas lentas sin repintar: el
    // painter seguía mostrando la imagen anterior aunque los datos ya hubieran
    // cambiado. `shouldRepaint` compara por contenido, así que no hay coste
    // extra cuando no hay cambios reales.
    if (advanceRadialLevels(
      levels: _levels,
      targets: _targets,
      peaks: _peaks,
      elapsed: elapsed,
    )) {
      changed = true;
    }
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _ticker.removeListener(_tick);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final painter = _RadialPainter(
      levels: List<double>.unmodifiable(_levels),
      peaks: List<double>.unmodifiable(_peaks),
      pulse: _beat.pulse,
      palette: _palette,
      rotation: _rotation,
      variant: widget.variant,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return CustomPaint(size: Size.infinite, painter: painter);
        }
        return Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(size: Size.infinite, painter: painter),
            _buildArtwork(constraints),
          ],
        );
      },
    );
  }

  /// Carátula de la pista en el centro. La clave incluye el id de la pista para
  /// que `QueryArtworkWidget` recargue la imagen al cambiar de canción (sin
  /// clave se quedaba mostrando la primera carátula que hubiera cargado).
  Widget _buildArtwork(BoxConstraints constraints) {
    final int? artId;
    final ArtworkType artType;
    if (widget.trackId != null) {
      artId = widget.trackId;
      artType = ArtworkType.AUDIO;
    } else if (widget.albumId != null) {
      artId = widget.albumId;
      artType = ArtworkType.ALBUM;
    } else {
      artId = null;
      artType = ArtworkType.AUDIO;
    }

    final shortest = min(constraints.maxWidth, constraints.maxHeight);
    final diameter = shortest * 0.32;
    return SizedBox(
      width: diameter,
      height: diameter,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: _palette[1].withAlpha(150), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: _palette[1].withAlpha(55),
              blurRadius: diameter * 0.16,
            )
          ],
        ),
        child: ClipOval(
          child: artId == null
              ? _artworkPlaceholder(diameter)
              : QueryArtworkWidget(
                  key: ValueKey('radial-art-${artType.name}-$artId'),
                  id: artId,
                  type: artType,
                  artworkFit: BoxFit.cover,
                  artworkWidth: diameter,
                  artworkHeight: diameter,
                  keepOldArtwork: true,
                  nullArtworkWidget: _artworkPlaceholder(diameter),
                ),
        ),
      ),
    );
  }

  Widget _artworkPlaceholder(double diameter) => Container(
        color: const Color(0xFF0D0A20),
        child: Icon(Icons.music_note_rounded,
            color: _palette[2].withAlpha(210), size: diameter * 0.38),
      );
}

class _RadialPainter extends CustomPainter {
  final List<double> levels;
  final List<double> peaks;
  final double pulse;
  final List<Color> palette;
  final double rotation;
  final RadialVariant variant;

  const _RadialPainter({
    required this.levels,
    required this.peaks,
    required this.pulse,
    required this.palette,
    required this.rotation,
    required this.variant,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || palette.length < 2 || size.isEmpty) return;

    final shortest = min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final inner = shortest * 0.21;
    final maxLen = shortest * 0.26;
    final stroke = (shortest / 105).clamp(2.0, 4.5);

    // Anillo que late con los graves: refuerza visualmente cada golpe.
    if (pulse > 0.01) {
      canvas.drawCircle(
        center,
        inner - stroke * (1 + pulse * 2),
        Paint()
          ..color = palette[1].withAlpha((55 * pulse).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.4,
      );
    }

    switch (variant) {
      case RadialVariant.bars:
        _paintBars(canvas, center, inner, maxLen, stroke);
      case RadialVariant.wave:
        _paintWave(canvas, center, inner, maxLen, stroke, Offset.zero & size);
      case RadialVariant.petals:
        _paintPetals(canvas, center, inner, maxLen, stroke);
      case RadialVariant.dual:
        _paintDual(canvas, center, inner, maxLen, stroke);
      case RadialVariant.dots:
        _paintDots(canvas, center, inner, maxLen, stroke);
    }
  }

  // ── 1. Barras ─────────────────────────────────────────────────────────────
  void _paintBars(Canvas canvas, Offset center, double inner, double maxLen,
      double stroke) {
    for (var i = 0; i < levels.length; i++) {
      final angle = _angle(i);
      final level = _levelAt(i);
      if (level < 0.01 && peaks[i] < 0.04) continue;
      final color = _colorAt(i / levels.length);
      final length = maxLen * level;
      final start = _point(center, inner, angle);
      final end = _point(center, inner + length, angle);

      if (level > 0.2) {
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = color.withAlpha((42 * _opacity(level)).round())
            ..strokeWidth = stroke * 2.6
            ..strokeCap = StrokeCap.round,
        );
      }
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = color.withAlpha((110 + 145 * _opacity(level)).round().clamp(90, 255))
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
      _drawPeak(canvas, center, inner, maxLen, angle, i, color, stroke);
    }
  }

  // ── 2. Onda ───────────────────────────────────────────────────────────────
  void _paintWave(Canvas canvas, Offset center, double inner, double maxLen,
      double stroke, Rect bounds) {
    final n = levels.length;
    final points = <Offset>[
      for (var i = 0; i < n; i++)
        _point(center, inner + maxLen * (0.06 + _levelAt(i) * 0.94), _angle(i)),
    ];
    final path = Path();
    final first = _mid(points[n - 1], points[0]);
    path.moveTo(first.dx, first.dy);
    for (var i = 0; i < n; i++) {
      final next = _mid(points[i], points[(i + 1) % n]);
      path.quadraticBezierTo(points[i].dx, points[i].dy, next.dx, next.dy);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = SweepGradient(colors: [
          for (final c in palette) c.withAlpha((52 + pulse * 35).round()),
          palette.first.withAlpha(52),
        ]).createShader(bounds)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..shader = SweepGradient(colors: [...palette, palette.first])
            .createShader(bounds)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.9,
    );
    for (var i = 0; i < n; i += 2) {
      if (peaks[i] > 0.06) {
        _drawPeak(
            canvas, center, inner, maxLen, _angle(i), i, _colorAt(i / n), stroke * 0.8);
      }
    }
  }

  // ── 3. Pétalos ────────────────────────────────────────────────────────────
  void _paintPetals(Canvas canvas, Offset center, double inner, double maxLen,
      double stroke) {
    for (var i = 0; i < levels.length; i++) {
      final level = _levelAt(i);
      if (level < 0.02) continue;
      final length = maxLen * level;
      final width = stroke * (0.9 + level * 1.7);
      final color = _colorAt(i / levels.length);
      final angle = _angle(i);

      final petal = Path()
        ..moveTo(inner, 0)
        ..quadraticBezierTo(inner + length * 0.45, -width * 1.7, inner + length, 0)
        ..quadraticBezierTo(inner + length * 0.45, width * 1.7, inner, 0)
        ..close();

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      if (level > 0.45) {
        canvas.drawPath(
          petal,
          Paint()
            ..color = color.withAlpha((45 * level).round())
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 1.5),
        );
      }
      canvas.drawPath(
        petal,
        Paint()..color = color.withAlpha((95 + 135 * level).round().clamp(0, 255)),
      );
      canvas.restore();

      _drawPeak(canvas, center, inner, maxLen, angle, i, color, stroke * 0.8);
    }
  }

  // ── 4. Doble anillo ──────────────────────────────────────────────────────
  void _paintDual(Canvas canvas, Offset center, double inner, double maxLen,
      double stroke) {
    final n = levels.length;
    final half = n ~/ 2;
    for (var i = 0; i < n; i++) {
      final angle = _angle(i);
      final low = _levelAt(i % half);
      final high = _levelAt(half + (i % half));
      _drawLine(canvas, center, inner, maxLen * 0.46, angle, low,
          stroke * 0.8, _colorAt(i / n));
      _drawLine(canvas, center, inner + maxLen * 0.56, maxLen * 0.44, angle,
          high, stroke * 0.8, _colorAt((i + half) / n));
      _drawPeak(canvas, center, inner + maxLen * 0.56, maxLen * 0.44, angle,
          half + (i % half), _colorAt((i + half) / n), stroke * 0.7);
    }
  }

  // ── 5. Neón (puntos) ─────────────────────────────────────────────────────
  void _paintDots(Canvas canvas, Offset center, double inner, double maxLen,
      double stroke) {
    final n = levels.length;
    final points = <Offset>[
      for (var i = 0; i < n; i++)
        _point(center, inner + maxLen * (0.10 + _levelAt(i) * 0.90), _angle(i)),
    ];

    final link = Path()..moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < n; i++) {
      link.lineTo(points[i].dx, points[i].dy);
    }
    link.close();
    canvas.drawPath(
      link,
      Paint()
        ..color = palette[1].withAlpha((28 + pulse * 30).round())
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.5,
    );

    for (var i = 0; i < n; i++) {
      final level = _levelAt(i);
      final color = _colorAt(i / n);
      final radius = stroke * (0.55 + level * 1.25 + pulse * 0.5);
      if (level > 0.22) {
        canvas.drawCircle(
          points[i],
          radius * 2.1,
          Paint()
            ..color = color.withAlpha((38 * level).round())
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 1.5),
        );
      }
      canvas.drawCircle(
        points[i],
        radius,
        Paint()
          ..color = color.withAlpha((130 + 110 * level).round().clamp(0, 255)),
      );
      if (peaks[i] > 0.06) {
        canvas.drawCircle(
          _point(center, inner + maxLen * peaks[i], _angle(i)),
          stroke * 0.4,
          Paint()..color = color.withAlpha(120),
        );
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  double _angle(int index) =>
      (index / levels.length) * 2 * pi - pi / 2 + rotation;

  Offset _point(Offset center, double radius, double angle) => Offset(
        center.dx + cos(angle) * radius,
        center.dy + sin(angle) * radius,
      );

  Offset _mid(Offset a, Offset b) =>
      Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

  double _levelAt(int index) {
    if (index >= levels.length) return 0.0;
    final raw = levels[index].clamp(0.0, 1.0);
    // El golpe expande y aclara sin inventar energía: la forma sigue siendo
    // la del FFT de esa pista en ese instante.
    // El golpe realza la forma del FFT, pero no la sustituye: si el pulso
    // aportara demasiado, el círculo respiraría igual con cualquier canción.
    return (raw + pulse * (0.06 + raw * 0.15)).clamp(0.0, 1.0);
  }

  double _opacity(double level) =>
      (0.30 + level * 0.58 + pulse * 0.08).clamp(0.0, 1.0);

  void _drawLine(Canvas canvas, Offset center, double startRadius,
      double maxLength, double angle, double level, double width, Color color) {
    if (level < 0.015) return;
    canvas.drawLine(
      _point(center, startRadius, angle),
      _point(center, startRadius + maxLength * level, angle),
      Paint()
        ..color = color.withAlpha((110 + 145 * level).round().clamp(0, 255))
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawPeak(Canvas canvas, Offset center, double startRadius,
      double maxLength, double angle, int index, Color color, double stroke) {
    final peak = peaks[index].clamp(0.0, 1.0);
    if (peak <= 0.04) return;
    canvas.drawCircle(
      _point(center, startRadius + maxLength * peak + stroke, angle),
      stroke * 0.55,
      Paint()
        ..color = color.withAlpha((90 + 120 * pulse).round().clamp(0, 255)),
    );
  }

  Color _colorAt(double t) {
    final scaled = t * (palette.length - 1);
    final index = scaled.floor().clamp(0, palette.length - 2);
    return Color.lerp(palette[index], palette[index + 1], scaled - index)!;
  }

  @override
  bool shouldRepaint(covariant _RadialPainter old) {
    if (old.levels.length != levels.length ||
        old.peaks.length != peaks.length ||
        old.pulse != pulse ||
        old.rotation != rotation ||
        old.variant != variant ||
        old.palette.length != palette.length) {
      return true;
    }
    for (var i = 0; i < palette.length; i++) {
      if (old.palette[i] != palette[i]) return true;
    }
    for (var i = 0; i < levels.length; i++) {
      if (old.levels[i] != levels[i] || old.peaks[i] != peaks[i]) return true;
    }
    return false;
  }
}
