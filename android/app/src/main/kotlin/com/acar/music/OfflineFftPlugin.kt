package com.acar.music

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Espectro REAL calculado desde el archivo de audio, sin depender de
 * android.media.audiofx.Visualizer (bloqueado por el DSP en algunos Samsung).
 * La posición de reproducción de just_audio indexa los frames, así que un
 * seek o un reinicio se reflejan automáticamente, sin acumular desfase.
 */
class OfflineFftPlugin(flutterEngine: FlutterEngine) {
    companion object {
        const val CHANNEL = "com.acar.music/offline_fft"
        const val TARGET_RATE = 22050
        const val FFT_SIZE = 1024
        const val HOP = 512
        const val BANDS = 64
        const val MIN_HZ = 40.0
        const val MAX_HZ = 10500.0
        const val MAX_PCM_SAMPLES = 40 * 1024 * 1024
    }

    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "acar-offline-fft").apply { priority = Thread.NORM_PRIORITY - 1 }
    }
    private val main = Handler(Looper.getMainLooper())
    private val jobId = AtomicInteger(0)

    private data class Analysis(
        val path: String,
        val frameRate: Double,
        val frameCount: Int,
        val bands: FloatArray,
    )

    @Volatile
    private var cache: Analysis? = null

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> onCall(call, result) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("BAD_PATH", "Ruta vacía", null)
                    return
                }
                cache?.let {
                    if (it.path == path) {
                        result.success(meta(it))
                        return
                    }
                }
                val id = jobId.incrementAndGet()
                worker.execute {
                    try {
                        val analysis = analyze(path, id)
                        if (id != jobId.get()) {
                            // Otra pista ganó la carrera. ANTES no se respondía:
                            // el `await` de Dart se colgaba para siempre y
                            // `_offlineSwitching` quedaba en true, matando el
                            // FFT offline durante el resto de la sesión.
                            main.post {
                                result.error("CANCELLED", "Pista cambiada", null)
                            }
                            return@execute
                        }
                        cache = analysis
                        main.post { result.success(meta(analysis)) }
                    } catch (_: Cancelled) {
                        main.post { result.error("CANCELLED", "Pista cambiada", null) }
                    } catch (e: Exception) {
                        val code = if (id == jobId.get()) "DECODE_ERROR" else "CANCELLED"
                        main.post { result.error(code, e.message, null) }
                    }
                }
            }
            "getFrameAt" -> {
                val a = cache
                if (a == null) {
                    result.error("NOT_READY", "Llama a prepare antes", null)
                    return
                }
                val ms = call.argument<Int>("positionMs") ?: 0
                val idx = ((ms / 1000.0) * a.frameRate).roundToInt()
                    .coerceIn(0, a.frameCount - 1)
                val base = idx * BANDS
                val out = ArrayList<Double>(BANDS)
                for (i in 0 until BANDS) out.add(a.bands[base + i].toDouble())
                result.success(out)
            }
            "release" -> {
                jobId.incrementAndGet()
                cache = null
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun meta(a: Analysis) = mapOf(
        "frameCount" to a.frameCount,
        "frameRate" to a.frameRate,
        "sampleRate" to TARGET_RATE,
        "bands" to BANDS,
    )

    private class Cancelled : Exception()

    private fun analyze(path: String, id: Int): Analysis {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull { i ->
                extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("Sin pista de audio")

            val fmt = extractor.getTrackFormat(track)
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            extractor.selectTrack(track)

            var srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = max(1, fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT))

            fmt.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(fmt, null, null, 0)
            codec.start()

            val mono = GrowableShorts()
            val info = MediaCodec.BufferInfo()
            var inputEos = false
            var outputEos = false
            val timeout = 10_000L

            while (!outputEos) {
                if (id != jobId.get()) throw Cancelled()

                if (!inputEos) {
                    val i = codec.dequeueInputBuffer(timeout)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i) ?: break
                        buf.clear()
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(
                                i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputEos = true
                        } else {
                            codec.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                when (val o = codec.dequeueOutputBuffer(info, timeout)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val of = codec.outputFormat
                        srcRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    }
                    MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                    else -> if (o >= 0) {
                        val nShort = info.size / 2
                        if (nShort > 0) {
                            val buf = codec.getOutputBuffer(o) ?: break
                            buf.order(ByteOrder.LITTLE_ENDIAN)
                            val raw = ShortArray(nShort)
                            buf.asShortBuffer().get(raw)
                            val down = downmix(raw, nShort, channels)
                            mono.addAll(down, down.size)
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputEos = true
                        }
                    }
                }

                if (mono.size > MAX_PCM_SAMPLES) {
                    throw IllegalStateException("Pista demasiado larga")
                }
            }

            val pcm = resample(mono.toArray(), srcRate, TARGET_RATE)
            return buildFrames(path, pcm, id)
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }

    private fun downmix(raw: ShortArray, count: Int, channels: Int): ShortArray {
        val frames = count / channels
        val out = ShortArray(frames)
        for (f in 0 until frames) {
            var acc = 0
            for (c in 0 until channels) acc += raw[f * channels + c].toInt()
            out[f] = (acc / channels).coerceIn(-32768, 32767).toShort()
        }
        return out
    }

    private fun resample(src: ShortArray, from: Int, to: Int): ShortArray {
        if (from == to || src.isEmpty()) return src
        val ratio = to.toDouble() / from.toDouble()
        val outSize = max(1, (src.size * ratio).toInt())
        val out = ShortArray(outSize)
        for (i in 0 until outSize) {
            val pos = i / ratio
            val low = pos.toInt()
            val high = min(low + 1, src.size - 1)
            val t = (pos - low).toFloat()
            val v = src[low].toFloat() * (1f - t) + src[high].toFloat() * t
            out[i] = v.coerceIn(-32768f, 32767f).toInt().toShort()
        }
        return out
    }

    private fun buildFrames(path: String, pcm: ShortArray, id: Int): Analysis {
        val frameCount = max(1, (pcm.size - FFT_SIZE) / HOP + 1)
        val bands = FloatArray(frameCount * BANDS)
        val window = FloatArray(FFT_SIZE) { i ->
            (0.5 - 0.5 * cos(2.0 * PI * i / (FFT_SIZE - 1))).toFloat()
        }
        val fft = Fft1024()
        val re = FloatArray(FFT_SIZE)
        val im = FloatArray(FFT_SIZE)

        for (f in 0 until frameCount) {
            if (f % 128 == 0 && id != jobId.get()) throw Cancelled()
            val start = f * HOP
            for (i in 0 until FFT_SIZE) {
                val idx = start + i
                val s = if (idx < pcm.size) pcm[idx].toInt() else 0
                re[i] = s * window[i] / 32768f
                im[i] = 0f
            }
            fft.transform(re, im)

            val hzPerBin = TARGET_RATE.toDouble() / FFT_SIZE
            val ratio = MAX_HZ / MIN_HZ
            val mags = DoubleArray(FFT_SIZE / 2)
            for (k in 1 until mags.size) {
                mags[k] = sqrt(re[k].toDouble() * re[k] + im[k].toDouble() * im[k])
            }
            var base = f * BANDS
            for (b in 0 until BANDS) {
                val f0 = MIN_HZ * ratio.pow(b.toDouble() / BANDS)
                val f1 = MIN_HZ * ratio.pow((b + 1).toDouble() / BANDS)
                val from = max(1, (f0 / hzPerBin).toInt())
                val to = min(mags.size, max(from + 1, (f1 / hzPerBin).toInt()))
                var peak = 0.0
                var sum = 0.0
                for (k in from until to) {
                    peak = maxOf(peak, mags[k])
                    sum += mags[k]
                }
                bands[base + b] = (peak * 0.65 + (sum / (to - from)) * 0.35).toFloat()
            }
        }

        // Normalización global por percentil 95: estable entre pasajes, sin
        // bombeo. El silencio real sigue siendo cero.
        val sorted = bands.copyOf()
        sorted.sort()
        val ref = max(1e-6f, sorted[(sorted.size * 0.95).toInt()])
        for (i in bands.indices) {
            val v = (bands[i] / ref).pow(0.78f).coerceIn(0f, 1f)
            bands[i] = if (v < 0.01f) 0f else v
        }

        return Analysis(path, TARGET_RATE.toDouble() / HOP, frameCount, bands)
    }

    fun destroy() {
        jobId.incrementAndGet()
        worker.shutdownNow()
        cache = null
    }

    private class GrowableShorts {
        private var data = ShortArray(1 shl 16)
        var size: Int = 0
            private set

        fun addAll(src: ShortArray, n: Int) {
            if (size + n > data.size) {
                data = data.copyOf(maxOf(size + n, data.size * 2))
            }
            System.arraycopy(src, 0, data, size, n)
            size += n
        }

        fun toArray(): ShortArray = data.copyOf(size)
    }

    private class Fft1024 {
        private val n = FFT_SIZE
        private val rev = IntArray(n)
        private val cosT = FloatArray(n / 2)
        private val sinT = FloatArray(n / 2)

        init {
            for (i in 0 until n) {
                var x = i
                var r = 0
                repeat(10) {
                    r = (r shl 1) or (x and 1)
                    x = x shr 1
                }
                rev[i] = r
            }
            for (i in 0 until n / 2) {
                cosT[i] = cos(-2.0 * PI * i / n).toFloat()
                sinT[i] = sin(-2.0 * PI * i / n).toFloat()
            }
        }

        fun transform(re: FloatArray, im: FloatArray) {
            for (i in 0 until n) {
                val j = rev[i]
                if (j > i) {
                    val tr = re[i]; re[i] = re[j]; re[j] = tr
                    val ti = im[i]; im[i] = im[j]; im[j] = ti
                }
            }
            var len = 2
            while (len <= n) {
                val half = len / 2
                val step = n / len
                for (i in 0 until n step len) {
                    for (j in 0 until half) {
                        val c = cosT[j * step]
                        val s = sinT[j * step]
                        val k = i + j
                        val l = k + half
                        val tre = re[l] * c - im[l] * s
                        val tim = re[l] * s + im[l] * c
                        re[l] = re[k] - tre
                        im[l] = im[k] - tim
                        re[k] += tre
                        im[k] += tim
                    }
                }
                len *= 2
            }
        }
    }
}
