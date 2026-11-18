package io.github.drak905.tapo_tv

import java.net.URI
import java.net.URLDecoder

/**
 * Pure decisions of the native player, kept free of Android classes so they
 * run in JVM unit tests. LivePlayer.kt calls these.
 */
object PlayerPolicy {
    /**
     * Emulator detection from Build values: HARDWARE contains goldfish or
     * ranchu, PRODUCT starts with sdk_, or FINGERPRINT contains generic.
     */
    fun isEmulator(hardware: String, product: String, fingerprint: String): Boolean =
        hardware.contains("goldfish") || hardware.contains("ranchu") ||
            product.startsWith("sdk_") || fingerprint.contains("generic")

    /**
     * True when decoders must be sorted software-first (emulator: the
     * goldfish hardware H.264 decoder stalls after about a dozen live
     * frames). Real TVs keep hardware decoders.
     */
    fun preferSoftwareDecoders(emulator: Boolean): Boolean = emulator

    /** The video TextureView never takes focus (D-pad stays in Flutter). */
    val videoViewFocusable: Boolean get() = false

    private val cameraPath = Regex("^/camera/[^/]+\\.ts$")

    private fun parse(url: String): URI? = try {
        URI(url)
    } catch (_: Exception) {
        null
    }

    /**
     * A bridge URL is accepted only for http://127.0.0.1:<port>/camera/<id>.ts
     * with a non-empty per-launch key `k` query parameter.
     */
    fun isBridgeUrl(url: String): Boolean {
        val uri = parse(url) ?: return false
        if (uri.scheme != "http" || uri.host != "127.0.0.1" || uri.port !in 1..65535) return false
        val path = uri.rawPath ?: return false
        if (!cameraPath.matches(path)) return false
        return bridgeKey(url) != null
    }

    /** The key `k` of a bridge URL, or null when absent/empty. */
    fun bridgeKey(url: String): String? {
        val query = parse(url)?.rawQuery ?: return null
        for (pair in query.split('&')) {
            val eq = pair.indexOf('=')
            val name = if (eq < 0) pair else pair.substring(0, eq)
            if (name != "k") continue
            val value = if (eq < 0) "" else URLDecoder.decode(pair.substring(eq + 1), "UTF-8")
            return value.ifEmpty { null }
        }
        return null
    }
}
