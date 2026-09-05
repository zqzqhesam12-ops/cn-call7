package com.example.mobile

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import android.content.Intent
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.app.NotificationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Hosts the Flutter-owned CN CALL UI; it never registers a Telecom call. */
class MainActivity : FlutterActivity() {
    private var defaultRingtone: Ringtone? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    companion object {
        const val ACTION_INCOMING_CALL = "com.example.mobile.action.INCOMING_CALL"
        private const val EVENTS_CHANNEL = "cn_call/telecom_events"
        private const val PREFERENCES = "FlutterSharedPreferences"
        private const val PENDING_CALL_KEY = "flutter.pending_incoming_call"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 9100)
        }
        persistIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (persistIncomingIntent(intent)) {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, EVENTS_CHANNEL)
                    .invokeMethod("incomingCall", incomingArguments(intent))
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Keep Core Telecom available strictly as a lifecycle/event bridge.
        // It never owns CN CALL's visual interface.
        CoreTelecomManager.register(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn_call/call")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "coreTelecomFlutterReady" -> {
                        CoreTelecomFlutterDispatcher.markFlutterReady(this, flutterEngine)
                        result.success(true)
                    }
                    "claimCoreTelecomAnswer" -> result.success(
                        CoreTelecomCallBridge.claimAnswerForUi(
                            this,
                            call.argument<String>("callId").orEmpty(),
                        ),
                    )
                    "disconnectTelecomCall" -> CoroutineScope(Dispatchers.Default).launch {
                        val callId = call.argument<String>("callId").orEmpty()
                        val force = call.argument<Boolean>("force") ?: false
                        result.success(CoreTelecomCallBridge.disconnectCall(callId, "ended", force))
                    }
                    "hasNativeRuntime" -> result.success(
                        CoreTelecomCallBridge.hasNativeRuntime(
                            call.argument<String>("callId").orEmpty(),
                        ),
                    )
                    "consumeCoreTelecomAnswer" -> result.success(
                        CoreTelecomCallBridge.consumeAnswerRequested(
                            this,
                            call.argument<String>("callId").orEmpty(),
                        ),
                    )
                    "clearCoreTelecomAnswer" -> result.success(
                        CoreTelecomCallBridge.clearAnswerRequested(
                            this,
                            call.argument<String>("callId").orEmpty(),
                        ),
                    )
                    "canUseFullScreenIntent" -> {
                        result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                                getSystemService(NotificationManager::class.java)
                                    ?.canUseFullScreenIntent() == true,
                        )
                    }
                    "openFullScreenIntentSettings" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            result.success(false)
                        } else {
                            try {
                                startActivity(
                                    Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                                        data = Uri.parse("package:$packageName")
                                    },
                                )
                                result.success(true)
                            } catch (_: ActivityNotFoundException) {
                                result.success(false)
                            }
                        }
                    }
                    "startActiveCallForegroundService" -> result.success(CoreTelecomForegroundService.start(this, call.argument<String>("callId").orEmpty()))
                    "configureCallAudio" -> {
                        stopDefaultRingtone()
                        releaseActivityAudioFocus()
                        result.success(true)
                    }
                    "prepareRingbackAudio" -> {
                          configureCallAudio(false)
                          result.success(true)
                      }
                      "playDefaultRingtone" -> {
                        playDefaultRingtone(call.argument<Boolean>("earpiece") == true)
                        result.success(true)
                    }
                    "stopDefaultRingtone" -> {
                        stopDefaultRingtone()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun configureCallAudio(speaker: Boolean) {
        val manager = getSystemService(AUDIO_SERVICE) as AudioManager
        audioManager = manager
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        manager.isSpeakerphoneOn = speaker
        val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .build()
        audioFocusRequest = focus
        manager.requestAudioFocus(focus)
    }

    private fun releaseActivityAudioFocus() {
        audioFocusRequest?.let { audioManager?.abandonAudioFocusRequest(it) }
        audioFocusRequest = null
    }

    private fun playDefaultRingtone(earpiece: Boolean) {
        stopDefaultRingtone()
        configureCallAudio(speaker = !earpiece)
        val uri = RingtoneManager.getActualDefaultRingtoneUri(
            this,
            RingtoneManager.TYPE_RINGTONE,
        ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        defaultRingtone = RingtoneManager.getRingtone(this, uri)
        defaultRingtone?.apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
            audioAttributes = AudioAttributes.Builder()
                .setUsage(
                    if (earpiece) AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING
                    else AudioAttributes.USAGE_NOTIFICATION_RINGTONE,
                )
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            play()
        }
    }

    private fun stopDefaultRingtone() {
        defaultRingtone?.stop()
        defaultRingtone = null
    }

    override fun onDestroy() {
        stopDefaultRingtone()
        audioFocusRequest?.let { audioManager?.abandonAudioFocusRequest(it) }
        audioManager?.mode = AudioManager.MODE_NORMAL
        super.onDestroy()
    }

    private fun persistIncomingIntent(intent: Intent?): Boolean {
        if (intent?.action != ACTION_INCOMING_CALL) return false
        val data = incomingArguments(intent)
        if (data["call_id"].isNullOrEmpty() || data["caller_id"].isNullOrEmpty()) {
            return false
        }
        getSharedPreferences(PREFERENCES, MODE_PRIVATE).edit()
            .putString(PENDING_CALL_KEY, JSONObject(data).toString())
            .apply()
        return true
    }

    private fun incomingArguments(intent: Intent): Map<String, String> = mapOf(
        "type" to "incoming_call",
        "call_id" to intent.getStringExtra("call_id").orEmpty(),
        "caller_id" to intent.getStringExtra("caller_id").orEmpty(),
        "caller_name" to intent.getStringExtra("caller_name").orEmpty(),
        "from_id" to intent.getStringExtra("caller_id").orEmpty(),
    )
}
