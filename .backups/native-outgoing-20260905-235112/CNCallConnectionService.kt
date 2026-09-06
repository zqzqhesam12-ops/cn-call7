package com.example.mobile

import android.net.Uri
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause

class CNCallConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: android.telecom.PhoneAccountHandle,
        request: ConnectionRequest,
    ): Connection? {
        val extras = request.extras
        val callId = extras.getString(EXTRA_CALL_ID)?.trim().orEmpty()
        val callerId = extras.getString(EXTRA_CALLER_ID)?.trim().orEmpty()
        val callerName = extras.getString(EXTRA_CALLER_NAME)?.trim().orEmpty()

        if (callId.isEmpty() || callerId.isEmpty()) {
            return Connection.createFailedConnection(
                DisconnectCause(DisconnectCause.ERROR),
            )
        }

        val connection = CNCallConnection(
            appContext = applicationContext,
            callId = callId,
            incoming = true,
            callerId = callerId,
            callerName = callerName,
            address = request.address ?: Uri.parse("cncall:$callerId"),
        )
        if (!CNCallRegistry.put(
                CNCallRegistry.Entry(callId, connection, incoming = true),
            )
        ) {
            return Connection.createFailedConnection(
                DisconnectCause(DisconnectCause.BUSY),
            )
        }

        connection.beginRinging()
        return connection
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: android.telecom.PhoneAccountHandle,
        request: ConnectionRequest,
    ): Connection? {
        val address = request.address ?: return Connection.createFailedConnection(
            DisconnectCause(DisconnectCause.ERROR),
        )
        val callId = "telecom-${System.currentTimeMillis()}-${address.hashCode()}"
        val connection = CNCallConnection(
            appContext = applicationContext,
            callId = callId,
            incoming = false,
            callerId = address.schemeSpecificPart.orEmpty(),
            callerName = address.schemeSpecificPart.orEmpty(),
            address = address,
        )
        if (!CNCallRegistry.put(
                CNCallRegistry.Entry(callId, connection, incoming = false),
            )
        ) {
            return Connection.createFailedConnection(
                DisconnectCause(DisconnectCause.BUSY),
            )
        }

        connection.beginDialing()
        if (!CNCallEngine.startOutgoing(callId, address.toString())) {
            connection.fail(DisconnectCause.ERROR)
        }
        return connection
    }

    override fun onDestroy() {
        super.onDestroy()
    }

    companion object {
        const val EXTRA_CALL_ID = "com.example.mobile.extra.CALL_ID"
        const val EXTRA_CALLER_ID = "com.example.mobile.extra.CALLER_ID"
        const val EXTRA_CALLER_NAME = "com.example.mobile.extra.CALLER_NAME"
    }
}
