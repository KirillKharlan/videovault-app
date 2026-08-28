package com.example.videovault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/// Foreground-сервис + PowerManager wake lock. Сам он звук НЕ проигрывает —
/// реальное воспроизведение по-прежнему делает video_player (ExoPlayer)
/// внутри Flutter. Но у него ДВЕ задачи, а не одна:
///  1. Foreground-сервис не даёт системе убить сам ПРОЦЕСС приложения.
///  2. PARTIAL_WAKE_LOCK не даёт системе усыпить CPU после выключения
///     экрана — без него декодирование звука останавливается через
///     несколько секунд после блокировки телефона, ДАЖЕ если foreground-
///     сервис жив (foreground-сервис защищает процесс, а не CPU).
class BackgroundPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "videovault_playback"
        const val NOTIF_ID = 501

        const val ACTION_START = "com.videovault.bg.START"
        const val ACTION_STOP = "com.videovault.bg.STOP"
        const val ACTION_UPDATE = "com.videovault.bg.UPDATE"

        const val EXTRA_TITLE = "title"
        const val EXTRA_IS_PLAYING = "isPlaying"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "VideoVault"
                val isPlaying = intent?.getBooleanExtra(EXTRA_IS_PLAYING, true) ?: true
                startForeground(NOTIF_ID, buildNotification(title, isPlaying))
                acquireWakeLock()
            }
        }
        return START_STICKY
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val wl = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK, "VideoVault:BackgroundPlaybackWakeLock"
        )
        wl.setReferenceCounted(false)
        // Предохранитель на 12 часов — если по какой-то причине release() не
        // вызовется (например, процесс убит системой напрямую), лок не
        // держится вечно и не сажает батарею навсегда.
        wl.acquire(12 * 60 * 60 * 1000L)
        wakeLock = wl
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun buildNotification(title: String, isPlaying: Boolean): Notification {
        val openAppIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentPendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val playPauseIntent = Intent(MainActivity.ACTION_PLAY_PAUSE_BROADCAST).setPackage(packageName)
        val playPausePending = PendingIntent.getBroadcast(
            this, 10, playPauseIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val nextIntent = Intent(MainActivity.ACTION_SKIP_NEXT_BROADCAST).setPackage(packageName)
        val nextPending = PendingIntent.getBroadcast(
            this, 11, nextIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Кнопка Stop шлёт broadcast, который слушает MainActivity — она и
        // сообщит Flutter остановить воспроизведение, и остановит сам сервис
        // (см. ACTION_STOP_BROADCAST в MainActivity). Так гарантируется что
        // звук реально прекратится, а не просто пропадёт уведомление.
        val stopIntent = Intent(MainActivity.ACTION_STOP_BROADCAST).setPackage(packageName)
        val stopPending = PendingIntent.getBroadcast(
            this, 12, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val playPauseIcon = if (isPlaying) R.drawable.ic_pip_pause else R.drawable.ic_pip_play
        val playPauseLabel = if (isPlaying) "Pause" else "Play"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText("VideoVault — играет в фоне")
            .setSmallIcon(R.drawable.ic_pip_play)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .addAction(playPauseIcon, playPauseLabel, playPausePending)
            .addAction(R.drawable.ic_pip_skip_next, "Next", nextPending)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPending)
            .build()
    }

    fun updateNotification(title: String, isPlaying: Boolean) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(title, isPlaying))
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Воспроизведение видео",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Уведомление о фоновом воспроизведении звука"
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
