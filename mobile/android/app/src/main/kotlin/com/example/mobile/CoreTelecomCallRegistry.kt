package com.example.mobile

import androidx.core.telecom.CallControlScope
import kotlinx.coroutines.CompletableDeferred
import java.util.concurrent.ConcurrentHashMap

/**
 * Single source of truth for Core-Telecom runtime ownership.
 *
 * One call_id owns exactly one runtime entry.
 *
 * This registry never calls Telecom APIs.
 */
object CoreTelecomCallRegistry {

    enum class State {
        SETTING_UP,
        RINGING,
        ANSWERING,
        DIALING,
        ACTIVE,
        INACTIVE,
        ENDING,
        ENDED,
    }

    data class CallRuntime(
        val callId: String,
        val peerId: String,
        val displayName: String,
        val incoming: Boolean,
        val scope: CallControlScope? = null,
        val state: State = State.SETTING_UP,
    )

    private val calls =
        ConcurrentHashMap<String, CallRuntime>()

    private enum class TerminalCleanupState {
        CLAIMED,
        COMPLETED,
    }

    private val terminalCleanup =
        ConcurrentHashMap<String, TerminalCleanupState>()

    private val answerClaims =
        ConcurrentHashMap<String, Boolean>()

    /*
     * One readiness gate per call_id.
     * activate/disconnect may arrive before Telecom enters the
     * CallControlScope block, especially during cold starts.
     */
    private val scopeReady =
        ConcurrentHashMap<String, CompletableDeferred<CallControlScope>>()

    fun create(
        callId: String,
        peerId: String,
        displayName: String,
        incoming: Boolean,
    ): CallRuntime? {
        val id = callId.trim()
        val peer = peerId.trim()

        if (id.isEmpty() || peer.isEmpty()) {
            return null
        }

        val runtime =
            CallRuntime(
                callId = id,
                peerId = peer,
                displayName = displayName.trim().ifEmpty { peer },
                incoming = incoming,
            )

        val existing = calls.putIfAbsent(id, runtime)

        if (existing != null) {
            return null
        }

        scopeReady.putIfAbsent(
            id,
            CompletableDeferred(),
        )

        return runtime
    }

    fun get(callId: String): CallRuntime? {
        return calls[callId.trim()]
    }

    fun contains(callId: String): Boolean {
        val id = callId.trim()
        return id.isNotEmpty() && calls.containsKey(id)
    }

    fun setScope(
        callId: String,
        scope: CallControlScope,
    ): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false

        var updated = false

        calls.computeIfPresent(id) { _, runtime ->
            if (
                runtime.state == State.ENDED
            ) {
                runtime
            } else if (
                runtime.scope != null &&
                runtime.scope !== scope
            ) {
                runtime
            } else {
                updated = true
                runtime.copy(scope = scope)
            }
        }

        if (updated) {
            scopeReady
                .computeIfAbsent(id) {
                    CompletableDeferred()
                }
                .complete(scope)
        }

        return updated
    }

    suspend fun awaitScope(
        callId: String,
        timeoutMs: Long = 4500L,
    ): CallControlScope? {
        val id = callId.trim()
        if (id.isEmpty()) return null

        getScope(id)?.let { return it }

        val waiter =
            scopeReady.computeIfAbsent(id) {
                CompletableDeferred()
            }

        return try {
            kotlinx.coroutines.withTimeoutOrNull(timeoutMs) {
                waiter.await()
            }
        } catch (_: Throwable) {
            null
        }
    }

    fun getScope(
        callId: String,
    ): CallControlScope? {
        return calls[callId.trim()]?.scope
    }

    /**
     * Normal lifecycle update.
     *
     * Once ENDING/ENDED is reached, the call cannot regress to an
     * earlier active state.
     */
    fun setState(
        callId: String,
        state: State,
    ): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false

        var updated = false

        calls.compute(id) { _, runtime ->
            if (runtime == null) {
                null
            } else {
                /*
                 * Once a call is terminal, no later callback/action may
                 * resurrect it into a non-terminal state.
                 */
                if (
                    (runtime.state == State.ENDING ||
                     runtime.state == State.ENDED) &&
                    state != State.ENDED
                ) {
                    return@compute runtime
                }

                updated = true
                runtime.copy(state = state)
            }
        }

        return updated
    }

    /**
     * Atomically claims the terminal transition for one call_id.
     *
     * Only the first caller that observes a non-terminal runtime may
     * transition it to ENDING. All later reject/hangup/end events are
     * rejected before they can call scope.disconnect().
     *
     * If force is true, ANSWERING state does not block the transition.
     * This allows legitimate remote terminal events and answer failure
     * cleanup to proceed even when answer ownership has been claimed.
     */
    fun beginEnding(callId: String, force: Boolean = false): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false

        var claimed = false

        calls.compute(id) { _, runtime ->
            if (runtime == null) {
                null
            } else if (
                runtime.state == State.ENDING ||
                runtime.state == State.ENDED ||
                (!force && runtime.state == State.ANSWERING)
            ) {
                runtime
            } else {
                claimed = true
                runtime.copy(state = State.ENDING)
            }
        }

        return claimed
    }

    /**
     * Checks if answer ownership has been claimed for a call.
     * Read-only check; does not mutate state.
     */
    fun isAnswerClaimed(callId: String): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false
        return answerClaims.containsKey(id)
    }

    /**
     * Atomically claims the answer transition for one incoming call.
     *
     * The runtime-keyed compute is serialized with beginEnding(), so an
     * answer cannot claim a call while it is entering a terminal state.
     */
    fun tryClaimAnswer(callId: String): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false

        var claimed = false

        calls.compute(id) { _, runtime ->
            if (runtime == null) {
                null
            } else if (
                !runtime.incoming ||
                runtime.state == State.ENDING ||
                runtime.state == State.ENDED
            ) {
                runtime
            } else if (
                answerClaims.putIfAbsent(id, true) != null
            ) {
                runtime
            } else {
                claimed = true
                runtime.copy(state = State.ANSWERING)
            }
        }

        return claimed
    }

    /**
     * Marks the call terminal only after Telecom has confirmed
     * the disconnect through onDisconnect.
     */
    fun markEnded(callId: String): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false

        var updated = false

        calls.compute(id) { _, runtime ->
            if (runtime == null) {
                null
            } else {
                updated = true
                runtime.copy(state = State.ENDED)
            }
        }

        return updated
    }

    fun claimTerminalCleanup(callId: String): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false
        return terminalCleanup.putIfAbsent(id, TerminalCleanupState.CLAIMED) == null
    }

    fun completeTerminalCleanup(callId: String): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false
        return terminalCleanup.replace(
            id,
            TerminalCleanupState.CLAIMED,
            TerminalCleanupState.COMPLETED,
        )
    }

    fun remove(
        callId: String,
    ): CallRuntime? {
        val id = callId.trim()
        if (id.isEmpty()) return null

        scopeReady.remove(id)?.cancel()

        return calls.remove(id)
    }

    fun size(): Int {
        return calls.size
    }

    fun snapshot(): List<CallRuntime> {
        return calls.values.toList()
    }

    fun clear() {
        calls.clear()
        scopeReady.values.forEach { it.cancel() }
        scopeReady.clear()
        terminalCleanup.clear()
        answerClaims.clear()
    }
}
