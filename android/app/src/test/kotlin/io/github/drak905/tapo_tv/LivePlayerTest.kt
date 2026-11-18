package io.github.drak905.tapo_tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-logic tests of the native player policy (spec mb.exo.*, mb.security.bridge). */
class LivePlayerTest {
    @Test
    fun emulatorDetectedFromGoldfishHardware() {
        assertTrue(PlayerPolicy.isEmulator("goldfish", "tv_x86", "google/tv/tv:14"))
    }

    @Test
    fun emulatorDetectedFromRanchuHardware() {
        assertTrue(PlayerPolicy.isEmulator("ranchu", "tv_x86", "google/tv/tv:14"))
    }

    @Test
    fun emulatorDetectedFromSdkProductPrefix() {
        assertTrue(PlayerPolicy.isEmulator("qcom", "sdk_google_atv_x86", "vendor/tv/tv:14"))
    }

    @Test
    fun emulatorDetectedFromGenericFingerprint() {
        assertTrue(PlayerPolicy.isEmulator("qcom", "tvbox", "generic/vbox86p/vbox86p:14"))
    }

    @Test
    fun realTvIsNotAnEmulator() {
        assertFalse(PlayerPolicy.isEmulator("amlogic", "sabrina", "google/sabrina/sabrina:14"))
    }

    @Test
    fun emulatorPrefersSoftwareDecoders() {
        assertTrue(PlayerPolicy.preferSoftwareDecoders(true))
    }

    @Test
    fun realTvKeepsHardwareDecoders() {
        assertFalse(PlayerPolicy.preferSoftwareDecoders(false))
    }

    @Test
    fun videoViewIsNotFocusable() {
        assertFalse(PlayerPolicy.videoViewFocusable)
    }

    @Test
    fun bridgeUrlWithKeyIsAccepted() {
        val url = "http://127.0.0.1:41234/camera/DEV1.ts?k=abc123&n=1"
        assertTrue(PlayerPolicy.isBridgeUrl(url))
        assertEquals("abc123", PlayerPolicy.bridgeKey(url))
    }

    @Test
    fun bridgeUrlWithoutKeyIsRejected() {
        val url = "http://127.0.0.1:41234/camera/DEV1.ts?n=1"
        assertFalse(PlayerPolicy.isBridgeUrl(url))
        assertNull(PlayerPolicy.bridgeKey(url))
    }

    @Test
    fun bridgeUrlWithEmptyKeyIsRejected() {
        assertFalse(PlayerPolicy.isBridgeUrl("http://127.0.0.1:41234/camera/DEV1.ts?k=&n=1"))
    }

    @Test
    fun nonLoopbackUrlIsRejected() {
        assertFalse(PlayerPolicy.isBridgeUrl("http://192.168.1.20:41234/camera/DEV1.ts?k=abc123"))
        assertFalse(PlayerPolicy.isBridgeUrl("https://example.com/camera/DEV1.ts?k=abc123"))
    }

    @Test
    fun otherPathsAreRejected() {
        assertFalse(PlayerPolicy.isBridgeUrl("http://127.0.0.1:41234/other/DEV1.ts?k=abc123"))
        assertFalse(PlayerPolicy.isBridgeUrl("http://127.0.0.1:41234/camera/DEV1.mp4?k=abc123"))
    }
}
