package io.github.drak905.tapo_tv

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
        throw NotImplementedError()

    /**
     * True when decoders must be sorted software-first (emulator: the
     * goldfish hardware H.264 decoder stalls after about a dozen live
     * frames). Real TVs keep hardware decoders.
     */
    fun preferSoftwareDecoders(emulator: Boolean): Boolean = throw NotImplementedError()

    /** The video TextureView never takes focus (D-pad stays in Flutter). */
    val videoViewFocusable: Boolean get() = throw NotImplementedError()

    /**
     * A bridge URL is accepted only for http://127.0.0.1:<port>/camera/<id>.ts
     * with a non-empty per-launch key `k` query parameter.
     */
    fun isBridgeUrl(url: String): Boolean = throw NotImplementedError()

    /** The key `k` of a bridge URL, or null when absent/empty. */
    fun bridgeKey(url: String): String? = throw NotImplementedError()
}
