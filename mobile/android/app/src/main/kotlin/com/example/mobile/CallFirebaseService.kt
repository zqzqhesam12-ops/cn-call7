package com.example.mobile

import org.json.JSONArray
import org.json.JSONObject
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class CallFirebaseService : FirebaseMessagingService() {

    private val serviceScope =
        CoroutineScope(Dispatchers.Default)

    override fun onMessageReceived(message: RemoteMessage) {

        val type = message.data["type"]

        if (
            type == "call_cancelled" ||
            type == "call_reject" ||
            type == "hangup" ||
            type == "timeout" ||
            type == "disconnected"
        ) {
            val callId =
                message.data["call_id"]
                    ?.trim()
                    .orEmpty()

            if (callId.isEmpty()) return

            // The native service only records a terminal tombstone. Flutter
            // reconciles signalling/media when it is active; no Telecom call
            // exists to disconnect here.
            serviceScope.launch {
                  try {
                      markCallEnded(callId)
                      val disconnectResult =
                          CoreTelecomCallBridge.disconnectCallResult(callId, type)
                      if (disconnectResult == CoreTelecomCallBridge.DisconnectResult.SUCCESS) {
                          CoreTelecomCallBridge.finalizeTerminalCleanup(
                              context = this@CallFirebaseService.applicationContext,
                              callId = callId,
                          )
                      }

                      println(
                          "[CN CALL][FCM] " +
                              "FCM TERMINAL HANDLED " +
                              "type=$type call_id=$callId"
                      )

                  } catch (error: Throwable) {
                      println("[CN CALL][FCM] terminal persistence failed call_id=$callId error=$error")
                  }
              }

return
        }

        if (type != "incoming_call") {
            return
        }

        val callerName =
            message.data["caller_name"]
                ?: "CN CALL"

        val callerId =
            message.data["caller_id"]
                ?: message.data["from_id"]
                ?: ""

        if (callerId.isEmpty()) {
            return
        }

        val callId = message.data["call_id"]?.trim().orEmpty()
        if (callId.isEmpty()) return
        if (isCallEnded(callId)) {
            println("CN CALL: ignored stale incoming FCM. callId=$callId")
            return
        }

        // The full-screen PendingIntent is the single durable UI handoff: it
        // carries this exact identity into CNCallIncomingActivity.  Do not
        // mirror it into Flutter preferences, which could belong to an older
        // call by the time the Activity starts.
        try {
            CoreTelecomCallBridge.submitIncoming(this@CallFirebaseService, callId, callerId, callerName)

            println("[CN CALL][FCM] Flutter incoming launched call_id=$callId")
        } catch (e: Exception) {
            println("[CN CALL][FCM] incoming launch failed call_id=$callId error=$e")
        }

        return
    }

    private fun isCallEnded(callId: String): Boolean {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        return endedCallIds(prefs).contains(callId)
    }

    private fun markCallEnded(callId: String) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val endedIds = endedCallIds(prefs).toMutableList()
        endedIds.remove(callId)
        endedIds.add(callId)
        if (endedIds.size > 32) {
            endedIds.subList(0, endedIds.size - 32).clear()
        }

        val editor = prefs.edit().putString(
            "flutter.cn_call_ended_call_ids_v2",
            JSONArray(endedIds).toString()
        )
        // This is not the cold-start UI handoff.  It only clears a matching
        // Flutter-owned pending invite from an already-running app.
        val pending = prefs.getString("flutter.pending_incoming_call", null)
        val pendingId = try { JSONObject(pending ?: "{}").optString("call_id") } catch (_: Exception) { "" }
        if (pendingId == callId) editor.remove("flutter.pending_incoming_call")
        if (prefs.getString("flutter.cn_call_active_call_id", null) == callId) {
            editor.remove("flutter.cn_call_active_call_id")
            editor.remove("flutter.cn_call_active_call_at")
        }
        editor.apply()
    }

    private fun endedCallIds(prefs: android.content.SharedPreferences): List<String> {
        val encoded = prefs.getString("flutter.cn_call_ended_call_ids_v2", "[]")
        return try {
            val values = JSONArray(encoded ?: "[]")
            List(values.length()) { index -> values.optString(index).trim() }
                .filter { it.isNotEmpty() }
        } catch (_: Exception) {
            emptyList()
        }
    }

}
