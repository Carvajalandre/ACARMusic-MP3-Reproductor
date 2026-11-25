import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';

class TrackTile extends StatefulWidget {
  /// Única fuente de verdad de la altura de fila. Debe coincidir con el
  /// `itemExtent` de las listas que la usan.
  static const double height = 60.0;

  final SongModel song;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final Widget? trailingOverride;

  const TrackTile(
      {super.key,
      required this.song,
      required this.isPlaying,
      required this.onTap,
      this.onMore,
      this.trailingOverride});

  @override
  State<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<TrackTile> {
  Color _accent = AppTheme.primary;
  int? _lastSongId;

  @override
  Widget build(BuildContext context) {
    if (!widget.isPlaying) {
      _lastSongId = null;
    } else if (_lastSongId != widget.song.id) {
      _lastSongId = widget.song.id;
      _loadAccent(widget.song);
    }
    final activeColor = _accentForText(_accent);
    // Un ListTile de DOS líneas mide 72px como mínimo, no 48: al forzarlo a
    // 60 con itemExtent el contenido se calculaba para 72 y se desbordaba
    // hacia abajo (pistas "mal centradas"). Un Row de altura fija con
    // CrossAxisAlignment.center centra carátula y texto de forma exacta.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      height: TrackTile.height,
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: widget.isPlaying
            ? _accent.withAlpha(34)
            : AppTheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: Colors.white.withAlpha(18)),
          bottom: BorderSide(color: Colors.white.withAlpha(18)),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: RepaintBoundary(
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: QueryArtworkWidget(
                            id: widget.song.id,
                            type: ArtworkType.AUDIO,
                            artworkBorder: BorderRadius.circular(9),
                            artworkFit: BoxFit.cover,
                            artworkWidth: 48,
                            artworkHeight: 48,
                            keepOldArtwork: true,
                            nullArtworkWidget: Container(
                              color: AppTheme.surfaceContainerHigh,
                              child: const Icon(Icons.music_note_rounded,
                                  color: AppTheme.onSurfaceVariant, size: 20),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.isPlaying)
                      Container(
                        decoration: BoxDecoration(
                            color: _accent.withAlpha(150),
                            borderRadius: BorderRadius.circular(9)),
                        child: const Center(
                            child: Icon(Icons.equalizer_rounded,
                                color: Colors.white, size: 17)),
                      ),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.manrope(
                              color: widget.isPlaying
                                  ? activeColor
                                  : AppTheme.onSurface,
                              fontSize: 14,
                              height: 1.2,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(widget.song.artist ?? 'Artista desconocido',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.manrope(
                              color: widget.isPlaying
                                  ? activeColor.withAlpha(190)
                                  : AppTheme.onSurfaceVariant,
                              fontSize: 11,
                              height: 1.2)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                widget.trailingOverride ??
                    IconButton(
                        icon: const Icon(Icons.more_horiz_rounded,
                            color: AppTheme.onSurfaceVariant, size: 20),
                        onPressed: widget.onMore),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadAccent(SongModel song) async {
    try {
      final art = await OnAudioQuery().queryArtwork(song.id, ArtworkType.AUDIO,
          format: ArtworkFormat.JPEG, size: 120);
      var result = _fallbackColor(song);
      if (art != null && art.isNotEmpty) {
        final palette = await PaletteGenerator.fromImageProvider(
            MemoryImage(art),
            size: const Size(120, 120),
            maximumColorCount: 8);
        result = palette.vibrantColor?.color ??
            palette.dominantColor?.color ??
            result;
      }
      if (mounted && _lastSongId == song.id) setState(() => _accent = result);
    } catch (_) {
      if (mounted && _lastSongId == song.id) {
        setState(() => _accent = _fallbackColor(song));
      }
    }
  }

  Color _fallbackColor(SongModel song) {
    final hue = ((song.albumId ?? song.id) * 47) % 360;
    return HSLColor.fromAHSL(1, hue.toDouble(), 0.68, 0.48).toColor();
  }

  Color _accentForText(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl.lightness < 0.62 ? hsl.withLightness(0.72).toColor() : color;
  }
}
