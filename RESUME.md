# RESUME — ACARMusic

> **Propósito:** este archivo permite que otra sesión (con cualquier modelo de IA)
> recupere el contexto completo del proyecto sin depender del historial de chat.
> **Regla obligatoria:** al final de CADA cambio se debe actualizar este archivo
> con la fecha del cambio y ejecutar, en orden:
>
> ```bash
> flutter clean
> flutter pub get
> flutter build apk --release
> ```
>
> El APK resultante queda en `build\app\outputs\flutter-apk\app-release.apk`.

---

## Entorno y datos fijos

- Proyecto: `C:\Users\Andres\Desktop\Desarrollo\app-music\ACARMusic\ACARMusic`
- Flutter / Dart instalados: Dart SDK 3.13.2 (Flutter reciente)
- Git: rama `CarvaNew`, dispositivo de prueba Samsung S20 FE
- Paquetes: `just_audio ^0.9.40`, `audio_service ^0.18.15`, `audio_session`,
  `on_audio_query ^2.9.0`, `provider`, `permission_handler`, `shared_preferences`,
  `google_fonts`, `palette_generator`
- Nota Windows: para que `flutter pub get` cree los symlinks de plugins hay que
  tener Developer Mode activo. Ya se habilitó con:
  `HKCU\Software\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense = 1`
  Aun así, el proceso sin privilegios de administrador no puede crear los
  symlinks de las plataformas de escritorio. **Solución aplicada:** desactivar
  esas plataformas (la app es Android-only):
  `flutter config --no-enable-windows-desktop --no-enable-linux-desktop`.
  Con eso `flutter clean` → `flutter pub get` → `flutter build apk --release`
  funciona de forma repetible sin elevación.
- Advertencias no bloqueantes del build: Gradle 8.14.0 / AGP 8.11.1 / Kotlin
  2.2.20 pronto sin soporte; `source/target 8` obsoletos; tree-shaking de iconos.

---

## Registro de cambios (fecha: 2026-11-20)

### 1. Análisis inicial del proyecto
Se analizó el código buscando errores de reproducción y animaciones. Hallazgos
principales: desincronización play/pause (doble camino provider/handler + filtro
global de `playerStateStream`), `_pendingSong` que perdía skips rápidos,
`wasPlaying` guardado pero no restaurado, debounce de guardado que nunca
disparaba, suscripciones sin cancelar, carrera en `VisualizerService`,
`WidgetsBindingObserver` duplicados, fuga de búsqueda entre pantallas y switch
de tema inactivo. `flutter analyze` inicial: 25 avisos.

### 2. Correcciones (4 fases)

**Fase 1 — Audio (`lib/audio/audio_provider.dart`)**
- `playerStateStream` es la única fuente de verdad de `_isPlaying`; ya no se
  filtran eventos durante play/pause.
- Skips rápidos acumulados como pasos relativos y reprocesados en orden.
- `repeat.one` con `LoopMode.one` + guard de reentrada.
- Restauración de sesión con `try/catch`, flag anti-race, casts seguros y
  **se restaura `wasPlaying`**.
- Guardado de posición por **throttle** de 700 ms (antes debounce, nunca disparaba).
- `seekTo`/`skipPrevious` usan `_player.duration`/`_player.position` reales.
- `_countdownTimer` del temporizador de sueño se cancela al disparar.
- Suscripciones canceladas en `dispose`; eliminado logging de diagnóstico.
- `playSong` valida índice y archivo antes de mutar estado.
- Reintento del FFT al pasar a `processingState.ready`.

**Fase 2 — Animaciones**
- `VisualizerService`: `start/stop` serializados con token de generación; sin
  datos simulados (si falla el FFT nativo emite silencio); `dispose` con catch
  asíncrono; `_silenceFrame` cacheado; timers detenidos sin suscriptores.
- `RadialVisualizer`: `AnimationController` en vez de `Timer.periodic` 33 ms
  (respeta `TickerMode`); niveles con `shouldRepaint` comparativo.
- `BarVisualizer`: mismo criterio de repaint; `isPlaying` propagado;cancel
  de suscripciones con `unawaited`.
- `TickerMode` en `app.dart` es el único control de ciclo de vida (se eliminaron
  los `WidgetsBindingObserver` de vinilo y player y el guard que congelaba el disco).
- `vinyl`/`minimalist` ya no arrancan FFT sin consumidor.

**Fase 3 — UI / estado**
- Búsqueda local de Explore (`library.searchResults`); ya no filtra Biblioteca.
- Switch de tema funcional: `lib/theme/theme_provider.dart` + `AppTheme.lightTheme`.
- `PopScope` global (incluido landscape); MiniPlayer unificado (overlay en Home y
  `SongListScreen`); Slider con `onChangeEnd`.
- Permisos centralizados en `main.dart`; `PermissionScreen` en español con
  `openAppSettings()` para denegación permanente.
- Eliminados `playlist_detail_screen.dart` y el shim `getSongsFromPlaylist`.
- Persistencia defensiva por clave, `mostPlayed` cacheado,_columnas de carpetas
  por ruta completa, orden "Recién añadidas" real, `notifyListeners` en
  `incrementPlayCount`.

**Fase 4 — Calidad**
- `flutter analyze` → **No issues found** (antes 25).
- `flutter test` → 7 tests (`test/acar_music_test.dart`).
- `DOCUMENTATION.md` actualizado (Parte 6 con arquitectura real y correcciones).

### 3. Generación de APK
Ejecutados `flutter clean`, `flutter pub get`, `flutter build apk --release`.
APK: `build\app\outputs\flutter-apk\app-release.apk` (~60 MB).
Flutter migró `android/gradle.properties` (`android.builtInKotlin=false`,
`android.newDsl=false`) y `pub get` actualizó `pubspec.lock`: se conservaron
ambos porque son necesarios para compilar.

### 4. Animación "animation test" — nombre
Se añadió `VisualizerStyle.animationTest` con `displayName: 'animation test'`,
icono `✨`, y un placeholder inicial (`AnimationTestVisualizer`). Aparece en el
selector de animaciones. Test actualizado. APK regenerado.

### 5. Animación "animation test" completa + arreglo FFT
**Animación completa** (`animation_test_visualizer.dart`): escena POV nocturna,
monitor ultrawide con borde ámbar, teclado RGB, planeta gris, reloj, barra de
tareas, letras secuenciales, espectro radial dorado con FFT real, paneo/zoom de
cámara y marca de agua final. Un solo `AnimationController` de 14 s en loop.

**Arreglo FFT (las barras no seguían la música):**
- Causa raíz: se había quitado `Permission.microphone` en_runtime; sin RECORD_AUDIO
  el `android.media.audiofx.Visualizer` fallaba y Dart usaba datos aleatorios
  simulados. Se restauró el permiso (no se graba audio) y se borró el generador
  falso: ahora emite silencio si el nativo falla.
- `VisualizerPlugin.kt`: mapeo **logarítmico 40 Hz → 16 kHz** con el
  `samplingRate` real, descarta bin DC, AGC con decaimiento `0.995` y piso 48,
  curva perceptiva `pow(0.78)`.
- `BarVisualizer`/`RadialVisualizer` consumen las 64 bandas 1:1 (antes doblaban
  la curva logarítmica).
- Verificación: analyze limpio, 7 tests, APK ~60,2 MB.

### 6. Espectro radial sincronizado y distinto por pista (2026-11-20)
El usuario reportó que el radial parecía una animación fija e igual para todas
las pistas. Causas reales encontradas y corregidas:
- Se usaban solo 33 bandas (mitad derecha) espejadas y se volvía a aplicar una
  curva logarítmica sobre el FFT nativo de 64 bandas. Ahora se usan las 64
  bandas 1:1 alrededor del círculo (remuestreo lineal solo si el nativo entrega
  otro tamaño). Se eliminó la longitud mínima constante que dibujaba un aro
  fijo aunque no hubiera audio.
- `RadialBeatDetector` (nuevo `lib/visualizers/radial/radial_audio.dart`):
  detecta golpes de graves contra una media móvil (umbral 1,22 / mín 0,10 /
  150 ms de refractario) y produce un pulso con decaimiento exponencial que
  expande barras, ilumina el anillo interior y sube el brillo. Picos retenidos
  por barra con caída lenta. Sin datos inventados.
- Paleta y rotación derivadas de `glowColor` + `trackId` (respaldo `albumId`),
  propagados desde `VisualizerFactory` y `PlayerScreen` → cada pista se ve
  distinta. `shouldRepaint` compara también picos, pulso y paleta.
- Tests nuevos en `test/acar_music_test.dart`: 10 tests en verde.
  `flutter analyze --no-pub` → No issues found.
- Verificación completa: `flutter clean` → `flutter pub get` →
  `flutter build apk --release` → **APK 60,2 MB** en
  `build\app\outputs\flutter-apk\app-release.apk`. Solo advertencias
  no bloqueantes de Gradle/Kotlin/Java 8 ya conocidas.

### 7. Cinco estilos radiales, carátula y fix de cambio de pista (2026-11-20)
El usuario pidió 5 estilos de la misma animación, numerados, con la imagen de
la pista y arreglar el "controlador" que se quedaba con una pista fija.
- `VisualizerStyle` ahora tiene `radialBars`, `radialWave`, `radialPetals`,
  `radialDual`, `radialDots` → nombres `Espectro radial 1..5` con descripción.
  Selector con miniaturas reales de cada estilo (`RadialStylePreview`).
  Migración de `radialVisualizer` guardado → `radialBars`.
- `RadialVariant` en `_RadialPainter`: barras, onda cerrada con relleno,
  pétalos, doble anillo (graves/agudos) y constelación de neón. Todos comparten
  FFT real, beats, picos y paleta por pista.
- Carátula de la pista en el centro del radial (`QueryArtworkWidget` con clave
  por id de pista/álbum).
- Fix "pista fija": `ValueKey('visualizer-${song.id}')` en `VisualizerFactory`
  (retrato y horizontal), guard de `_lastSongId` en `_extractPalette`/`_fallback`
  y claves por id en las carátulas de miniplayer, cola y animation test.
- `usesFft` centraliza qué estilos arrancan el nativo.
- Tests: 11 en verde. `flutter analyze --no-pub`: No issues found.
- `flutter clean` → `flutter pub get` → `flutter build apk --release`:
  **APK 60,4 MB** en `build\app\outputs\flutter-apk\app-release.apk`.

### 8. Correcciones de pistas, menú de animaciones y FFT (2026-11-21)

El usuario reportó (con capturas) cuatro problemas: la pista resaltada no
coincidía con el mini reproductor, el menú de animaciones no respondía, las
animaciones no seguían la música y las pistas se veían grandes/toscas.

**Pista seleccionada/reproducida desactualizada**
- Causa: `MiniPlayer` usaba `context.read<AudioProvider>()` (no suscribe) y el
  padre lo envolvía en un hijo `const`; Flutter omite `updateChild` cuando el
  widget es la misma instancia canónica, así que el mini reproductor se
  congelaba con la PRIMERA pista reproducida mientras la lista sí resaltaba la
  nueva.
- Fix: `MiniPlayer` usa `context.select((a) => a.currentSong)`, que suscribe
  de verdad, y los `Selector` que lo envolvían se simplificaron a un
  `Positioned` const (el propio mini player se muestra/oculta y se actualiza).
  Se conservan las claves por id en la carátula.

**Menú de animaciones**
- Causa: el bottom sheet era una `Column` sin scroll y sin `isScrollControlled`;
  con 9 estilos el contenido desbordaba y los radiales 3-5 eran inalcanzables.
  Además se cerraba una hoja y se abría otra en el mismo tap, y el gesto
  descartaba la nueva.
- Fix: `AnimationStyleSheet` usa `SafeArea` + `SingleChildScrollView` con
  `minLeadingWidth`y filas `dense`; `_showAnimationStyleSheet` abre con
  `isScrollControlled: true` y `maxHeight = 90%` de la pantalla. Nuevo helper
  `_closeSheetAndThen` en el reproductor: cierra la hoja y abre la siguiente en
  el frame posterior (aplicado a Animaciones, Ecualizador, Sueño y Ajustes).

**Animaciones acordes a la música**
- `VisualizerService.start` ya no sobrescribe `_playbackActive` (lo decide
  `_manageVisualizer` según `isPlaying`) y añade `restart()` ("force") para
  reenganchar el FFT tras cada cambio de pista, aunque just_audio reutilice el
  mismo id de sesión. `playSong` llama a `_manageVisualizer(force: true)`.
- `AudioProvider` se suscribe a `audioSessionIdStream`: cuando just_audio crea
  un id de sesión nuevo al cargar la pista, se fuerza el reenganche del FFT
  (antes el visualizador podía quedar en la sesión anterior).
- Kotlin `VisualizerPlugin`: si la sesión del reproductor falla (DSP Samsung),
  prueba la mezcla global (id 0); tasa de captura 50 Hz; libera el visualizador
  fallido; mantiene AGC lento y mapeo logarítmico 40 Hz-16 kHz.
- Verificación: `flutter analyze --no-pub` → No issues found; `flutter test`
  → 11 tests en verde. APK release regenerado.

**Tamaño de pistas**
- `TrackTile`: portada 64→48 px, padding 10→5 px, títulos 17→14 y 14→11 px,
  separadores alpha 42→18, iconos más pequeños. `_tileHeight` 86→60 en
  Biblioteca y 72→60 en listas (coincide con la altura real del tile).

### 9. Segunda ronda: bug de cambio de pista, centrado y FFT real (2026-11-21)

El usuario reportó que las animaciones seguían sin acorde a la pista, que las
pistas estaban "muy mal centradas" y que no se podía cambiar de pista hasta
tocar pausa/reproducir. Se usaron tres subagentes en paralelo (investigación)
y se supervisaron y aplicaron las correcciones.

**Bug de reproducción (causa raíz)**
- just_audio 0.9.46 devuelve en `play()` un Future que **solo se completa al
  pausar/parar/terminar** la pista (ver test oficial `control` del paquete).
  `await _player.play()` dentro de `playSong` dejaba `_changingTrack = true`
  para siempre: los `skipNext/skipPrevious` se encolaban en `_pendingSkipSteps`
  y solo se aplicaban al pulsar pausa (que completaba el Future).
- Fix: helper `_requestPlay()` (fire-and-forget con `catchError`) usado en
  `playSong`, `togglePlayPause`, `_restoreSessionIfPossible` y
  `AudioHandler.play()`. Además un watchdog de 12 s libera el guard si una
  carga `setFilePath` se cuelga (`_releaseTrackChangeGuard()`).
- No se cambió `setFilePath`: con preload ya cambia el audio mientras suena.

**Centrado de pistas**
- Causa: un `ListTile` de DOS líneas mide **72 px** mínimo (no 48). Con
  `contentPadding` 5+5 y borde 1+1, `TrackTile` medía **84 px**, pero las
  listas lo forzaban a 60 con `itemExtent`: el contenido se posicionaba para
  72 y se desbordaba 12 px hacia abajo (separadores desalineados).
- Fix: `TrackTile` ya no usa `ListTile`; es un `AnimatedContainer` de altura
  fija `TrackTile.height = 60` con `InkWell > Row(CrossAxisAlignment.center)`.
  Carátula y bloque de texto quedan exactamente centrados en y=30. Biblioteca
  y listas usan `TrackTile.height` como `itemExtent`.
- `_scrollToLetter` de `SongListScreen` ya no suma `_kHeaderInfoHeight` (40 px),
  que desplazaba la canción respecto al sidebar alfabético.

**FFT REAL cuando el DSP bloquea el Visualizer**
- Nuevo `OfflineFftPlugin.kt` (`com.acar.music/offline_fft`): descodifica el
  archivo con `MediaExtractor + MediaCodec` a mono 22 050 Hz, calcula FFT
  radix-2 de 1024 con hop 512 (43 fps), mapea 64 bandas logarítmicas
  40 Hz-10,5 kHz y normaliza por percentil 95. Caché de una pista, trabajo en
  un hilo con token de cancelación; `getFrameAt(positionMs)` es O(1).
  Registrado en `MainActivity` (creación + `destroy()`).
- `VisualizerService`: watchdog de 12 frames a cero con reproducción activa
  (~0,4 s) conmuta del nativo al FFT offline; `positionMsProvider` apunta a
  `_player.position` para que la posición absoluta evite desfase en seeks;
  `setPlaybackActive` gestiona el timer de 33 ms; `preferredSource` permite
  forzar nativo/offline. Nunca se generan datos simulados.
- `AudioProvider` pasa `filePath` al servicio y conecta la posición del
  reproductor; se limpia en `dispose`.
- Verificación: `flutter analyze --no-pub` → No issues found;
  `flutter test` → 11 tests en verde; `flutter build apk --release` → APK
  60,5 MB. Nota: la descodificación inicial tarda ~2-5 s en segundo plano;
  mientras tanto el visualizador emite silencio (datos reales solo).

---

## Estado actual / pendientes conocidos

- El `Visualizer` nativo sigue siendo la primera opción; si el DSP lo bloquea
  se usa automáticamente el FFT offline del archivo (sección 9). Queda validar
  en el Samsung S20 FE que el `MediaCodec` descodifica todos los formatos del
  usuario; si alguno falla, ese visualizador emite silencio (nunca datos
  falsos) y se podría ampliar con otro descodificador.
- Ecualizador real y "Ajustes desde el reproductor" siguen siendo placeholders.
- Las letras de "animation test" son frases genéricas originales (no lyrics
  reales); para letras sincronizadas haría falta un `LyricsProvider` con `.lrc`.
- `analysis_options.yaml` y `android/gradle.properties` están modificados
  (el primero ya venía así; el segundo lo migró Flutter automáticamente).

---

## Checklist para la próxima sesión

1. Leer este archivo y `DOCUMENTATION.md` (Parte 6).
2. Hacer el cambio solicitado.
3. `flutter analyze --no-pub` → debe dar **No issues found**.
4. `flutter test` → deben pasar todos los tests.
5. Actualizar este `RESUME.md` con fecha y lo hecho.
6. Ejecutar en orden: `flutter clean` → `flutter pub get` → `flutter build apk --release`.
7. Reportar la ruta y tamaño del APK.
