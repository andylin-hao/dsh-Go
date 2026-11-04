package io.github.ccch1mneyyy.dsh_app.phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings

/**
 * Keeps the process, and with it Dart's dsh-go-link connections to computers, up while any
 * computer may use the phone (docs/design/remote-agents.md). Without it Android freezes the app in
 * the background (seen on a vivo with Android 16 within seconds): the link stops answering and the
 * agent's call fails. With the local engine running DshService does this too; this one covers
 * phones that only link with computers. Not sticky: without Dart there is no link to keep.
 */
class PhoneLinkService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        val n = notification(this)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            running = true
        } catch (e: Exception) {
            Log.w("DshPhoneLink", "link service could not go foreground", e)
            running = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "dsh-phone-link"
        private const val NOTIFICATION_ID = 3091

        @Volatile var running = false
            private set

        /** Starts or stops the service to match [on]; does nothing when it already matches. */
        fun ensure(context: Context, on: Boolean): Boolean {
            if (on == running) return running
            try {
                if (on) {
                    context.startForegroundService(Intent(context, PhoneLinkService::class.java))
                    running = true
                } else {
                    context.stopService(Intent(context, PhoneLinkService::class.java))
                    running = false
                }
            } catch (e: Exception) {
                // Background start refused (a vendor policy): the link still works while the app is open.
                Log.w("DshPhoneLink", "link service ${if (on) "start" else "stop"} refused", e)
                running = false
            }
            return running
        }

        private fun ensureChannel(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, AppStrings.get(context, R.string.phone_link_channel), NotificationManager.IMPORTANCE_MIN).apply {
                    setShowBadge(false)
                },
            )
        }

        private fun notification(context: Context): Notification {
            val open = PendingIntent.getActivity(
                context, NOTIFICATION_ID,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(AppStrings.APP_NAME)
                .setContentText(AppStrings.get(context, R.string.phone_link_running))
                .setOngoing(true)
                .setContentIntent(open)
                .build()
        }
    }
}
