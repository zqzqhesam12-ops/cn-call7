package com.example.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Bundle
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** A dedicated Flutter host for CN CALL's custom incoming and active-call UI. */
class CNCallIncomingActivity : FlutterActivity() {
    private var ringtone: Ringtone? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    private val terminalReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val callId = intent.getStringExtra("call_id")
                ?: this@CNCallIncomingActivity.intent?.getStringExtra("call_id").orEmpty()
            println("[CN CALL][REJECT DIAGNOSTIC] terminalReceiver.onReceive call_id=$callId")
            println("[CN CALL][REJECT DIAGNOSTIC] before Activity.finish call_id=$callId")
            finishAndRemoveTask()
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 9200)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(terminalReceiver, IntentFilter(ACTION_TERMINAL), Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(terminalReceiver, IntentFilter(ACTION_TERMINAL))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onDestroy() {
        println("[CN CALL][REJECT DIAGNOSTIC] Activity.onDestroy call_id=${intent?.getStringExtra("call_id").orEmpty()}")
        ringtone?.stop()
        audioFocusRequest?.let { audioManager?.abandonAudioFocusRequest(it) }
        audioManager?.mode = AudioManager.MODE_NORMAL
        unregisterReceiver(terminalReceiver)
        super.onDestroy()
    }

    override fun onPause() {
        println("[CN CALL][REJECT DIAGNOSTIC] Activity.onPause call_id=${intent?.getStringExtra("call_id").orEmpty()}")
        super.onPause()
    }

    override fun onStop() {
        println("[CN CALL][REJECT DIAGNOSTIC] Activity.onStop call_id=${intent?.getStringExtra("call_id").orEmpty()}")
        super.onStop()
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "cn_call/call").setMethodCallHandler { call, result ->
            when (call.method) {
                "incomingCallBootstrap" -> {
                    val callId = intent?.getStringExtra("call_id")?.trim().orEmpty()
                    val callerId = intent?.getStringExtra("caller_id")?.trim().orEmpty()
                    val callerName = intent?.getStringExtra("caller_name")?.trim().orEmpty()
                    if (callId.isEmpty() || callerId.isEmpty()) {
                        result.error("missing_call_identity", "CN CALL incoming Activity has no call identity", null)
                    } else {
                        result.success(mapOf("callId" to callId, "callerId" to callerId, "callerName" to callerName))
                    }
                }
                "recordAudioPermissionGranted" -> result.success(hasRecordAudioPermission())
                "configureCallAudio" -> {
                    ringtone?.stop()
                    ringtone = null
                    releaseActivityAudioFocus()
                    result.success(true)
                }
                "playDefaultRingtone" -> {
                    ringtone?.stop()
                    val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    ringtone = RingtoneManager.getRingtone(this, uri)?.also { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.isLooping = true; it.play() }
                    result.success(true)
                }
                "stopDefaultRingtone" -> { ringtone?.stop(); ringtone = null; result.success(true) }
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

    override fun getDartEntrypointFunctionName(): String = "incomingCallUiMain"

    private fun hasRecordAudioPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
    }

    companion object { const val ACTION_TERMINAL = "com.example.mobile.CN_CALL_TERMINAL" }
}
