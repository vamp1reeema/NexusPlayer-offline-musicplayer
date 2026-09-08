package com.example.nexus_player

import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.media.audiofx.Virtualizer
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val channelName = "nexus_player/equalizer"

    private var equalizer: Equalizer? = null
    private var bassBoost: BassBoost? = null
    private var virtualizer: Virtualizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var sessionId: Int = 0
    private var eqEnabled: Boolean = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "attach" -> {
                            val id = call.argument<Int>("sessionId") ?: 0
                            attach(id)
                            result.success(bandInfo())
                        }
                        "setEnabled" -> {
                            eqEnabled = call.argument<Boolean>("enabled") ?: true
                            equalizer?.enabled = eqEnabled
                            result.success(null)
                        }
                        "getBands" -> result.success(bandInfo())
                        "setBand" -> {
                            val index = call.argument<Int>("index") ?: 0
                            val level = call.argument<Double>("level") ?: 0.0
                            // level in dB, Android uses millibels
                            equalizer?.setBandLevel(index.toShort(), (level * 100).toInt().toShort())
                            result.success(null)
                        }
                        "setPreset" -> {
                            val name = call.argument<String>("name") ?: "Flat"
                            applyPreset(name)
                            result.success(bandInfo())
                        }
                        "setBassBoost" -> {
                            val strength = call.argument<Int>("strength") ?: 0 // 0..1000
                            if (bassBoost == null && sessionId != 0) {
                                bassBoost = BassBoost(0, sessionId)
                            }
                            bassBoost?.enabled = strength > 0
                            bassBoost?.setStrength(strength.toShort())
                            result.success(null)
                        }
                        "setVirtualizer" -> {
                            val strength = call.argument<Int>("strength") ?: 0
                            if (virtualizer == null && sessionId != 0) {
                                virtualizer = Virtualizer(0, sessionId)
                            }
                            virtualizer?.enabled = strength > 0
                            virtualizer?.setStrength(strength.toShort())
                            result.success(null)
                        }
                        "setLoudness" -> {
                            val mB = call.argument<Int>("mB") ?: 0
                            if (loudnessEnhancer == null && sessionId != 0) {
                                loudnessEnhancer = LoudnessEnhancer(sessionId)
                            }
                            loudnessEnhancer?.enabled = mB > 0
                            loudnessEnhancer?.setTargetGain(mB)
                            result.success(null)
                        }
                        "release" -> {
                            releaseFx()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("EQ_ERROR", e.message, null)
                }
            }
    }

    private fun attach(id: Int) {
        if (id == 0) return
        if (id == sessionId && equalizer != null) return
        releaseFx()
        sessionId = id
        try {
            equalizer = Equalizer(0, sessionId).apply { enabled = eqEnabled }
            bassBoost = BassBoost(0, sessionId)
            virtualizer = Virtualizer(0, sessionId)
            loudnessEnhancer = LoudnessEnhancer(sessionId)
        } catch (_: Exception) {
            // Device may not support all effects
        }
    }

    private fun releaseFx() {
        try { equalizer?.release() } catch (_: Exception) {}
        try { bassBoost?.release() } catch (_: Exception) {}
        try { virtualizer?.release() } catch (_: Exception) {}
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        equalizer = null
        bassBoost = null
        virtualizer = null
        loudnessEnhancer = null
        sessionId = 0
    }

    private fun bandInfo(): Map<String, Any?> {
        val eq = equalizer ?: return mapOf(
            "supported" to false,
            "bands" to emptyList<Map<String, Any>>(),
            "minLevel" to -1500,
            "maxLevel" to 1500
        )
        val n = eq.numberOfBands.toInt()
        val bands = mutableListOf<Map<String, Any>>()
        for (i in 0 until n) {
            val center = eq.getCenterFreq(i.toShort()) / 1000 // Hz
            val level = eq.getBandLevel(i.toShort()).toInt() / 100.0 // dB
            bands.add(mapOf("index" to i, "freq" to center, "level" to level))
        }
        val range = eq.bandLevelRange
        return mapOf(
            "supported" to true,
            "bands" to bands,
            "minLevel" to range[0].toInt() / 100.0,
            "maxLevel" to range[1].toInt() / 100.0
        )
    }

    /** Approximate common presets in dB for available bands */
    private fun applyPreset(name: String) {
        val eq = equalizer ?: return
        val n = eq.numberOfBands.toInt()
        val profiles = mapOf(
            "Flat" to DoubleArray(n) { 0.0 },
            "Acoustic" to approx(n, doubleArrayOf(3.0, 2.0, 1.0, 0.5, 1.0, 1.5, 2.0, 2.5, 2.0, 1.5)),
            "Bass Booster" to approx(n, doubleArrayOf(6.0, 5.0, 4.0, 2.0, 0.0, -0.5, 0.0, 1.0, 2.0, 3.0)),
            "Bass Reducer" to approx(n, doubleArrayOf(-5.0, -4.0, -3.0, -1.0, 0.0, 0.5, 1.0, 1.5, 2.0, 2.0)),
            "Classical" to approx(n, doubleArrayOf(3.0, 2.5, 1.0, 0.0, -0.5, -0.5, 0.0, 1.5, 2.5, 3.0)),
            "Dance" to approx(n, doubleArrayOf(5.0, 4.0, 2.0, 0.0, 0.0, -1.0, 0.0, 2.0, 3.5, 4.0)),
            "Electronic" to approx(n, doubleArrayOf(4.0, 3.5, 1.0, 0.0, -1.5, 1.0, 0.5, 1.5, 3.0, 4.5)),
            "Hip Hop" to approx(n, doubleArrayOf(5.5, 4.5, 1.5, 1.0, -0.5, -0.5, 1.0, 1.5, 2.5, 3.5)),
            "Jazz" to approx(n, doubleArrayOf(3.0, 2.0, 0.5, 1.0, -0.5, -0.5, 0.0, 1.0, 2.0, 3.0)),
            "Pop" to approx(n, doubleArrayOf(-1.0, 0.0, 2.0, 3.5, 2.5, 1.0, 0.0, -0.5, -1.0, -1.5)),
            "Rock" to approx(n, doubleArrayOf(4.0, 3.0, 1.5, 0.0, -1.0, -0.5, 0.5, 2.0, 3.0, 3.5)),
        )
        val levels = profiles[name] ?: profiles["Flat"]!!
        for (i in 0 until n) {
            eq.setBandLevel(i.toShort(), (levels[i] * 100).toInt().toShort())
        }
    }

    private fun approx(n: Int, src: DoubleArray): DoubleArray {
        if (src.size == n) return src
        return DoubleArray(n) { i ->
            val pos = i.toDouble() / (n - 1).coerceAtLeast(1) * (src.size - 1)
            val lo = pos.toInt().coerceIn(0, src.size - 1)
            val hi = (lo + 1).coerceIn(0, src.size - 1)
            val t = pos - lo
            src[lo] * (1 - t) + src[hi] * t
        }
    }
}
