import 'dart:math';

import 'package:flutter/material.dart';

/// Detecta los golpes de graves ("beats") del FFT real.
///
/// No genera datos: solo observa la energía de las bandas bajas y produce un
/// pulso [0..1] que decae. La comparación contra una media móvil evita que un
/// volumen alto sostenido dispare pulsos continuos; el periodo refractario
/// evita que un mismo golpe cuente dos veces.
class RadialBeatDetector {
  RadialBeatDetector({
    this.threshold = 1.25,
    this.minEnergy = 0.08,
    // 250 ms y decaimiento rápido: con el refractario anterior (150 ms) y
    // 1,8 s de cola, el pulso volvía a 1 antes de bajar y quedaba casi fijo,
    // tapando la forma real del espectro con un halo uniforme.
    this.refractory = const Duration(milliseconds: 250),
    this.decayPerSecond = 9.0,
  });

  /// Cuánto debe superar la energía instantánea a la media móvil.
  final double threshold;

  /// Energía mínima absoluta para considerar un golpe (evita ruido en silencio).
  final double minEnergy;

  /// Tiempo mínimo entre golpes.
  final Duration refractory;

  /// Velocidad de decaimiento exponencial del pulso.
  final double decayPerSecond;

  double _average = 0.0;
  bool _hasAverage = false;
  double _pulse = 0.0;
  DateTime? _lastBeat;

  /// Pulso actual, en el rango [0..1].
  double get pulse => _pulse;

  /// Observa la energía de graves de un frame del FFT.
  /// Devuelve `true` cuando se detecta un golpe nuevo.
  ///
  /// [sinceLastFrame] hace que la media móvil tenga la misma constante de
  /// tiempo (~0,4 s) tanto a 30 fps como a 50 fps; antes el umbral de golpe
  /// cambiaba según la fuente del FFT.
  bool observe(double energy, DateTime now, {Duration? sinceLastFrame}) {
    final value = energy.clamp(0.0, 1.0);
    if (!_hasAverage) {
      _average = value;
      _hasAverage = true;
    } else {
      final seconds = sinceLastFrame == null
          ? 1 / 30
          : sinceLastFrame.inMilliseconds / 1000.0;
      final alpha = (1 - exp(-2.5 * seconds.clamp(0.001, 0.25))).clamp(0.0, 1.0);
      _average += (value - _average) * alpha;
    }

    final previous = _lastBeat;
    final ready = previous == null || now.difference(previous) >= refractory;
    if (ready && value >= minEnergy && value > _average * threshold) {
      _pulse = 1.0;
      _lastBeat = now;
      return true;
    }
    return false;
  }

  /// Decaimiento del pulso en cada frame del ticker (independiente de fps).
  void decay(Duration elapsed) {
    if (_pulse <= 0.0) return;
    final seconds = elapsed.inMilliseconds / 1000.0;
    if (seconds <= 0.0) return;
    _pulse *= exp(-decayPerSecond * seconds);
    if (_pulse < 0.002) _pulse = 0.0;
  }

  void reset() {
    _average = 0.0;
    _hasAverage = false;
    _pulse = 0.0;
    _lastBeat = null;
  }
}

/// Paleta del espectro derivada del color vibrante de la portada y de la
/// identidad de la pista. Así cada canción tiene un aspecto propio sin inventar
/// datos de audio: los niveles siguen viniendo del FFT real.
List<Color> buildRadialPalette(Color glow, int? seed) {
  final hsl = HSLColor.fromColor(glow);
  // Desplazamiento determinista por pista (0..357 grados, paso de 3).
  // Con solo 12 valores, pistas distintas (ids 11 y 23, por ejemplo) tenían
  // exactamente la misma paleta y reforzaban la sensación de animación fija.
  final shift = ((seed ?? 0).abs() % 120) * 3.0;
  double hue(double delta) => (hsl.hue + shift + delta + 360) % 360;

  return [
    HSLColor.fromAHSL(1.0, hue(-38), 0.88, 0.46).toColor(),
    HSLColor.fromAHSL(1.0, hue(-12), 0.92, 0.55).toColor(),
    HSLColor.fromAHSL(1.0, hue(20), 0.95, 0.62).toColor(),
    HSLColor.fromAHSL(1.0, hue(62), 0.90, 0.58).toColor(),
    HSLColor.fromAHSL(1.0, hue(110), 0.85, 0.50).toColor(),
  ];
}
