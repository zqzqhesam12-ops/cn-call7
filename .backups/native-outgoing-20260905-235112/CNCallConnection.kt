package com.example.mobile

import android.content.Context
import android.net.Uri
import android.telecom.Connection
import android.telecom.DisconnectCause

class CNCallConnection(
    private val appContext: Context,
    val callId: String,
    private val incoming: Boolean,
    private val callerId: String,
    private val callerName: String,
    private val address: Uri,
) : Connection() {
    private var terminal = false
    private var answering = false
    private var active = false
    private val engineCallbacks = object : CNCallEngine.Callbacks {
        override fun onMediaReady() {
            if (!terminal && answering && !active) {
                if (CNCallRegistry.markActive(callId)) {
                    active = true
                    answering = false
                    setActive()
                }
            }
        }

        override fun onDisconnected() {
            if (!terminal) {
                fail(DisconnectCause.REMOTE)
            }
        }

        override fun onError(message: String) {
            if (!terminal) {
                println("[CN CALL][TELECOM] engine error call_id=$callId message=$message")
                fail(DisconnectCause.ERROR)
            }
        }
    }

    init {
        setAddress(address, PRESENTATION_ALLOWED)
        if (callerName.isNotBlank()) {
            setCallerDisplayName(callerName, PRESENTATION_ALLOWED)
        }
    }

    fun beginRinging() {
        if (!terminal) {
            setRinging()
        }
    }

    fun beginDialing() {
        if (!terminal) {
            setDialing()
        }
    }

    override fun onAnswer() {
        if (terminal || !incoming || answering || active) return
        if (!CNCallRegistry.claimAnswer(callId)) return
        answering = true
        CNCallNotification.cancel(appContext, callId)
        if (!CNCallEngine.hasRecordAudioPermission(appContext)) {
            fail(DisconnectCause.ERROR)
            return
        }
        if (!CNCallEngine.initialize(appContext, engineCallbacks) ||
            !CNCallEngine.startIncoming(callId, callerId, callerName)
        ) {
            fail(DisconnectCause.ERROR)
            return
        }
        val answerStarted = CNCallEngine.answer(callId)
        if (!answerStarted) {
            fail(DisconnectCause.ERROR)
        }
    }

    override fun onReject() {
        if (terminal || !CNCallRegistry.claimReject(callId)) return
        if (CNCallEngine.reject(callId)) {
            fail(DisconnectCause.REJECTED)
        } else {
            fail(DisconnectCause.ERROR)
        }
    }

    override fun onDisconnect() {
        if (terminal || !CNCallRegistry.claimDisconnect(callId)) return
        terminal = true
        answering = false
        active = false
        CNCallRegistry.markTerminated(callId)
        CNCallEngine.disconnect(callId)
        CNCallEngine.release(callId)
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroyAndRemove()
    }

    override fun onAbort() {
        onDisconnect()
    }

    override fun onHold() {
        if (!terminal && active && CNCallEngine.hold(callId)) {
            setOnHold()
        }
    }

    override fun onUnhold() {
        if (!terminal && active && CNCallEngine.unhold(callId)) {
            setActive()
        }
    }

    fun fail(code: Int) {
        if (terminal) return
        terminal = true
        answering = false
        active = false
        CNCallEngine.release(callId)
        CNCallNotification.cancel(appContext, callId)
        setDisconnected(DisconnectCause(code))
        destroyAndRemove()
    }

    override fun onShowIncomingCallUi() {
        if (!terminal && incoming) {
            CNCallNotification.showIncoming(appContext, callId, callerName)
        }
    }

    private fun destroyAndRemove() {
        CNCallRegistry.remove(callId)
        CNCallNotification.cancel(appContext, callId)
        destroy()
    }
}
