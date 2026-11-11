package top.yunov.clipkeep

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
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/// 下载前台服务：保持进程优先级，并在通知栏展示进度/完成状态。
class DownloadService : Service() {
    companion object {
        const val ACTION_START = "top.yunov.clipkeep.download.START"
        const val ACTION_UPDATE = "top.yunov.clipkeep.download.UPDATE"
        const val ACTION_COMPLETE = "top.yunov.clipkeep.download.COMPLETE"
        const val ACTION_STOP = "top.yunov.clipkeep.download.STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_INDETERMINATE = "indeterminate"

        private const val CHANNEL_ID = "clipkeep_downloads"
        private const val NOTIFICATION_ID = 1001

        fun start(
            context: Context,
            action: String,
            title: String,
            text: String,
            progress: Int,
            indeterminate: Boolean,
        ) {
            val intent = Intent(context, DownloadService::class.java).apply {
                this.action = action
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_INDETERMINATE, indeterminate)
            }
            ContextCompat.startForegroundService(context, intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        createChannel()
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "ClipKeep"
        val text = intent.getStringExtra(EXTRA_TEXT) ?: "正在下载…"
        val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
        val indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, false)

        when (action) {
            ACTION_START, ACTION_UPDATE -> {
                val notification = buildNotification(
                    title = title,
                    text = text,
                    progress = progress,
                    indeterminate = indeterminate,
                    ongoing = true,
                )
                startForegroundCompat(notification)
                if (action == ACTION_UPDATE) {
                    notificationManager().notify(NOTIFICATION_ID, notification)
                }
                return START_STICKY
            }
            ACTION_COMPLETE -> {
                val notification = buildNotification(
                    title = title,
                    text = text,
                    progress = 100,
                    indeterminate = false,
                    ongoing = false,
                )
                startForegroundCompat(notification)
                stopForegroundCompat(removeNotification = false)
                notificationManager().notify(NOTIFICATION_ID, notification)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                // startForegroundService 启动后必须先 startForeground，否则系统会报
                // “did not then call startForeground”；随即移除通知并停止。
                startForegroundCompat(
                    buildNotification(
                        title = title,
                        text = text,
                        progress = 0,
                        indeterminate = true,
                        ongoing = true,
                    ),
                )
                stopForegroundCompat(removeNotification = true)
                notificationManager().cancel(NOTIFICATION_ID)
                stopSelf()
                return START_NOT_STICKY
            }
        }
        stopSelf()
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat(removeNotification: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(
                if (removeNotification) {
                    Service.STOP_FOREGROUND_REMOVE
                } else {
                    Service.STOP_FOREGROUND_DETACH
                },
            )
        } else {
            @Suppress("DEPRECATION")
            stopForeground(removeNotification)
        }
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Int,
        indeterminate: Boolean,
        ongoing: Boolean,
    ): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, progress.coerceIn(0, 100), indeterminate)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = notificationManager()
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "下载任务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "下载进度与完成提醒"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
