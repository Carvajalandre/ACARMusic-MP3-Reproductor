import 'dart:math';

/// Lógica pura del espectro radial, separada del widget para poder verificar
/// con tests que los niveles siguen al FFT real (y no a una animación fija).

/// Adapta cualquier número de bandas a [count] sin inventar energía.
///
/// El plugin nativo entrega 64 bandas logarítmicas: en ese caso la copia es 1:1.
/// Solo se interpola linealmente si otra fuente entrega otro tamaño.
List<double> mapRadialBands(List<double> data, int count) {
  if (data.isEmpty) return List<double>.filled(count, 0.0);
  if (data.length == count) {
    return [for (final value in data) value.clamp(0.0, 1.0).toDouble()];
  }
  if (count == 1) {
    return [data.reduce(max).clamp(0.0, 1.0).toDouble()];
  }
  final output = List<double>.filled(count, 0.0);
  final last = data.length - 1;
  for (var i = 0; i < count; i++) {
    final position = i * last / (count - 1);
    final low = position.floor().clamp(0, last);
    final high = min(low + 1, last);
    final t = position - low;
    output[i] =
        (data[low] * (1 - t) + data[high] * t).clamp(0.0, 1.0).toDouble();
  }
  return output;
}

/// Avanza un frame de suavizado de niveles y picos.
///
/// Devuelve `true` si **cualquier** valor cambió, aunque sea menos de 0,001.
/// El comparador de repintado del painter decide después si ese cambio es
/// visible; usar un umbral aquí hacía que la deriva lenta se acumulara en
/// silencio y el radial se quedara congelado en la última imagen pintada.
///
/// No se aplica ninguna atenuación global por "poca energía media": un golpe
/// real suele ocupar 2-3 de las 64 bandas (media ≈ 0,01) y recortarlo convertía
/// la música en un aro pequeño y casi constante. El relieve se controla solo
/// con la velocidad de ataque/release.
bool advanceRadialLevels({
  required List<double> levels,
  required List<double> targets,
  required List<double> peaks,
  required Duration elapsed,
}) {
  var maxTarget = 0.0;
  for (final target in targets) {
    if (target > maxTarget) maxTarget = target;
  }

  var changed = false;
  final fall = elapsed.inMilliseconds * 0.0009;
  for (var i = 0; i < levels.length; i++) {
    final target = (i < targets.length ? targets[i] : 0.0).clamp(0.0, 1.0);
    final speed = target > levels[i] ? 0.72 : (maxTarget < 0.02 ? 0.42 : 0.30);
    final next = (levels[i] + (target - levels[i]) * speed).clamp(0.0, 1.0);
    if (next != levels[i]) changed = true;
    levels[i] = next;

    // Pico retenido: salta con el golpe y cae despacio, como un analizador
    // real. Es lo que hace visible el ritmo entre transitorios.
    final previousPeak = peaks[i];
    final falling = previousPeak - fall;
    final peak = falling > next ? falling : next;
    if (peak != previousPeak) changed = true;
    peaks[i] = peak;
  }
  return changed;
}

/// Orientación determinista de la pista (0..360 grados en radianes).
double radialRotationFor(int? seed) =>
    (((seed ?? 0).abs() % 360) * pi) / 180;
