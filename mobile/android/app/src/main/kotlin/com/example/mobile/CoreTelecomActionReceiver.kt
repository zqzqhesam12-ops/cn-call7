package com.example.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

/**
 * Receives Core-Telecom lifecycle actions and forwards them to Flutter.
 *
 * This receiver intentionally does NOT invoke a phone UI or the legacy
 * It is the only broadcast action bridge for the Core-Telecom path.
 *
 * The Core-Telecom bridge will consume the queued action.
 */
class CoreTelecomActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_REJECT =
            "com.example.mobile.CORE_TELECOM_REJECT"

        const val ACTION_DISCONNECT =
            "com.example.mobile.CORE_TELECOM_DISCONNECT"

        const val ACTION_ANSWER =
            "com.example.mobile.CORE_TELECOM_ANSWER"

        const val EXTRA_CALL_ID = "call_id"
        const val EXTRA_PEER_ID = "peer_id"
        const val EXTRA_NAME = "name"

        private const val QUEUE_KEY =
            "flutter.cn_call_core_telecom_actions_v1"
    }

    override fun onReceive(
        context: Context,
        intent: Intent?,
    ) {
        val event = intent ?: return

        val action = when (event.action) {
            ACTION_REJECT -> "reject"
            ACTION_DISCONNECT -> "ended"
            ACTION_ANSWER -> "answer"
            else -> return
        }

        val callId =
            event.getStringExtra(EXTRA_CALL_ID)
                ?.trim()
                .orEmpty()

        val peerId =
            event.getStringExtra(EXTRA_PEER_ID)
                ?.trim()
                .orEmpty()

        val name =
            event.getStringExtra(EXTRA_NAME)
                ?.trim()
                .orEmpty()

        if (callId.isEmpty()) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "ignored action without callId"
            )
            return
        }

        val prefs =
            context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )

        val queue =
            try {
                JSONArray(
                    prefs.getString(
                        QUEUE_KEY,
                        "[]",
                    ),
                )
            } catch (_: Exception) {
                JSONArray()
            }

        /*
         * Same terminal/user action must only enter the queue once.
         */
        for (index in 0 until queue.length()) {
            val existing =
                queue.optJSONObject(index)
                    ?: continue

            if (
                existing.optString("action") == action &&
                existing.optString("callId") == callId
            ) {
                return
            }
        }

        queue.put(
            JSONObject().apply {
                put("action", action)
                put("callId", callId)
                put("peerId", peerId)
                put("name", name)
                put(
                    "at",
                    System.currentTimeMillis(),
                )
            },
        )

        /*
         * Keep the queue intentionally bounded.
         * Old actions must never accumulate indefinitely.
         */
        while (queue.length() > 32) {
            queue.remove(0)
        }

        prefs.edit()
            .putString(
                QUEUE_KEY,
                queue.toString(),
            )
            .apply()

        println(
            "[CN CALL][CORE TELECOM] " +
                "ACTION QUEUED " +
                "action=$action call_id=$callId"
        )

        CoreTelecomCallBridge.onActionQueued(
            context = context,
            callId = callId,
        )
    }
}
