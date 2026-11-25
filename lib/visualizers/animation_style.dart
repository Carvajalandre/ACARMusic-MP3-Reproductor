/// Variantes del Espectro radial. Todas consumen el mismo FFT real, el mismo
/// detector de golpes y la misma imagen de la pista; cambia solo el dibujo.
enum RadialVariant { bars, wave, petals, dual, dots }

enum VisualizerStyle {
  vinyl,
  barVisualizer,
  radialBars,
  radialWave,
  radialPetals,
  radialDual,
  radialDots,
  minimalist,
  animationTest;

  RadialVariant? get radialVariant => switch (this) {
        VisualizerStyle.radialBars => RadialVariant.bars,
        VisualizerStyle.radialWave => RadialVariant.wave,
        VisualizerStyle.radialPetals => RadialVariant.petals,
        VisualizerStyle.radialDual => RadialVariant.dual,
        VisualizerStyle.radialDots => RadialVariant.dots,
        _ => null,
      };

  /// `true` cuando el estilo necesita que el Visualizer nativo esté activo.
  bool get usesFft =>
      radialVariant != null ||
      this == VisualizerStyle.barVisualizer ||
      this == VisualizerStyle.animationTest;

  String get displayName {
    switch (this) {
      case VisualizerStyle.vinyl:
        return 'Disco de vinilo';
      case VisualizerStyle.barVisualizer:
        return 'Barras de espectro';
      case VisualizerStyle.radialBars:
        return 'Espectro radial 1 · Barras';
      case VisualizerStyle.radialWave:
        return 'Espectro radial 2 · Onda';
      case VisualizerStyle.radialPetals:
        return 'Espectro radial 3 · Pétalos';
      case VisualizerStyle.radialDual:
        return 'Espectro radial 4 · Doble anillo';
      case VisualizerStyle.radialDots:
        return 'Espectro radial 5 · Neón';
      case VisualizerStyle.minimalist:
        return 'Minimalista';
      case VisualizerStyle.animationTest:
        return 'animation test';
    }
  }

  /// Texto secundario del selector de animaciones.
  String get description {
    switch (this) {
      case VisualizerStyle.radialBars:
        return 'Barras clásicas con picos retenidos';
      case VisualizerStyle.radialWave:
        return 'Curva continua que respira con el ritmo';
      case VisualizerStyle.radialPetals:
        return 'Pétalos que se abren con cada golpe';
      case VisualizerStyle.radialDual:
        return 'Graves y agudos en dos anillos';
      case VisualizerStyle.radialDots:
        return 'Puntos de neón unidos por una constelación';
      default:
        return '';
    }
  }

  String get iconLabel {
    switch (this) {
      case VisualizerStyle.vinyl:
        return '💿';
      case VisualizerStyle.barVisualizer:
        return '📊';
      case VisualizerStyle.radialBars:
        return '1️⃣';
      case VisualizerStyle.radialWave:
        return '2️⃣';
      case VisualizerStyle.radialPetals:
        return '3️⃣';
      case VisualizerStyle.radialDual:
        return '4️⃣';
      case VisualizerStyle.radialDots:
        return '5️⃣';
      case VisualizerStyle.minimalist:
        return '◻️';
      case VisualizerStyle.animationTest:
        return '✨';
    }
  }
}
