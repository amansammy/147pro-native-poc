package com.pro147.poc

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Minimal foreground service that keeps the process alive (with camera|microphone
 * type) while streaming, so Android doesn't suspend the capture/encode when the app
 * is backgrounded mid-match. The camera + RTMP encode themselves live in
 * StreamerPlugin (RootEncoder GenericStream); this service only holds the
 * foreground promotion + ongoing notification.
 *
 * Started from StreamerPlugin.startStream, stopped from stopStream.
 */
class StreamingForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "pro147_streaming"
        private const val NOTIFICATION_ID = 1471

        fun start(context: Context) {
            val intent = Intent(context, StreamingForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, StreamingForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("147 Pro")
            .setContentText("Streaming live")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // If the system kills us, don't auto-restart — the plugin re-starts on the
        // next startStream.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Live streaming",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Shown while 147 Pro is streaming a match"
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }
}
