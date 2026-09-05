package com.example.mobile

/**
 * Lightweight source-level sanity checks.
 *
 * This file is intentionally not a runtime production test.
 */
object CoreTelecomCallRegistryTest {

    fun verifyBasicOwnership() {
        val first = CoreTelecomCallRegistry.create(
            callId = "test-call-1",
            peerId = "1",
            displayName = "Test",
            incoming = false,
        ) ?: error("first call was not created")

        check(
            CoreTelecomCallRegistry.get("test-call-1") === first
        )

        val duplicate = CoreTelecomCallRegistry.create(
            callId = "test-call-1",
            peerId = "1",
            displayName = "Test",
            incoming = false,
        )

        check(duplicate == null)

        check(
            CoreTelecomCallRegistry.setState(
                "test-call-1",
                CoreTelecomCallRegistry.State.ACTIVE,
            )
        )

        check(
            CoreTelecomCallRegistry.get("test-call-1")?.state ==
                CoreTelecomCallRegistry.State.ACTIVE
        )

        check(
            CoreTelecomCallRegistry.remove("test-call-1") != null
        )

        check(
            !CoreTelecomCallRegistry.contains("test-call-1")
        )
    }
}
