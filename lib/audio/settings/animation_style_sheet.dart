import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../visualizers/animation_style.dart';
import '../../visualizers/radial/radial_style_preview.dart';
import '../audio_provider.dart';

class AnimationStyleSheet extends StatelessWidget {
  final AudioProvider audio;

  const AnimationStyleSheet({super.key, required this.audio});

  @override
  Widget build(BuildContext context) {
    // El bottom sheet se abre con `isScrollControlled: true`. Sin este scroll
    // las 9 animaciones desbordaban la pantalla y las últimas no se podían
    // tocar (era el motivo por el que "no permitía interactuar").
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: AppTheme.outline,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Text('Animaciones',
                style: TextStyle(
                    color: AppTheme.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            ...VisualizerStyle.values.map((style) {
              final selected = style == audio.animationStyle;
              final isDefault = style == VisualizerStyle.vinyl;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                minLeadingWidth: 34,
                leading: style.radialVariant == null
                    ? Text(style.iconLabel,
                        style: const TextStyle(fontSize: 22))
                    : RadialStylePreview(variant: style.radialVariant!),
                title: Text(
                  '${style.displayName}${isDefault ? ' (Por defecto)' : ''}',
                  style: TextStyle(
                    color: selected ? AppTheme.primary : AppTheme.onSurface,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                subtitle: style.description.isEmpty
                    ? null
                    : Text(style.description,
                        style: const TextStyle(
                            color: AppTheme.onSurfaceVariant, fontSize: 11)),
                trailing: selected
                    ? const Icon(Icons.check_rounded,
                        color: AppTheme.primary, size: 22)
                    : null,
                onTap: () {
                  audio.animationStyle = style;
                  Navigator.of(context).pop();
                },
              );
            }),
            const SizedBox(height: 8),
            const Text(
                'Los cambios se aplican al instante en el reproductor.',
                style: TextStyle(
                    color: AppTheme.onSurfaceVariant, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
