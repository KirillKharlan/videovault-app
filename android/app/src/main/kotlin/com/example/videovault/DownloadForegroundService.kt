package com.example.videovault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground-сервис на время скачивания. Сам он ничего не качает — yt-dlp
 * работает внутри процесса приложения (YtDlpBridge). Задачи сервиса две:
 *  1. не дать системе убить процесс приложения, пока оно свёрнуто (иначе
 *     скачивание обрывалось, как только уходишь с экрана);
 *  2. PARTIAL_WAKE_LOCK — не дать CPU уснуть после блокировки экрана.
 * В уведомлении показывается прогресс и кнопка «Отменить».
 *
 * Управление: Intent с ACTION_START (запуск или обновление уведомления) и
 * Service.stopService() из DownloadServiceBridge.
 */
class DownloadForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "videovault_downloads"
        const val NOTIF_ID = 502

        const val ACTION_START = "com.videovault.dl.START"
        const val ACTION_CANCEL = "com.videovault.dl.CANCEL"

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PERCENT = "percent" // -1 = прогресс неизвестен

        /** Кнопка «Отменить» в уведомлении: MainActivity передаёт это во Flutter. */
        @Volatile
        var onCancelRequested: (() -> Unit)? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> onCancelRequested?.invoke()
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "VideoVault"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
                val percent = intent?.getIntExtra(EXTRA_PERCENT, -1) ?: -1
                val notification = buildNotification(title, text, percent)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                } else {
                    startForeground(NOTIF_ID, notification)
                }
                acquireWakeLock()
            }
        }
        // Не STICKY: если систему убила процесс, перезапускать сервис без
        // приложения нечему — само скачивание живёт внутри процесса.
        return START_NOT_STICKY
    }

    /** Приложение смахнули из недавних — скачивание всё равно умирает вместе с ним. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VideoVault:DownloadWakeLock")
        wl.setReferenceCounted(false)
        // Предохранитель: если release() по какой-то причине не вызовется,
        // лок не держится вечно.
        wl.acquire(6 * 60 * 60 * 1000L)
        wakeLock = wl
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun buildNotification(title: String, text: String, percent: Int): Notification {
        val openApp = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = PendingIntent.getActivity(
            this, 0, openApp,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val cancelIntent = Intent(this, DownloadForegroundService::class.java).setAction(ACTION_CANCEL)
        val cancelPending = PendingIntent.getService(
            this, 20, cancelIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Отменить", cancelPending)
        if (percent in 0..100) {
            builder.setProgress(100, percent, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Загрузки", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Прогресс скачивания видео"
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}
