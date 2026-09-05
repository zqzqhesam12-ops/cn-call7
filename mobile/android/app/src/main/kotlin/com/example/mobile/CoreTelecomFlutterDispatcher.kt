package com.example.mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference

/**
 * Core-Telecom -> Flutter dispatcher.
 *
 * Does not know anything about FCM, LiveKit, or the legacy Telecom path.
 *
 * If Flutter is already alive:
 *   dispatch immediately.
 *
 * If Flutter is cold:
 *   persist the event for telecomBackgroundMain().
 */
object CoreTelecomFlutterDispatcher {

    private const val ENGINE_ID = BackgroundFlutterEngine.ENGINE_ID

    private const val EVENTS_CHANNEL =
        "cn_call/telecom_events"

    private const val QUEUE_KEY =
        "flutter.cn_call_core_telecom_flutter_events_v1"

    private const val MAX_QUEUE_SIZE = 64

    private val flutterReady =
        AtomicBoolean(false)

    /*
     * SharedPreferences does not provide an atomic read/modify/write
     * transaction. All Core-Telecom event queue mutations therefore use
     * one process-local lock.
     */
    private val queueLock = Any()

    fun dispatch(
        context: Context,
        action: String,
        callId: String,
        peerId: String,
        name: String = "",
    ) {
        val id = callId.trim()
        val peer = peerId.trim()
        val safeAction = action.trim()

        if (safeAction.isEmpty() || id.isEmpty()) {
            println(
                "[CN CALL][CORE TELECOM] " +
                    "Flutter event rejected: missing identity"
            )
            return
        }

        val event = JSONObject().apply {
            put("action", safeAction)
            put("callId", id)
            put("peerId", peer)
            put("name", name.trim())
            put("at", System.currentTimeMillis())
        }

        val engine =
            FlutterEngineCache
                .getInstance()
                .get(ENGINE_ID)

        /*
         * Never send directly to an engine whose Dart handler has not
         * announced readiness. Persist first so cold-start events survive.
         */
        if (engine != null && flutterReady.get()) {
            send(engine, event)
            return
        }

        persist(context, event)

        println(
            "[CN CALL][CORE TELECOM] " +
                "Flutter event queued " +
                "action=$safeAction call_id=$id"
        )

        BackgroundFlutterEngine.ensureStarted(context)
    }

    fun markFlutterReady(
        context: Context,
        engine: FlutterEngine,
    ) {
        flutterReady.set(true)

        println(
            "[CN CALL][CORE TELECOM] " +
                "FLUTTER READY"
        )

        drain(
            context,
            engine,
        )
    }

    fun markFlutterNotReady() {
        flutterReady.set(false)
    }

    fun drain(
        context: Context,
        engine: FlutterEngine,
    ) {
        synchronized(queueLock) {
            drainLocked(context, engine)
        }
    }

    private fun drainLocked(
        context: Context,
        engine: FlutterEngine,
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
                        QUEUE_KEY,
                        "[]",
                    ),
                )
            } catch (_: Exception) {
                JSONArray()
            }

        if (queue.length() == 0) {
            return
        }

        for (index in 0 until queue.length()) {
            val event =
                queue.optJSONObject(index)
                    ?: continue

            send(engine, event)
        }

        prefs.edit()
            .remove(QUEUE_KEY)
            .apply()

        println(
            "[CN CALL][CORE TELECOM] " +
                "Flutter event queue drained"
        )
    }

    private fun send(
        engine: FlutterEngine,
        event: JSONObject,
    ) {
        val arguments =
            mapOf(
                "action" to event.optString("action"),
                "callId" to event.optString("callId"),
                "peerId" to event.optString("peerId"),
                "name" to event.optString("name"),
            )

        val invoke = {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                EVENTS_CHANNEL,
            ).invokeMethod(
                "coreTelecomAction",
                arguments,
            )
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            invoke()
            return
        }

        val completed = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>(null)
        val posted = Handler(Looper.getMainLooper()).post {
            try {
                invoke()
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                completed.countDown()
            }
        }

        if (!posted) {
            throw IllegalStateException("Unable to schedule Core Telecom Flutter event")
        }

        completed.await()
        failure.get()?.let { throw it }
    }

    private fun persist(
        context: Context,
        event: JSONObject,
    ) {
        synchronized(queueLock) {
            persistLocked(context, event)
        }
    }

    private fun persistLocked(
        context: Context,
        event: JSONObject,
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
                        QUEUE_KEY,
                        "[]",
                    ),
                )
            } catch (_: Exception) {
                JSONArray()
            }

        /*
         * Do not queue the exact same event twice.
         */
        for (index in 0 until queue.length()) {
            val existing =
                queue.optJSONObject(index)
                    ?: continue

            if (
                existing.optString("action") ==
                    event.optString("action") &&
                existing.optString("callId") ==
                    event.optString("callId")
            ) {
                return
            }
        }

        queue.put(event)

        while (queue.length() > MAX_QUEUE_SIZE) {
            queue.remove(0)
        }

        prefs.edit()
            .putString(
                QUEUE_KEY,
                queue.toString(),
            )
            .apply()
    }
}
