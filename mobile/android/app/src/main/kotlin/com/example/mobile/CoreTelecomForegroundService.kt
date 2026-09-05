package com.example.mobile

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Build
import android.app.ForegroundServiceStartNotAllowedException
import android.content.pm.ServiceInfo
import androidx.core.app.ServiceCompat

/** Execution support only for an active Core-Telecom call; it owns no call state. */
class CoreTelecomForegroundService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        CoreTelecomNotification.createChannel(applicationContext)
        val callId = intent?.getStringExtra(EXTRA_CALL_ID).orEmpty()
        val notification = Notification.Builder(this, CoreTelecomNotification.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_call_outgoing)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setContentTitle("CN CALL")
            .setContentText("مكالمة جارية")
            .build()
        try {
            val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else 0
            ServiceCompat.startForeground(this, CoreTelecomNotification.ongoingNotificationId(callId), notification, types)
            } catch (error: SecurityException) {
                println("[CN CALL][FGS] promotion denied call_id=$callId error=$error")
                stopSelf()
            } catch (error: ForegroundServiceStartNotAllowedException) {
                println("[CN CALL][FGS] background start not allowed call_id=$callId error=$error")
                stopSelf()
            } catch (error: IllegalArgumentException) {
            println("[CN CALL][FGS] invalid type/notification call_id=$callId error=$error")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val EXTRA_CALL_ID = "call_id"
        fun start(context: Context, callId: String): Boolean {
            val intent = Intent(context, CoreTelecomForegroundService::class.java)
                .putExtra(EXTRA_CALL_ID, callId)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
                true
            } catch (error: RuntimeException) {
                println("[CN CALL][FGS] start denied call_id=$callId error=$error")
                false
            }
        }
        fun stop(context: Context) = context.stopService(Intent(context, CoreTelecomForegroundService::class.java))
    }
}
