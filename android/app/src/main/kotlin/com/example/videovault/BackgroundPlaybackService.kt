package com.example.videovault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat

/// Foreground-сервис + PowerManager wake lock + MediaSession. Сам он звук НЕ
/// проигрывает — реальное воспроизведение делают video_player/just_audio внутри
/// Flutter. Задачи сервиса:
///  1. Foreground-сервис не даёт системе убить сам ПРОЦЕСС приложения.
///  2. PARTIAL_WAKE_LOCK не даёт системе усыпить CPU после выключения экрана.
///  3. MediaSession: уведомление в стиле медиаплеера с обложкой и кнопками
///     «предыдущее / пауза / следующее / стоп», управление с экрана блокировки
///     и кнопками наушников/Bluetooth. Все нажатия уходят тем же путём, что и
///     раньше: broadcast -> MainActivity -> Flutter (PlaybackManager).
class BackgroundPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "videovault_playback"
        const val NOTIF_ID = 501

        const val ACTION_START = "com.videovault.bg.START"
        const val ACTION_STOP = "com.videovault.bg.STOP"
        const val ACTION_UPDATE = "com.videovault.bg.UPDATE"

        const val EXTRA_TITLE = "title"
        const val EXTRA_IS_PLAYING = "isPlaying"
        const val EXTRA_ART_PATH = "artPath"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var session: MediaSessionCompat? = null

    @Volatile
    private var isPlayingState = true

    // Обложку декодируем один раз на файл (уведомление обновляется часто).
    private var artPath: String? = null
    private var artBitmap: Bitmap? = null

    private val sessionCallback = object : MediaSessionCompat.Callback() {
        // Для Flutter «пауза/плей» — один переключатель, поэтому сверяемся с
        // текущим состоянием: «пауза» на уже поставленном на паузу видео не должна
        // его запускать.
        override fun onPlay() { if (!isPlayingState) send(MainActivity.ACTION_PLAY_PAUSE_BROADCAST) }
        override fun onPause() { if (isPlayingState) send(MainActivity.ACTION_PLAY_PAUSE_BROADCAST) }
        override fun onSkipToNext() = send(MainActivity.ACTION_SKIP_NEXT_BROADCAST)
        override fun onSkipToPrevious() = send(MainActivity.ACTION_SKIP_PREV_BROADCAST)
        override fun onStop() = send(MainActivity.ACTION_STOP_BROADCAST)
    }

    private fun send(action: String) {
        sendBroadcast(Intent(action).setPackage(packageName))
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        session = MediaSessionCompat(this, "VideoVaultBackground").apply {
            setCallback(sessionCallback)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseWakeLock()
                session?.isActive = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "VideoVault"
                val isPlaying = intent?.getBooleanExtra(EXTRA_IS_PLAYING, true) ?: true
                val art = loadArt(intent?.getStringExtra(EXTRA_ART_PATH))
                isPlayingState = isPlaying
                updateSession(title, isPlaying, art)
                startForeground(NOTIF_ID, buildNotification(title, isPlaying, art))
                acquireWakeLock()
            }
        }
        return START_STICKY
    }

    private fun updateSession(title: String, isPlaying: Boolean, art: Bitmap?) {
        val s = session ?: return
        val meta = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "VideoVault")
            .apply { if (art != null) putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, art) }
            .build()
        s.setMetadata(meta)
        val actions = PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or PlaybackStateCompat.ACTION_STOP
        s.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                    if (isPlaying) 1f else 0f
                )
                .build()
        )
        s.isActive = true
    }

    /** Обложка из файла, уменьшенная до ~600 px (не тащим в уведомление огромные картинки). */
    private fun loadArt(path: String?): Bitmap? {
        if (path.isNullOrEmpty()) return null
        if (path == artPath && artBitmap != null) return artBitmap
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / sample > 600 || bounds.outHeight / sample > 600) sample *= 2
            val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            artPath = path
            artBitmap = bitmap
            bitmap
        } catch (e: Throwable) {
            null
        }
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
        session?.isActive = false
        session?.release()
        session = null
        super.onDestroy()
    }

    private fun action(requestCode: Int, broadcast: String): PendingIntent =
        PendingIntent.getBroadcast(
            this, requestCode, Intent(broadcast).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

    private fun buildNotification(title: String, isPlaying: Boolean, art: Bitmap?): Notification {
        val openAppIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentPendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val playPauseIcon = if (isPlaying) R.drawable.ic_pip_pause else R.drawable.ic_pip_play
        val playPauseLabel = if (isPlaying) "Pause" else "Play"

        val style = androidx.media.app.NotificationCompat.MediaStyle()
            .setShowActionsInCompactView(0, 1, 2)
        session?.let { style.setMediaSession(it.sessionToken) }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText("VideoVault — играет в фоне")
            .setSmallIcon(R.drawable.ic_pip_play)
            .setLargeIcon(art)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(R.drawable.ic_pip_skip_previous, "Previous",
                action(13, MainActivity.ACTION_SKIP_PREV_BROADCAST))
            .addAction(playPauseIcon, playPauseLabel,
                action(10, MainActivity.ACTION_PLAY_PAUSE_BROADCAST))
            .addAction(R.drawable.ic_pip_skip_next, "Next",
                action(11, MainActivity.ACTION_SKIP_NEXT_BROADCAST))
            // Кнопка Stop шлёт broadcast, который слушает MainActivity — она и
            // сообщит Flutter остановить воспроизведение, и остановит сам сервис
            // (см. ACTION_STOP_BROADCAST в MainActivity).
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop",
                action(12, MainActivity.ACTION_STOP_BROADCAST))
            .setStyle(style)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Воспроизведение видео",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Уведомление о фоновом воспроизведении звука"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
