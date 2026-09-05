package com.example.mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Core-Telecom runtime bridge.
 *
 * This layer owns the Core-Telecom lifecycle but is NOT wired into the
 * production FCM/outgoing path yet.
 *
 * Current responsibilities:
 * - create incoming/outgoing Core-Telecom calls
 * - retain their CallControlScope
 * - serialize per-call actions
 * - forward lifecycle callbacks to Flutter
 */
object CoreTelecomCallBridge {

    enum class DisconnectResult {
        SUCCESS,
        RUNTIME_MISSING,
        DUPLICATE,
        SCOPE_TIMEOUT,
        ERROR,
        EXCEPTION,
    }

    private const val ACTION_QUEUE_KEY =
        "flutter.cn_call_core_telecom_actions_v1"
    private const val ANSWER_REQUESTED_KEY =
        "flutter.cn_call_core_telecom_answer_requested_call_ids_v1"

    private val worker =
        CoroutineScope(
            SupervisorJob() + Dispatchers.Default
        )

    private val actionLocks =
        ConcurrentHashMap<String, Mutex>()

    @Volatile
    private var terminalContext: Context? = null

    /**
     * Experimental incoming entry point.
     *
     * Nothing in the current production code calls this yet.
     */
    fun submitIncoming(
        context: Context,
        callId: String,
        callerId: String,
        callerName: String,
    ) {
        submit(
            context = context,
            callId = callId,
            peerId = callerId,
            displayName = callerName,
            incoming = true,
        )
    }

    /**
     * Experimental outgoing entry point.
     *
     * Nothing in the current production code calls this yet.
     */
    fun submitOutgoing(
        context: Context,
        callId: String,
        targetId: String,
        targetName: String = targetId,
    ) {
        submit(
            context = context,
            callId = callId,
            peerId = targetId,
            displayName = targetName,
            incoming = false,
        )
    }

    private fun submit(
        context: Context,
        callId: String,
        peerId: String,
        displayName: String,
        incoming: Boolean,
    ) {
        val id = callId.trim()
        val peer = peerId.trim()

        if (id.isEmpty() || peer.isEmpty()) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "CALL REJECTED: missing identity"
            )
            return
        }

        val runtime =
            CoreTelecomCallRegistry.create(
                callId = id,
                peerId = peer,
                displayName = displayName,
                incoming = incoming,
            )

        if (runtime == null) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "DUPLICATE CALL BLOCKED call_id=$id"
            )
            return
        }

        CoreTelecomManager.register(context.applicationContext)
        terminalContext = context.applicationContext
        if (incoming) {
            CoreTelecomNotification.showIncoming(context, id, displayName, peer)
        }

        worker.launch {
            try {
                val attributes =
                    if (incoming) {
                        CoreTelecomManager.incomingAttributes(
                            peer,
                            displayName,
                        )
                    } else {
                        CoreTelecomManager.outgoingAttributes(
                            peer,
                            displayName,
                        )
                    }

                CoreTelecomManager.addCall(
                    context = context,
                    callId = id,
                    attributes = attributes,
                    onAnswer = { callType ->
                        val runtime =
                            CoreTelecomCallRegistry.get(id)

                        if (runtime == null) {
                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "ANSWER IGNORED: runtime missing " +
                                    "call_id=$id"
                            )
                            return@addCall
                        }

                        if (!runtime.incoming) {
                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "ANSWER IGNORED: not incoming " +
                                    "call_id=$id"
                            )
                            return@addCall
                        }

                        if (runtime.state == CoreTelecomCallRegistry.State.ENDING ||
                            runtime.state == CoreTelecomCallRegistry.State.ENDED ||
                            runtime.state == CoreTelecomCallRegistry.State.ACTIVE ||
                            runtime.state == CoreTelecomCallRegistry.State.ANSWERING
                        ) {
                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "ANSWER DUPLICATE BLOCKED " +
                                    "call_id=$id state=${runtime.state}"
                            )
                            return@addCall
                        }

                        if (!CoreTelecomCallRegistry.tryClaimAnswer(id)) {
                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "ANSWER OWNERSHIP BLOCKED " +
                                    "call_id=$id"
                            )
                            return@addCall
                        }

                        recordAnswerRequested(context, id)

                        println(
                            "[CN CALL][CORE TELECOM] " +
                                "ANSWER REQUEST " +
                                "call_id=$id type=$callType"
                        )

                        println(
                            "[CN CALL][CORE TELECOM] " +
                                "ANSWER RECORDED; CUSTOM CN CALL ACCEPT " +
                                "OWNS DART LIFECYCLE " +
                                "call_id=$id"
                        )
                    },
                    onDisconnect = { cause ->
                        println(
                            "[CN CALL][CORE TELECOM] " +
                                "ON DISCONNECT " +
                                "call_id=$id cause=$cause"
                        )
                        finalizeTerminalCleanup(context, id)
                    },
                    onSetActive = {
                        CoreTelecomCallRegistry.setState(
                            id,
                            CoreTelecomCallRegistry.State.ACTIVE,
                        )

                        println(
                            "[CN CALL][CORE TELECOM] " +
                                "ACTIVE " +
                                "call_id=$id"
                        )
                        CoreTelecomCallRegistry.get(id)?.let { active ->
                            CoreTelecomNotification.showOngoing(
                                context = context,
                                callId = id,
                                peerId = active.peerId,
                                remoteName = active.displayName,
                            )
                        }
                    },
                    onSetInactive = {
                        CoreTelecomCallRegistry.setState(
                            id,
                            CoreTelecomCallRegistry.State.INACTIVE,
                        )

                        println(
                            "[CN CALL][CORE TELECOM] " +
                                "INACTIVE " +
                                "call_id=$id"
                        )

                        /*
                         * Core-Telecom is asking the VoIP app to stop using
                         * the microphone and incoming media here.
                         *
                         * LiveKit is not connected in this experimental
                         * layer yet, so no media operation is performed.
                         */
                    },
                    onScopeReady = { scope ->
                        CoreTelecomCallRegistry.setScope(
                            id,
                            scope,
                        )

                        CoreTelecomCallRegistry.setState(
                            id,
                            if (incoming) {
                                CoreTelecomCallRegistry.State.RINGING
                            } else {
                                CoreTelecomCallRegistry.State.DIALING
                            },
                        )

                        println(
                            "[CN CALL][CORE TELECOM] " +
                                "SCOPE READY call_id=$id"
                        )

                        /*
                         * An action may have arrived before the
                         * CallControlScope existed. Drain it now.
                         */
                        scope.launch {
                            drainQueuedAction(
                                context,
                                id,
                                scope,
                            )
                        }
                    },
                )
            } catch (error: Throwable) {
                println(
                    "[CN CALL][CORE TELECOM] " +
                        "ADD FAILED call_id=$id error=$error"
                )

                CoreTelecomCallRegistry.remove(id)
            }
        }
    }

    /**
     * Activate one Core-Telecom call.
     *
     * This is the only native activation entry point used by Flutter.
     */
    suspend fun activateCall(
        callId: String,
    ): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false

        val runtime = CoreTelecomCallRegistry.get(id)
            ?: return false

        if (
            runtime.state == CoreTelecomCallRegistry.State.ENDING ||
            runtime.state == CoreTelecomCallRegistry.State.ENDED
        ) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "ACTIVATE BLOCKED terminal call_id=$id"
            )
            return false
        }

        val scope =
            runtime.scope
                ?: CoreTelecomCallRegistry.awaitScope(
                    id,
                    timeoutMs = 4500L,
                )

        if (scope == null) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "ACTIVATE SCOPE TIMEOUT call_id=$id"
            )
            return false
        }
        return try {
            val result =
                if (runtime.incoming) {
                    scope.answer(
                        CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
                    )
                } else {
                    scope.setActive()
                }

            when (result) {
                is CallControlResult.Success -> {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "ACTIVATE ACCEPTED call_id=$id"
                    )
                    true
                }

                is CallControlResult.Error -> {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "ACTIVATE ERROR call_id=$id " +
                            "error=${result.errorCode}"
                    )
                    false
                }
            }
        } catch (error: androidx.core.telecom.CallException) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "ACTIVATE EXCEPTION call_id=$id code=${error.code}"
            )
            false
        }
    }

    fun finalizeTerminalCleanup(
        context: Context,
        callId: String,
    ) {
        val id = callId.trim()
        if (id.isEmpty()) {
            return
        }
        val claimed = CoreTelecomCallRegistry.claimTerminalCleanup(id)
        println(
            "[CN CALL][REJECT DIAGNOSTIC] terminal claim " +
                "call_id=$id result=$claimed"
        )
        if (!claimed) return

        val runtime = CoreTelecomCallRegistry.get(id)
        CoreTelecomCallRegistry.markEnded(id)

        fun attempt(operation: String, block: () -> Unit) {
            try {
                block()
            } catch (error: Throwable) {
                println(
                    "[CN CALL][CORE TELECOM] " +
                        "TERMINAL CLEANUP FAILED " +
                        "call_id=$id operation=$operation error=$error"
                )
            }
        }

        attempt("stop_fgs") {
            val stopped =
                CoreTelecomForegroundService.stop(context.applicationContext)
            if (!stopped) {
                println(
                    "[CN CALL][CORE TELECOM] " +
                        "TERMINAL CLEANUP RESULT " +
                        "call_id=$id operation=stop_fgs result=false"
                )
            }
        }
        attempt("cancel_notifications") {
            CoreTelecomNotification.cancelForCall(
                context.applicationContext,
                id,
            )
        }
        attempt("send_terminal_broadcast") {
            println(
                "[CN CALL][REJECT DIAGNOSTIC] before ACTION_TERMINAL " +
                    "call_id=$id"
            )
            context.applicationContext.sendBroadcast(
                android.content.Intent(CNCallIncomingActivity.ACTION_TERMINAL)
                    .setPackage(context.packageName),
            )
            println(
                "[CN CALL][REJECT DIAGNOSTIC] after ACTION_TERMINAL " +
                    "call_id=$id"
            )
        }
        if (runtime != null) {
            attempt("dispatch_flutter_terminal") {
                val dispatch = Runnable {
                    CoreTelecomFlutterDispatcher.dispatch(
                        context = context.applicationContext,
                        action = "ended",
                        callId = id,
                        peerId = runtime.peerId,
                        name = runtime.displayName,
                    )
                }
                if (Looper.myLooper() == Looper.getMainLooper()) {
                    dispatch.run()
                } else {
                    Handler(Looper.getMainLooper()).post(dispatch)
                }
            }
        }
        attempt("clear_answer_marker") {
            if (!clearAnswerRequested(context.applicationContext, id)) {
                println(
                    "[CN CALL][CORE TELECOM] " +
                        "TERMINAL CLEANUP RESULT " +
                        "call_id=$id operation=clear_answer_marker result=false"
                )
            }
        }
        attempt("remove_registry_runtime") {
            println(
                "[CN CALL][REJECT DIAGNOSTIC] before registry removal " +
                    "call_id=$id"
            )
            CoreTelecomCallRegistry.remove(id)
            println(
                "[CN CALL][REJECT DIAGNOSTIC] after registry removal " +
                    "call_id=$id"
            )
        }
        CoreTelecomCallRegistry.completeTerminalCleanup(id)

        println(
            "[CN CALL][CORE TELECOM] " +
                "TERMINAL CLEANUP COMPLETE call_id=$id"
        )
        println(
            "[CN CALL][REJECT DIAGNOSTIC] terminal cleanup completion " +
                "call_id=$id"
        )
    }

    /**
     * Disconnect one Core-Telecom call.
     */
    suspend fun disconnectCallResult(
        callId: String,
        reason: String,
        force: Boolean = false,
    ): DisconnectResult {
        val id = callId.trim()
        if (id.isEmpty()) return DisconnectResult.EXCEPTION

        val runtime =
            CoreTelecomCallRegistry.get(id)
                ?: run {
                    /*
                     * Already removed means Telecom has already reached the
                     * terminal boundary. Treat this as idempotent success.
                     */
                    return DisconnectResult.RUNTIME_MISSING
                }

        if (
            runtime.state == CoreTelecomCallRegistry.State.ENDED
        ) {
            return DisconnectResult.DUPLICATE
        }

        /*
         * If answer ownership has been claimed, only forced terminal
         * transitions (remote cancellation, answer failure) may proceed.
         * User-initiated reject/decline must not steal an already-claimed answer.
         */
        if (!force && CoreTelecomCallRegistry.isAnswerClaimed(id)) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "DISCONNECT BLOCKED: answer already claimed call_id=$id reason=$reason"
            )
            return DisconnectResult.DUPLICATE
        }

        /*
         * Do not allow multiple terminal transactions for the same call.
         * Only the first caller may claim ENDING.
         * force=true allows ANSWERING -> ENDING for legitimate remote terminal.
         */
        if (!CoreTelecomCallRegistry.beginEnding(id, force)) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "DISCONNECT DUPLICATE BLOCKED call_id=$id"
            )
            return DisconnectResult.DUPLICATE
        }

        /*
         * The scope may race with the action/callback during cold start.
         * Wait briefly instead of leaving the runtime permanently ENDING.
         */
        val scope =
            runtime.scope
                ?: CoreTelecomCallRegistry.awaitScope(
                    id,
                    timeoutMs = 4500L,
                )

        if (scope == null) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "DISCONNECT SCOPE TIMEOUT call_id=$id"
            )

            /*
             * Important:
             * Do NOT remove the registry entry here.
             * Do NOT mark ENDED here.
             *
             * The Telecom lifecycle remains authoritative through
             * onDisconnect(). The runtime can still receive that callback.
             */
            return DisconnectResult.SCOPE_TIMEOUT
        }

        println(
            "[CN CALL][CORE TELECOM] " +
                "DISCONNECT START call_id=$id reason=$reason"
        )

        return try {
            val result =
                scope.disconnect(
                    CoreTelecomManager.disconnectCause(reason)
                )

            when (result) {
                is CallControlResult.Success -> {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "DISCONNECT REQUEST ACCEPTED " +
                            "call_id=$id reason=$reason"
                    )

                    finalizeTerminalCleanup(
                        context = terminalContext ?: return DisconnectResult.EXCEPTION,
                        callId = id,
                    )
                    DisconnectResult.SUCCESS
                }

                is CallControlResult.Error -> {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "DISCONNECT ERROR " +
                            "call_id=$id " +
                            "error=${result.errorCode}"
                    )

                    DisconnectResult.ERROR
                }
            }
        } catch (error: androidx.core.telecom.CallException) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "DISCONNECT EXCEPTION " +
                    "call_id=$id code=${error.code}"
            )
            DisconnectResult.EXCEPTION
        } catch (error: RuntimeException) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "DISCONNECT EXCEPTION " +
                    "call_id=$id error=$error"
            )
            DisconnectResult.EXCEPTION
        }
    }

    suspend fun disconnectCall(
        callId: String,
        reason: String,
        force: Boolean = false,
    ): Boolean {
        val disconnectResult = disconnectCallResult(callId, reason, force)
        val booleanResult = when (disconnectResult) {
            DisconnectResult.SUCCESS,
            DisconnectResult.RUNTIME_MISSING,
            DisconnectResult.DUPLICATE -> true
            DisconnectResult.SCOPE_TIMEOUT,
            DisconnectResult.ERROR,
            DisconnectResult.EXCEPTION -> false
        }
        println(
            "[CN CALL][REJECT DIAGNOSTIC] disconnect result " +
                "call_id=${callId.trim()} enum=$disconnectResult boolean=$booleanResult"
        )
        return booleanResult
    }

    /**
     * Called by CoreTelecomActionReceiver after it queues an action.
     *
     * If the call scope is already available, the action is executed
     * immediately. Otherwise it remains persisted until SCOPE READY.
     */
    fun onActionQueued(
        context: Context,
        callId: String,
    ) {
        val id = callId.trim()
        if (id.isEmpty()) return

        val scope =
            CoreTelecomCallRegistry.getScope(id)
                ?: return

        worker.launch {
            drainQueuedAction(
                context,
                id,
                scope,
            )
        }
    }

    private suspend fun drainQueuedAction(
        context: Context,
        callId: String,
        scope: CallControlScope,
    ) {
        val mutex =
            actionLocks.computeIfAbsent(callId) {
                Mutex()
            }

        mutex.withLock {
            while (true) {
                val action =
                    peekQueuedAction(
                        context,
                        callId,
                    ) ?: return

                executeAction(
                    context = context,
                    callId = callId,
                    scope = scope,
                    action = action,
                )

                removeQueuedAction(
                    context,
                    callId,
                    action.optString("action"),
                )
            }
        }
    }

    private suspend fun executeAction(
        context: Context,
        callId: String,
        scope: CallControlScope,
        action: JSONObject,
    ) {
        /*
         * Local alias used by legacy log/terminal references in this function.
         * The outer submit() function uses "id"; executeAction() uses "callId".
         */
        val id = callId
        when (action.optString("action")) {

            "answer" -> {
                val runtime =
                    CoreTelecomCallRegistry.get(callId)
                        ?: return

                if (!runtime.incoming) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "ANSWER IGNORED: not incoming " +
                            "call_id=$callId"
                    )
                    return
                }

                if (!CoreTelecomCallRegistry.tryClaimAnswer(callId)) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "ANSWER OWNERSHIP BLOCKED " +
                            "call_id=$callId"
                    )
                    return
                }

                recordAnswerRequested(context, callId)
                CoreTelecomFlutterDispatcher.dispatch(
                    context = context,
                    action = "answer",
                    callId = callId,
                    peerId = runtime.peerId,
                    name = runtime.displayName,
                )
            }

                        "reject" -> {
                val runtime =
                    CoreTelecomCallRegistry.get(callId)
                        ?: return

                if (!runtime.incoming) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "REJECT IGNORED: not incoming " +
                            "call_id=$callId"
                    )
                    return
                }

                /*
                 * If answer ownership has been claimed, a competing user
                 * reject must not steal the call. Remote terminal and
                 * answer failure use force=true in disconnectCallResult.
                 */
                if (CoreTelecomCallRegistry.isAnswerClaimed(callId)) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "REJECT BLOCKED: answer already claimed call_id=$callId"
                    )
                    return
                }

                if (!CoreTelecomCallRegistry.beginEnding(callId, false)) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "REJECT DUPLICATE/TERMINAL BLOCKED " +
                            "call_id=$callId"
                    )
                    return
                }

                println(
                    "[CN CALL][CORE TELECOM] " +
                        "REJECT START call_id=$callId"
                )

                try {
                    val result =
                        scope.disconnect(
                            CoreTelecomManager.disconnectCause("rejected")
                        )

                    when (result) {
                        is CallControlResult.Success -> {
                            try {
                                CoreTelecomFlutterDispatcher.dispatch(
                                    context = context,
                                    action = "reject",
                                    callId = callId,
                                    peerId = runtime.peerId,
                                    name = runtime.displayName,
                                )
                            } catch (error: RuntimeException) {
                                println(
                                    "[CN CALL][CORE TELECOM] " +
                                        "REJECT FLUTTER DISPATCH FAILED " +
                                        "call_id=$callId error=$error"
                                )
                            }
                            finalizeTerminalCleanup(
                                context = context.applicationContext,
                                callId = callId,
                            )

                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "REJECT REQUEST ACCEPTED " +
                                    "call_id=$callId"
                            )
                        }

                        is CallControlResult.Error -> {
                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "REJECT ERROR " +
                                    "call_id=$callId " +
                                    "error=${result.errorCode}"
                            )
                        }
                    }
                } catch (error: androidx.core.telecom.CallException) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "REJECT EXCEPTION " +
                            "call_id=$callId code=${error.code}"
                    )
                }
            }

            "ended" -> {
                val runtime =
                    CoreTelecomCallRegistry.get(callId)
                        ?: return

                /*
                 * Ongoing notification End action is a legitimate terminal
                 * transition that must proceed even if answer was claimed.
                 * Use force=true to allow ANSWERING -> ENDING transition.
                 */
                if (!CoreTelecomCallRegistry.beginEnding(callId, true)) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "ENDED DUPLICATE/TERMINAL BLOCKED " +
                            "call_id=$callId"
                    )
                    return
                }

                println(
                    "[CN CALL][CORE TELECOM] " +
                        "ENDED START call_id=$callId"
                )

                // The ongoing-notification End action must use the same
                // Dart terminal owner that sends the remote hangup.  Native
                // disconnect remains idempotent and onDisconnect remains the
                // sole native cleanup boundary.
                try {
                    CoreTelecomFlutterDispatcher.dispatch(
                        context = context,
                        action = "hangup",
                        callId = callId,
                        peerId = runtime.peerId,
                        name = runtime.displayName,
                    )
                } catch (error: RuntimeException) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "HANGUP FLUTTER DISPATCH FAILED " +
                            "call_id=$callId error=$error"
                    )
                }

                try {
                    val result =
                        scope.disconnect(
                            CoreTelecomManager.disconnectCause("ended")
                        )

                    when (result) {
                        is CallControlResult.Success -> {
                            finalizeTerminalCleanup(
                                context = context.applicationContext,
                                callId = callId,
                            )
                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "END REQUEST ACCEPTED " +
                                    "call_id=$callId"
                            )
                        }

                        is CallControlResult.Error -> {
                            println(
                                "[CN CALL][CORE TELECOM] " +
                                    "DISCONNECT ERROR " +
                                    "call_id=$callId " +
                                    "error=${result.errorCode}"
                            )
                        }
                    }
                } catch (error: androidx.core.telecom.CallException) {
                    println(
                        "[CN CALL][CORE TELECOM] " +
                            "END EXCEPTION " +
                            "call_id=$callId code=${error.code}"
                    )
                }
            }
        }
    }

    private fun recordAnswerRequested(
        context: Context,
        callId: String,
    ) {
        updateAnswerRequested(context, callId, add = true)
    }

    fun consumeAnswerRequested(
        context: Context,
        callId: String,
    ): Boolean {
        return clearAnswerRequested(context, callId)
    }

    fun claimAnswerForUi(
        context: Context,
        callId: String,
    ): Boolean {
        val id = callId.trim()
        if (!CoreTelecomCallRegistry.tryClaimAnswer(id)) {
            return false
        }
        recordAnswerRequested(context, id)
        return true
    }

    fun hasNativeRuntime(callId: String): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false
        return CoreTelecomCallRegistry.contains(id)
    }

    fun clearAnswerRequested(
        context: Context,
        callId: String,
    ): Boolean {
        return updateAnswerRequested(context, callId, add = false)
    }

    private fun updateAnswerRequested(
        context: Context,
        callId: String,
        add: Boolean,
    ): Boolean {
        val id = callId.trim()
        if (id.isEmpty()) return false

        val prefs =
            context.applicationContext.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
        val answerRequested =
            try {
                JSONArray(
                    prefs.getString(
                        ANSWER_REQUESTED_KEY,
                        "[]",
                    ),
                )
            } catch (_: Exception) {
                JSONArray()
            }

        var present = false
        for (index in 0 until answerRequested.length()) {
            if (answerRequested.optString(index) == id) {
                present = true
                break
            }
        }

        if (add && !present) {
            answerRequested.put(id)
        } else if (!add && present) {
            for (index in answerRequested.length() - 1 downTo 0) {
                if (answerRequested.optString(index) == id) {
                    answerRequested.remove(index)
                }
            }
        }

        val changed = add != present
        if (changed) {
            val editor = prefs.edit()
            if (!add && answerRequested.length() == 0) {
                editor.remove(ANSWER_REQUESTED_KEY)
            } else {
                editor.putString(
                    ANSWER_REQUESTED_KEY,
                    answerRequested.toString(),
                )
            }
            if (!editor.commit()) {
                return false
            }
        }

        return true
    }

    private fun peekQueuedAction(
        context: Context,
        callId: String,
    ): JSONObject? {
        val prefs =
            context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )

        val queue =
            try {
                JSONArray(
                    prefs.getString(
                        ACTION_QUEUE_KEY,
                        "[]",
                    )
                )
            } catch (_: Exception) {
                return null
            }

        for (index in 0 until queue.length()) {
            val item =
                queue.optJSONObject(index)
                    ?: continue

            if (
                item.optString("callId").trim() ==
                callId
            ) {
                return item
            }
        }

        return null
    }

    private fun removeQueuedAction(
        context: Context,
        callId: String,
        actionName: String,
    ) {
        val prefs =
            context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )

        val queue =
            try {
                JSONArray(
                    prefs.getString(
                        ACTION_QUEUE_KEY,
                        "[]",
                    )
                )
            } catch (_: Exception) {
                JSONArray()
            }

        val result = JSONArray()

        for (index in 0 until queue.length()) {
            val item =
                queue.optJSONObject(index)

            if (
                item == null ||
                item.optString("callId").trim() != callId ||
                item.optString("action") != actionName
            ) {
                if (item != null) {
                    result.put(item)
                }
            }
        }

        prefs.edit()
            .putString(
                ACTION_QUEUE_KEY,
                result.toString(),
            )
            .apply()
    }
}
