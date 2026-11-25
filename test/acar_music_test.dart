import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:acar_music/library/models/custom_playlist.dart';
import 'package:acar_music/theme/theme_provider.dart';
import 'package:acar_music/visualizers/animation_style.dart';
import 'package:acar_music/visualizers/radial/radial_audio.dart';
import 'package:acar_music/visualizers/radial/radial_math.dart';
import 'package:acar_music/visualizers/radial/radial_visualizer.dart';

void main() {
  group('CustomPlaylist', () {
    test('round-trip JSON conserva id, nombre y orden de canciones', () {
      final original = CustomPlaylist(
        id: '1712345678901',
        name: 'Favoritos',
        songIds: const [12, 7, 99],
      );

      final decoded = CustomPlaylist.decodeList(
        CustomPlaylist.encodeList([original]),
      ).single;

      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.songIds, original.songIds);
    });

    test('datos corruptos no descartan las demás playlists', () {
      const raw = '[{"id":"a","name":"A","songIds":[1,2]},'
          '{"id":"b","name":"B","songIds":"invalido"}]';

      final decoded = CustomPlaylist.decodeList(raw);

      expect(decoded.length, 2);
      expect(decoded[0].songIds, [1, 2]);
      expect(decoded[1].songIds, isEmpty);
    });

    test('copyWith mantiene el id original', () {
      final pl = CustomPlaylist(id: 'x', name: 'Vieja', songIds: const [1]);
      final copy = pl.copyWith(name: 'Nueva');
      expect(copy.id, 'x');
      expect(copy.name, 'Nueva');
      expect(copy.songIds, [1]);
    });
  });

  group('ThemeProvider', () {
    test('modeFromName interpreta los valores persistidos', () {
      expect(ThemeProvider.modeFromName('light'), ThemeMode.light);
      expect(ThemeProvider.modeFromName('dark'), ThemeMode.dark);
      expect(ThemeProvider.modeFromName('system'), ThemeMode.system);
      expect(ThemeProvider.modeFromName(null), ThemeMode.dark);
      expect(ThemeProvider.modeFromName('desconocido'), ThemeMode.dark);
    });
  });

  group('VisualizerStyle', () {
    test('los nombres visibles están en español', () {
      expect(VisualizerStyle.barVisualizer.displayName, 'Barras de espectro');
      expect(VisualizerStyle.vinyl.displayName, 'Disco de vinilo');
      expect(VisualizerStyle.animationTest.displayName, 'animation test');
    });

    test('los cinco estilos radiales están enumerados y usan FFT', () {
      final radialStyles = VisualizerStyle.values
          .where((style) => style.radialVariant != null)
          .toList();

      expect(radialStyles.length, 5);
      expect(
        radialStyles.map((style) => style.displayName).toList(),
        [
          'Espectro radial 1 · Barras',
          'Espectro radial 2 · Onda',
          'Espectro radial 3 · Pétalos',
          'Espectro radial 4 · Doble anillo',
          'Espectro radial 5 · Neón',
        ],
      );
      expect(radialStyles.every((style) => style.usesFft), isTrue);
      expect(VisualizerStyle.vinyl.usesFft, isFalse);
    });
  });

  group('RadialBeatDetector', () {
    final start = DateTime(2026, 1, 1);

    test('un golpe de graves dispara el pulso', () {
      final detector = RadialBeatDetector();
      // La primera muestra solo inicializa la media.
      expect(detector.observe(0.30, start), isFalse);
      for (var i = 1; i <= 10; i++) {
        detector.observe(0.30, start.add(Duration(milliseconds: i * 40)));
      }
      expect(detector.observe(0.60, start.add(const Duration(milliseconds: 500))),
          isTrue);
      expect(detector.pulse, 1.0);
    });

    test('el volumen sostenido y el silencio no disparan pulsos', () {
      final detector = RadialBeatDetector();
      detector.observe(0.5, start);
      for (var i = 1; i <= 30; i++) {
        expect(detector.observe(0.5, start.add(Duration(milliseconds: i * 40))),
            isFalse);
      }
      expect(
          detector.observe(0.0, start.add(const Duration(milliseconds: 1300))),
          isFalse);
    });

    test('respeta el periodo refractario y el pulso decae a cero', () {
      final detector = RadialBeatDetector();
      detector.observe(0.30, start);
      for (var i = 1; i <= 10; i++) {
        detector.observe(0.30, start.add(Duration(milliseconds: i * 40)));
      }
      final hit = start.add(const Duration(milliseconds: 500));
      expect(detector.observe(0.60, hit), isTrue);
      expect(detector.observe(0.90, hit.add(const Duration(milliseconds: 40))),
          isFalse);

      detector.decay(const Duration(milliseconds: 2000));
      expect(detector.pulse, 0.0);
    });
  });

  group('buildRadialPalette', () {
    test('cada pista produce una paleta diferente', () {
      const glow = Color(0xFF6D28D9);
      final a = buildRadialPalette(glow, 11);
      final b = buildRadialPalette(glow, 12);

      expect(a.length, 5);
      expect(a, isNot(b));
    });

    test('ids con el mismo resto módulo 12 ya no comparten paleta', () {
      const glow = Color(0xFF6D28D9);
      // 11 % 12 == 23 % 12: con el desplazamiento antiguo eran idénticas.
      expect(buildRadialPalette(glow, 11),
          isNot(buildRadialPalette(glow, 23)));
      expect(radialRotationFor(11), isNot(radialRotationFor(23)));
      expect(radialRotationFor(null), 0.0);
    });
  });

  group('RadialBeatDetector · decaimiento', () {
    final start = DateTime(2026, 1, 1);

    test('el pulso baja rápido para no tapar la forma del espectro', () {
      final detector = RadialBeatDetector();
      detector.observe(0.30, start);
      for (var i = 1; i <= 10; i++) {
        detector.observe(0.30, start.add(Duration(milliseconds: i * 40)));
      }
      expect(
          detector.observe(
              0.60, start.add(const Duration(milliseconds: 500))),
          isTrue);

      detector.decay(const Duration(milliseconds: 500));
      expect(detector.pulse, lessThan(0.2));
      detector.decay(const Duration(milliseconds: 1000));
      expect(detector.pulse, 0.0);
    });
  });

  group('RadialVisualizer · el nivel sigue al FFT', () {
    const frame = Duration(milliseconds: 33);

    test('las 64 bandas se usan 1:1 alrededor del círculo', () {
      final data = List<double>.generate(64, (i) => i / 63);
      final mapped = mapRadialBands(data, 64);
      expect(mapped.length, 64);
      for (var i = 0; i < 64; i++) {
        expect(mapped[i], data[i]);
      }
    });

    test('el remuestreo no pierde la localización de los graves', () {
      final data = List<double>.filled(32, 0.0);
      data[0] = 1.0;
      final mapped = mapRadialBands(data, 64);
      expect(mapped.first, greaterThan(0.9));
      expect(mapped.last, lessThan(0.1));
    });

    test('un golpe aislado no se aplana por la energía media', () {
      final levels = List<double>.filled(64, 0.0);
      final targets = List<double>.filled(64, 0.0);
      final peaks = List<double>.filled(64, 0.0);
      targets[0] = 0.6; // media ≈ 0,009: antes se recortaba con * 0,45.
      for (var i = 0; i < 25; i++) {
        advanceRadialLevels(
            levels: levels, targets: targets, peaks: peaks, elapsed: frame);
      }
      expect(levels[0], greaterThan(0.5));
      expect(levels[1], lessThan(0.01));
    });

    test('una deriva menor a 0,001 por tick también marca cambio', () {
      final levels = List<double>.filled(64, 0.5);
      final targets = List<double>.filled(64, 0.5);
      final peaks = List<double>.filled(64, 0.5);
      targets[0] = 0.501; // avance por tick = 0,00072 (< 0,001).
      var changes = 0;
      for (var i = 0; i < 100; i++) {
        if (advanceRadialLevels(
            levels: levels, targets: targets, peaks: peaks, elapsed: frame)) {
          changes++;
        }
      }
      expect(levels[0], greaterThan(0.5));
      // Antes el delta nunca superaba 0,001 y `changed` era siempre false:
      // la deriva se acumulaba sin llegar nunca al painter.
      expect(changes, greaterThan(0));
    });

    test('el pico retenido cae más despacio que el nivel', () {
      final levels = List<double>.filled(64, 0.0);
      final targets = List<double>.filled(64, 0.0);
      final peaks = List<double>.filled(64, 0.0);
      targets[0] = 1.0;
      for (var i = 0; i < 10; i++) {
        advanceRadialLevels(
            levels: levels, targets: targets, peaks: peaks, elapsed: frame);
      }
      expect(peaks[0], greaterThan(0.9));
      targets[0] = 0.0;
      for (var i = 0; i < 5; i++) {
        advanceRadialLevels(
            levels: levels, targets: targets, peaks: peaks, elapsed: frame);
      }
      expect(levels[0], lessThan(0.3));
      expect(peaks[0], greaterThan(levels[0]));
    });

    testWidgets('un frame nuevo del stream repinta el radial', (tester) async {
      final controller = StreamController<List<double>>.broadcast();
      addTearDown(controller.close);
      await tester.pumpWidget(MaterialApp(
        home: SizedBox(
          width: 300,
          height: 300,
          child: RadialVisualizer(fftStream: controller.stream),
        ),
      ));

      CustomPaint radialPaint() => find
          .byType(CustomPaint)
          .evaluate()
          .map((element) => element.widget as CustomPaint)
          .firstWhere((paint) =>
              paint.painter.toString().contains('RadialPainter'));

      final before = radialPaint().painter;
      controller.add(List<double>.filled(64, 1.0));
      await tester.pump(const Duration(milliseconds: 80));
      final after = radialPaint().painter;

      expect(identical(before, after), isFalse);
    });
  });
}
