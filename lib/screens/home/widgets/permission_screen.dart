import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_theme.dart';
import '../../../library/library_provider.dart';

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _permanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final status = await Permission.audio.status;
    if (!mounted) return;
    setState(() => _permanentlyDenied = status.isPermanentlyDenied);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  color: AppTheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.audio_file_rounded,
                  size: 64,
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Acceso a tu biblioteca musical',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                  color: AppTheme.onSurface,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _permanentlyDenied
                    ? 'El permiso está denegado permanentemente. Ábrelo en Ajustes del sistema para continuar.'
                    : 'ACARMusic necesita permiso para leer los archivos de música de tu dispositivo y poder reproducirlos.',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                  color: AppTheme.onSurfaceVariant,
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () async {
                    if (_permanentlyDenied) {
                      await openAppSettings();
                      return;
                    }
                    await context
                        .read<LibraryProvider>()
                        .requestPermissionAndLoad();
                    if (mounted) await _checkStatus();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: AppTheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    _permanentlyDenied
                        ? 'Abrir ajustes del sistema'
                        : 'Conceder permiso',
                    style: GoogleFonts.manrope(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
