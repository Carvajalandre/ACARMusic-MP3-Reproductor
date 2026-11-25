import 'package:flutter/material.dart';
import 'animation_style.dart';
import 'bar/bar_visualizer.dart';
import 'radial/radial_visualizer.dart';
import 'minimalist/minimalist_visualizer.dart';
import 'vinyl/vinyl_record.dart';
import 'animation_test/animation_test_visualizer.dart';

class VisualizerFactory extends StatefulWidget {
  final VisualizerStyle style;
  final bool isPlaying;
  final int? albumId;
  final int? trackId;
  final Color glowColor;
  final Color paletteDominant;
  final Color paletteMuted;
  final double size;
  final Stream<List<double>>? fftStream;

  const VisualizerFactory({
    super.key,
    required this.style,
    required this.isPlaying,
    this.albumId,
    this.trackId,
    this.glowColor = const Color(0xFF6D28D9),
    this.paletteDominant = const Color(0xFF1A0A2E),
    this.paletteMuted = const Color(0xFF0D0A20),
    this.size = 260,
    this.fftStream,
  });

  @override
  State<VisualizerFactory> createState() => _VisualizerFactoryState();
}

class _VisualizerFactoryState extends State<VisualizerFactory> {
  // Broadcast para poder sobrevivir al solapamiento de AnimatedSwitcher al
  // cambiar de estilo (dos hijos vivos escuchan durante la transición).
  late final Stream<List<double>> _fallbackStream =
      Stream<List<double>>.periodic(
    const Duration(milliseconds: 80),
    (_) => List<double>.filled(64, 0.0),
  ).asBroadcastStream();

  @override
  Widget build(BuildContext context) {
    switch (widget.style) {
      case VisualizerStyle.vinyl:
        return VinylRecord(
          isPlaying: widget.isPlaying,
          albumId: widget.albumId,
          glowColor: widget.glowColor,
          size: widget.size,
        );
      case VisualizerStyle.barVisualizer:
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: BarVisualizer(
            fftStream: widget.fftStream ?? _fallbackStream,
            isPlaying: widget.isPlaying,
            paletteVibrant: widget.glowColor,
            paletteDominant: widget.paletteDominant,
            paletteMuted: widget.paletteMuted,
          ),
        );
      case VisualizerStyle.radialBars:
      case VisualizerStyle.radialWave:
      case VisualizerStyle.radialPetals:
      case VisualizerStyle.radialDual:
      case VisualizerStyle.radialDots:
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: RadialVisualizer(
            variant: widget.style.radialVariant!,
            fftStream: widget.fftStream ?? _fallbackStream,
            isPlaying: widget.isPlaying,
            glowColor: widget.glowColor,
            albumId: widget.albumId,
            trackId: widget.trackId,
          ),
        );
      case VisualizerStyle.minimalist:
        return MinimalistVisualizer(
          albumId: widget.albumId,
          size: widget.size,
          glowColor: widget.glowColor,
        );
      case VisualizerStyle.animationTest:
        return AnimationTestVisualizer(
          albumId: widget.albumId,
          trackId: widget.trackId,
          size: widget.size,
          isPlaying: widget.isPlaying,
          fftStream: widget.fftStream,
          glowColor: const Color(0xFFFFB000),
        );
    }
  }
}
