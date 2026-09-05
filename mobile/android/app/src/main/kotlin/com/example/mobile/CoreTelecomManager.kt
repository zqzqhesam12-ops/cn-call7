package com.example.mobile

import android.content.Context
import android.net.Uri
import android.telecom.DisconnectCause
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallsManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.sync.Mutex

/**
 * Native Core-Telecom owner.
 *
 * Production call flow is not switched yet.
 */
object CoreTelecomManager {

    private const val APP_SCHEME = "cncall"
    private const val BACKWARDS_COMPAT_SDK = 33

    @Volatile
    private var callsManager: CallsManager? = null

    /**
     * Only protects the setup phase.
     *
     * IMPORTANT:
     * addCall() itself remains suspended for the whole call lifetime.
     * Therefore this mutex MUST be released from the CallControlScope block.
     */
    private val setupMutex = Mutex()

    @Synchronized
    fun get(context: Context): CallsManager {
        return callsManager
            ?: CallsManager(context.applicationContext).also {
                callsManager = it
            }
    }

    fun register(context: Context) {
        synchronized(this) {
            get(context).registerAppWithTelecom(
                CallsManager.CAPABILITY_BASELINE,
                BACKWARDS_COMPAT_SDK,
            )

            println("[CN CALL][CORE TELECOM] APP REGISTERED")
        }
    }

    fun incomingAttributes(
        callerId: String,
        callerName: String,
    ): CallAttributesCompat {
        return createAttributes(
            peerId = callerId,
            displayName = callerName,
            direction = CallAttributesCompat.DIRECTION_INCOMING,
        )
    }

    fun outgoingAttributes(
        targetId: String,
        targetName: String = targetId,
    ): CallAttributesCompat {
        return createAttributes(
            peerId = targetId,
            displayName = targetName,
            direction = CallAttributesCompat.DIRECTION_OUTGOING,
        )
    }

    /**
     * Adds one Core-Telecom call.
     *
     * Setup is serialized until Telecom enters the CallControlScope.
     */
    suspend fun addCall(
        context: Context,
        callId: String,
        attributes: CallAttributesCompat,
        onAnswer: suspend (Int) -> Unit,
        onDisconnect: suspend (DisconnectCause) -> Unit,
        onSetActive: suspend () -> Unit,
        onSetInactive: suspend () -> Unit,
        onScopeReady: (CallControlScope) -> Unit,
    ) {
        val id = callId.trim()

        require(id.isNotEmpty()) {
            "Core-Telecom callId must not be empty"
        }

        setupMutex.lock()

        var setupReleased = false

        fun releaseSetup() {
            if (setupReleased) return

            setupReleased = true
            setupMutex.unlock()

            println(
                "[CN CALL][CORE TELECOM] SETUP RELEASED call_id=$id"
            )
        }

        try {
            println(
                "[CN CALL][CORE TELECOM] ADD START " +
                    "call_id=$id direction=${attributes.direction}"
            )

            get(context).addCall(
                callAttributes = attributes,

                onAnswer = { callType ->
                    println(
                        "[CN CALL][CORE TELECOM] ON ANSWER " +
                            "call_id=$id type=$callType"
                    )
                    onAnswer(callType)
                },

                onDisconnect = { cause ->
                    println(
                        "[CN CALL][CORE TELECOM] ON DISCONNECT " +
                            "call_id=$id cause=$cause"
                    )
                    onDisconnect(cause)
                },

                onSetActive = {
                    println(
                        "[CN CALL][CORE TELECOM] ON ACTIVE call_id=$id"
                    )
                    onSetActive()
                },

                onSetInactive = {
                    println(
                        "[CN CALL][CORE TELECOM] ON INACTIVE call_id=$id"
                    )
                    onSetInactive()
                },

                block = {
                    println(
                        "[CN CALL][CORE TELECOM] SCOPE READY call_id=$id"
                    )

                    /*
                     * The next addCall setup may now begin.
                     *
                     * This MUST happen before invoking application lifecycle
                     * callbacks, because callbacks may themselves schedule
                     * the next call.
                     */
                    releaseSetup()

                    try {
                        onScopeReady(this)
                    } catch (error: Throwable) {
                        println(
                            "[CN CALL][CORE TELECOM] " +
                                "SCOPE CALLBACK FAILED " +
                                "call_id=$id error=$error"
                        )

                        throw error
                    }
                },
            )
        } catch (error: androidx.core.telecom.CallException) {
            releaseSetup()

            println(
                "[CN CALL][CORE TELECOM] " +
                    "CALL EXCEPTION " +
                    "call_id=$id code=${error.code}"
            )

            throw error
        } catch (error: Throwable) {
            releaseSetup()

            println(
                "[CN CALL][CORE TELECOM] " +
                    "ADD FAILED call_id=$id error=$error"
            )

            throw error
        } finally {
            /*
             * If Telecom failed before entering the block, this guarantees
             * another call cannot remain permanently blocked.
             */
            releaseSetup()
        }
    }

    fun currentEndpoint(
        callId: String,
    ): Flow<androidx.core.telecom.CallEndpointCompat>? {
        return CoreTelecomCallRegistry
            .getScope(callId)
            ?.currentCallEndpoint
    }

    fun availableEndpoints(
        callId: String,
    ): Flow<List<androidx.core.telecom.CallEndpointCompat>>? {
        return CoreTelecomCallRegistry
            .getScope(callId)
            ?.availableEndpoints
    }

    fun muted(
        callId: String,
    ): Flow<Boolean>? {
        return CoreTelecomCallRegistry
            .getScope(callId)
            ?.isMuted
    }

    suspend fun activateCall(
        callId: String,
    ) {
        val scope =
            CoreTelecomCallRegistry.getScope(callId)
                ?: throw androidx.core.telecom.CallException(
                    androidx.core.telecom.CallException
                        .ERROR_CALL_IS_NOT_BEING_TRACKED
                )

        scope.setActive()
    }

    suspend fun disconnectCall(
        callId: String,
        reason: String,
    ) {
        val id = callId.trim()

        if (id.isEmpty()) return

        /*
         * Exactly one caller wins the terminal transition.
         */
        if (!CoreTelecomCallRegistry.beginEnding(id)) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "DUPLICATE TERMINAL BLOCKED call_id=$id"
            )
            return
        }

        val scope =
            CoreTelecomCallRegistry.getScope(id)

        if (scope == null) {
            CoreTelecomCallRegistry.markEnded(id)

            println(
                "[CN CALL][CORE TELECOM] " +
                    "DISCONNECT WITHOUT SCOPE call_id=$id"
            )
            return
        }

        println(
            "[CN CALL][CORE TELECOM] " +
                "DISCONNECT START call_id=$id reason=$reason"
        )

        try {
            scope.disconnect(
                disconnectCause(reason)
            )
        } catch (error: androidx.core.telecom.CallException) {
            if (
                error.code ==
                androidx.core.telecom.CallException
                    .ERROR_CALL_IS_NOT_BEING_TRACKED
            ) {
                CoreTelecomCallRegistry.markEnded(id)
            }

            println(
                "[CN CALL][CORE TELECOM] " +
                    "DISCONNECT FAILED " +
                    "call_id=$id code=${error.code}"
            )

            throw error
        }
    }

    fun disconnectCause(
        reason: String,
    ): DisconnectCause {
        return when (reason) {
            "rejected" ->
                DisconnectCause(DisconnectCause.REJECTED)

            "remote" ->
                DisconnectCause(DisconnectCause.REMOTE)

            "missed",
            "timeout" ->
                DisconnectCause(DisconnectCause.MISSED)

            else ->
                DisconnectCause(DisconnectCause.LOCAL)
        }
    }

    private fun createAttributes(
        peerId: String,
        displayName: String,
        direction: Int,
    ): CallAttributesCompat {
        val safePeerId = peerId.trim()

        require(safePeerId.isNotEmpty()) {
            "Core-Telecom peer id must not be empty"
        }

        val safeDisplayName =
            displayName.trim().ifEmpty { safePeerId }

        return CallAttributesCompat(
            safeDisplayName,
            Uri.parse("$APP_SCHEME:$safePeerId"),
            direction,
            CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
            CallAttributesCompat.SUPPORTS_SET_INACTIVE,
        )
    }
}
