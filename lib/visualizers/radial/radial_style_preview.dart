import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../animation_style.dart';
import 'radial_audio.dart';

/// Miniatura estática de cada variante para el selector de animaciones.
/// Los niveles son solo decorativos: no representan audio ni sustituyen al FFT.
class RadialStylePreview extends StatelessWidget {
  final RadialVariant variant;
  final double size;

  const RadialStylePreview({
    super.key,
    required this.variant,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _PreviewPainter(variant: variant)),
      );
}

class _PreviewPainter extends CustomPainter {
  static const int _count = 36;
  final RadialVariant variant;

  const _PreviewPainter({required this.variant});

  static final List<Color> palette = buildRadialPalette(AppTheme.primary, 5);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;
    final inner = radius * 0.34;
    final maxLen = radius * 0.52;
    final stroke = (radius / 8).clamp(1.0, 3.0);

    // Carátula simulada en miniatura (solo decoración).
    canvas.drawCircle(
      center,
      inner * 0.82,
      Paint()..color = Colors.white.withAlpha(28),
    );

    final levels = List<double>.generate(_count, (i) {
      final wave = (sin(i * 0.72) + 1) / 2;
      return 0.22 + wave * 0.72 * (0.55 + 0.45 * cos(i * 0.31).abs());
    });

    switch (variant) {
      case RadialVariant.bars:
      case RadialVariant.dual:
        for (var i = 0; i < _count; i++) {
          final angle = _angle(i);
          if (variant == RadialVariant.dual) {
            _line(canvas, center, inner, maxLen * 0.45, angle, levels[i],
                stroke * 0.8, _color(i / _count));
            _line(
                canvas,
                center,
                inner + maxLen * 0.55,
                maxLen * 0.45,
                angle,
                levels[(_count ~/ 2 + i) % _count],
                stroke * 0.8,
                _color((i + _count ~/ 2) / _count));
          } else {
            _line(canvas, center, inner, maxLen, angle, levels[i], stroke,
                _color(i / _count));
          }
        }
      case RadialVariant.wave:
        final points = <Offset>[
          for (var i = 0; i < _count; i++)
            _point(center, inner + maxLen * levels[i], _angle(i)),
        ];
        final path = Path();
        final start = _mid(points.last, points.first);
        path.moveTo(start.dx, start.dy);
        for (var i = 0; i < _count; i++) {
          final next = _mid(points[i], points[(i + 1) % _count]);
          path.quadraticBezierTo(points[i].dx, points[i].dy, next.dx, next.dy);
        }
        path.close();
        canvas.drawPath(path, Paint()..color = palette[1].withAlpha(70));
        canvas.drawPath(
          path,
          Paint()
            ..color = palette[2].withAlpha(220)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke,
        );
      case RadialVariant.petals:
        for (var i = 0; i < _count; i++) {
          final length = maxLen * levels[i];
          final width = stroke * 1.5;
          final petal = Path()
            ..moveTo(inner, 0)
            ..quadraticBezierTo(
                inner + length * 0.45, -width * 1.7, inner + length, 0)
            ..quadraticBezierTo(
                inner + length * 0.45, width * 1.7, inner, 0)
            ..close();
          canvas.save();
          canvas.translate(center.dx, center.dy);
          canvas.rotate(_angle(i));
          canvas.drawPath(
              petal, Paint()..color = _color(i / _count).withAlpha(200));
          canvas.restore();
        }
      case RadialVariant.dots:
        final points = <Offset>[
          for (var i = 0; i < _count; i++)
            _point(center, inner + maxLen * levels[i], _angle(i)),
        ];
        final link = Path()..moveTo(points.first.dx, points.first.dy);
        for (var i = 1; i < _count; i++) {
          link.lineTo(points[i].dx, points[i].dy);
        }
        link.close();
        canvas.drawPath(
          link,
          Paint()
            ..color = palette[1].withAlpha(70)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * 0.6,
        );
        for (var i = 0; i < _count; i++) {
          canvas.drawCircle(
            points[i],
            stroke * (0.8 + levels[i]),
            Paint()..color = _color(i / _count),
          );
        }
    }
  }

  double _angle(int i) => (i / _count) * 2 * pi - pi / 2;

  Offset _point(Offset center, double radius, double angle) => Offset(
        center.dx + cos(angle) * radius,
        center.dy + sin(angle) * radius,
      );

  Offset _mid(Offset a, Offset b) =>
      Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

  Color _color(double t) {
    final scaled = t * (palette.length - 1);
    final index = scaled.floor().clamp(0, palette.length - 2);
    return Color.lerp(palette[index], palette[index + 1], scaled - index)!;
  }

  void _line(Canvas canvas, Offset center, double start, double maxLen,
      double angle, double level, double width, Color color) {
    canvas.drawLine(
      _point(center, start, angle),
      _point(center, start + maxLen * level, angle),
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) => old.variant != variant;
}
