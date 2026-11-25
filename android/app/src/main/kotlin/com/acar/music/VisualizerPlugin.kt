package com.acar.music

import android.media.audiofx.Visualizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

class VisualizerPlugin(
    private val activity: WeakReference<MainActivity>,
    private val flutterEngine: FlutterEngine
) {
    private var visualizer: Visualizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var listener: Visualizer.OnDataCaptureListener? = null
    private val CHANNEL = "com.acar.music/visualizer"
    private val FFT_CHANNEL = "com.acar.music/visualizer_fft"
    private val fftBuffer = FloatArray(64)
    private var sampleRate = 48000
    // Referencia de amplitud con decaimiento lento: evita que los pasajes
    // silenciosos se amplifiquen hasta llenar las barras (AGC agresivo).
    private var peakRef = 64.0

    private val methodChannel: MethodChannel
    private val eventChannel: EventChannel

    init {
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        ).apply {
            setMethodCallHandler { call, result -> handleMethodCall(call, result) }
        }
        eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, FFT_CHANNEL
        ).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startVisualizer" -> {
                val sessionId = call.argument<Int>("audioSessionId") ?: 0
                val ok = startVisualizer(sessionId)
                result.success(ok) // false = Dart usa el FFT offline del archivo
            }
            "stopVisualizer" -> {
                stopVisualizer()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // SOLO la sesión del reproductor. Antes, si el DSP del dispositivo bloqueaba
    // la captura, se caía a Visualizer(0) (mezcla global): eso captura notifications,
    // otras apps o ruido, y devolvía true, así que Dart nunca conmutaba al FFT del
    // archivo. El radial "se movía" pero NO seguía la pista. Session 0 => false
    // para que VisualizerService use directamente el FFT offline de esa pista.
    private fun startVisualizer(sessionId: Int): Boolean {
        stopVisualizer()
        peakRef = 64.0
        if (sessionId == 0) return false
        var viz: Visualizer? = null
        try {
            viz = Visualizer(sessionId)
            viz.enabled = false
            val captureSize = Visualizer.getCaptureSizeRange()[1].coerceAtMost(512)
            viz.setCaptureSize(captureSize)

            listener = object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(v: Visualizer?, w: ByteArray?, s: Int) {}
                override fun onFftDataCapture(v: Visualizer?, fft: ByteArray?, s: Int) {
                    // Un visualizador liberado puede seguir entregando frames:
                    // nunca mezclar la pista anterior con la nueva.
                    if (v !== visualizer || eventSink == null) return
                    if (s > 0) sampleRate = s
                    processFft(fft)
                }
            }

            // 50 Hz: suficiente para seguir el ritmo sin saturar la CPU.
            val captureRate = Visualizer.getMaxCaptureRate().coerceAtMost(50000)
            viz.setDataCaptureListener(listener, captureRate, false, true)
            viz.enabled = true
            visualizer = viz
            return true
        } catch (e: Exception) {
            listener = null
            try { viz?.release() } catch (_: Exception) {}
            return false
        }
    }

    private fun processFft(fft: ByteArray?) {
        if (fft == null || eventSink == null) return
        val sourceBins = fft.size / 2
        val n = minOf(sourceBins, fftBuffer.size)
        // El bin 0 es DC; se empieza en 1 para que no sature las barras graves.
        val mags = DoubleArray(sourceBins)
        var frameMax = 0.0
        for (i in 1 until sourceBins) {
            val real = fft[i * 2].toDouble()
            val imag = fft[i * 2 + 1].toDouble()
            val magnitude = sqrt(real * real + imag * imag)
            mags[i] = magnitude
            if (magnitude > frameMax) frameMax = magnitude
        }
        if (frameMax < 1.6) {
            peakRef = max(24.0, peakRef * 0.98)
            java.util.Arrays.fill(fftBuffer, 0f)
            eventSink?.success(fftBuffer.toList().subList(0, n))
            return
        }

        // Referencia estable: sube rápido y baja muy despacio. Así el nivel de
        // cada barra representa la energía real de esa banda en ese instante.
        peakRef = max(frameMax, peakRef * 0.995)
        val gainRef = max(48.0, peakRef)

        // Mapeo logarítmico de frecuencias (40 Hz → 16 kHz). El mapeo lineal
        // anterior dejaba casi toda la música en las 10 primeras barras y el
        // resto quieto, que era la causa de que "no fuera acorde al audio".
        val hzPerBin = (sampleRate / 2.0) / sourceBins
        val minHz = 40.0
        val maxHz = minOf(16000.0, sampleRate / 2.0)
        val ratio = maxHz / minHz

        for (i in 0 until n) {
            val f0 = minHz * ratio.pow(i.toDouble() / n)
            val f1 = minHz * ratio.pow((i + 1).toDouble() / n)
            val start = min(sourceBins - 1, max(1, (f0 / hzPerBin).toInt()))
            val end = min(sourceBins, max(start + 1, (f1 / hzPerBin).toInt()))
            var peak = 0.0
            var sum = 0.0
            for (j in start until end) {
                peak = maxOf(peak, mags[j])
                sum += mags[j]
            }
            val avg = sum / (end - start)
            val energy = (peak * 0.65 + avg * 0.35) / gainRef
            // Curva perceptual: realza variaciones suaves sin saturar.
            fftBuffer[i] = energy.pow(0.78).toFloat().coerceIn(0f, 1f)
        }
        eventSink?.success(fftBuffer.toList().subList(0, n))
    }

    private fun stopVisualizer() {
        val old = visualizer
        visualizer = null
        listener = null
        try {
            old?.apply { enabled = false; release() }
        } catch (_: Exception) {}
    }

    fun destroy() {
        stopVisualizer()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }
}
