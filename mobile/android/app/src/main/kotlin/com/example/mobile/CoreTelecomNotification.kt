package com.example.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Notification helper for Core-Telecom.
 *
 * This is the single notification path for Core-Telecom calls.
 */
object CoreTelecomNotification {

    const val CHANNEL_ID = "cn_call_core_telecom_calls"


    fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager =
            context.getSystemService(NotificationManager::class.java)

        val channel = NotificationChannel(
            CHANNEL_ID,
            "CN CALL",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "CN CALL voice calls"
            setShowBadge(true)
        }

        manager.createNotificationChannel(channel)
    }

    fun showIncoming(
        context: Context,
        callId: String,
        callerName: String,
        callerId: String,
    ) {
        createChannel(context)

        val appContext = context.applicationContext

        val fullScreenIntent = PendingIntent.getActivity(
            appContext,
            requestCode(callId, 0),
            Intent(
                appContext,
                CNCallIncomingActivity::class.java,
            ).apply {
                putExtra("call_id", callId)
                putExtra("caller_id", callerId)
                putExtra("caller_name", callerName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            pendingIntentFlags(),
        )

        val answerIntent = PendingIntent.getBroadcast(
            appContext,
            requestCode(callId, 1),
            Intent(
                appContext,
                CoreTelecomActionReceiver::class.java,
            ).apply {
                action = CoreTelecomActionReceiver.ACTION_ANSWER
                putExtra(
                    CoreTelecomActionReceiver.EXTRA_CALL_ID,
                    callId,
                )
                putExtra(
                    CoreTelecomActionReceiver.EXTRA_PEER_ID,
                    callerId,
                )
                putExtra(
                    CoreTelecomActionReceiver.EXTRA_NAME,
                    callerName,
                )
            },
            pendingIntentFlags(),
        )

        val declineIntent = PendingIntent.getBroadcast(
            appContext,
            requestCode(callId, 2),
            Intent(
                appContext,
                CoreTelecomActionReceiver::class.java,
            ).apply {
                action = CoreTelecomActionReceiver.ACTION_REJECT
                putExtra(
                    CoreTelecomActionReceiver.EXTRA_CALL_ID,
                    callId,
                )
                putExtra(
                    CoreTelecomActionReceiver.EXTRA_PEER_ID,
                    callerId,
                )
                putExtra(
                    CoreTelecomActionReceiver.EXTRA_NAME,
                    callerName,
                )
            },
            pendingIntentFlags(),
        )

        val person =
            android.app.Person.Builder()
                .setName(callerName.ifBlank { callerId })
                .build()

        val builder = Notification.Builder(
            appContext,
            CHANNEL_ID,
        )
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentTitle(callerName.ifBlank { callerId })
            .setContentText("مكالمة واردة عبر CN CALL")
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(fullScreenIntent)

        // Android 14+ lets users revoke full-screen intent capability even
        // when USE_FULL_SCREEN_INTENT is declared.  Keep the same CN CALL
        // notification/content intent as the fallback; never route to the
        // phone UI or MainActivity.
        val canUseFullScreen =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                appContext.getSystemService(NotificationManager::class.java)
                    .canUseFullScreenIntent()
        if (canUseFullScreen) {
            builder.setFullScreenIntent(fullScreenIntent, true)
        } else {
            println("[CN CALL][FULLSCREEN] unavailable; showing CN CALL heads-up notification call_id=$callId")
        }

        // Attach native CallStyle Answer/Decline actions.  They are broadcast
        // only and never launch an Activity; the Full-Screen Intent above stays
        // the sole CNCallIncomingActivity entry.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(
                Notification.CallStyle.forIncomingCall(
                    person,
                    declineIntent,
                    answerIntent,
                ),
            )
        }

        appContext
            .getSystemService(NotificationManager::class.java)
            .notify(
                notificationId(callId, 1),
                builder.build(),
            )

        println(
            "[CN CALL][CORE TELECOM] INCOMING FULLSCREEN UI SHOWN " +
                "call_id=$callId"
        )
    }

    fun showOngoing(
        context: Context,
        callId: String,
        peerId: String,
        remoteName: String,
    ) {
        createChannel(context)

        val appContext = context.applicationContext

        val hangupIntent = PendingIntent.getBroadcast(
            appContext,
            requestCode(callId, 3),
            Intent(
                appContext,
                CoreTelecomActionReceiver::class.java,
            ).apply {
                action = CoreTelecomActionReceiver.ACTION_DISCONNECT
                putExtra(CoreTelecomActionReceiver.EXTRA_CALL_ID, callId)
                putExtra(
                    CoreTelecomActionReceiver.EXTRA_PEER_ID,
                    peerId,
                )
            },
            pendingIntentFlags(),
        )

        val builder = Notification.Builder(
            appContext,
            CHANNEL_ID,
        )
            .setSmallIcon(android.R.drawable.sym_call_outgoing)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)

        builder.addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "إنهاء", hangupIntent).build())

        appContext
            .getSystemService(NotificationManager::class.java)
            .notify(
                notificationId(callId, 2),
                builder.build(),
            )

        println(
            "[CN CALL][CORE TELECOM] ONGOING NOTIFICATION SHOWN " +
                "call_id=$callId"
        )
    }

    fun cancelIncoming(
        context: Context,
        callId: String,
    ) {
        context.applicationContext
            .getSystemService(NotificationManager::class.java)
            .cancel(notificationId(callId, 1))
    }

    fun cancelOngoing(
        context: Context,
        callId: String,
    ) {
        context.applicationContext
            .getSystemService(NotificationManager::class.java)
            .cancel(notificationId(callId, 2))
    }

    fun cancelForCall(context: Context, callId: String) {
        cancelIncoming(context, callId)
        cancelOngoing(context, callId)
    }

    fun cancelAll(context: Context) {
        val manager =
            context.applicationContext
                .getSystemService(NotificationManager::class.java)

        /*
         * Notification IDs are per-call, so there is no single global
         * incoming/ongoing notification ID to cancel safely.
         */
    }

    private fun notificationId(
        callId: String,
        type: Int,
    ): Int {
        var value = callId.hashCode() and 0x7fffffff
        value = (value % 1000000) * 10 + type
        return value
    }

    fun ongoingNotificationId(callId: String): Int = notificationId(callId, 2)

    private fun requestCode(
        callId: String,
        action: Int,
    ): Int {
        var value = callId.hashCode() and 0x7fffffff
        value = (value % 100000) * 10 + action
        return value
    }

    private fun pendingIntentFlags(): Int {
        return PendingIntent.FLAG_UPDATE_CURRENT or
            PendingIntent.FLAG_IMMUTABLE
    }
}
