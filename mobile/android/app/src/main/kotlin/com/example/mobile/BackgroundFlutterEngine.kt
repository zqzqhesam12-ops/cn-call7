package com.example.mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference

/** Owns the headless Core-Telecom bridge engine; it is never MainActivity's engine. */
object BackgroundFlutterEngine {
    const val ENGINE_ID = "cn_call_telecom_background_engine"
    private const val CALL_CHANNEL = "cn_call/call"

    @Synchronized
    fun ensureStarted(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val appContext = context.applicationContext
        fun startEngine(): FlutterEngine {
            val engine = FlutterEngine(appContext)
            GeneratedPluginRegistrant.registerWith(engine)
            MethodChannel(engine.dartExecutor.binaryMessenger, CALL_CHANNEL).setMethodCallHandler { call, result ->
                val callId = call.argument<String>("callId").orEmpty().trim()
                when (call.method) {
                    "disconnectTelecomCall" -> CoroutineScope(Dispatchers.Default).launch {
                        val force = call.argument<Boolean>("force") ?: false
                        result.success(CoreTelecomCallBridge.disconnectCall(callId, "ended", force))
                    }
                    "failTelecomCall" -> CoroutineScope(Dispatchers.Default).launch {
                        result.success(CoreTelecomCallBridge.disconnectCall(callId, "failed", true))
                    }
                    "activateTelecomCall" -> CoroutineScope(Dispatchers.Default).launch {
                        result.success(CoreTelecomCallBridge.activateCall(callId))
                    }
                    "consumeCoreTelecomAnswer" -> result.success(
                        CoreTelecomCallBridge.consumeAnswerRequested(
                            appContext,
                            callId,
                        ),
                    )
                    "hasNativeRuntime" -> result.success(
                        CoreTelecomCallBridge.hasNativeRuntime(callId),
                    )
                    "startActiveCallForegroundService" -> result.success(
                        CoreTelecomForegroundService.start(
                            appContext,
                            callId,
                        ),
                    )
                    "coreTelecomFlutterReady" -> {
                        CoreTelecomFlutterDispatcher.markFlutterReady(appContext, engine)
                        result.success(true)
                    }
                    "clearCoreTelecomAnswer" -> result.success(
                        CoreTelecomCallBridge.clearAnswerRequested(
                            appContext,
                            callId,
                        ),
                    )
                    else -> result.notImplemented()
                }
            }
            cache.put(ENGINE_ID, engine)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint("flutter_assets", "package:mobile/main.dart", "telecomBackgroundMain"))
            return engine
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return startEngine()
        }
        val engine = AtomicReference<FlutterEngine?>()
        val failure = AtomicReference<Throwable?>()
        val completed = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            try {
                engine.set(startEngine())
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                completed.countDown()
            }
        }
        try {
            completed.await()
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            throw RuntimeException("Interrupted while starting background Flutter engine", interrupted)
        }
        failure.get()?.let { throw it }
        return engine.get()
            ?: throw IllegalStateException("Background Flutter engine startup completed without an engine")
    }
}
