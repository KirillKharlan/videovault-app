package com.example.videovault

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {

    companion object {
        // Публичные строки действий — используются и здесь (для системного
        // PiP Actions), и в BackgroundPlaybackService (для кнопок в
        // уведомлении фонового воспроизведения). Один и тот же
        // BroadcastReceiver ниже обрабатывает оба источника одинаково.
        const val ACTION_PLAY_PAUSE_BROADCAST = "com.videovault.ACTION_PLAY_PAUSE"
        const val ACTION_SKIP_NEXT_BROADCAST = "com.videovault.ACTION_SKIP_NEXT"
        const val ACTION_FORWARD_10_BROADCAST = "com.videovault.ACTION_FORWARD_10"
        const val ACTION_STOP_BROADCAST = "com.videovault.ACTION_STOP"

        const val REQUEST_CODE_SAVE_FILE = 4201
    }

    private val CHANNEL = "com.videovault/pip"
    private var pipChannel: MethodChannel? = null

    // Ожидающее сохранение файла через системный SAF-диалог "Сохранить как".
    // ACTION_CREATE_DOCUMENT асинхронный (результат приходит в
    // onActivityResult), поэтому Result от MethodChannel держим здесь, пока
    // не придёт ответ от системы.
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null

    private var shouldAutoEnterPip = false
    private var pipAspectNumerator = 16
    private var pipAspectDenominator = 9

    private var currentIsPlaying = true
    private var currentHasNext = false
    private var currentTitle = "VideoVault"

    private var receiverRegistered = false
    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_PLAY_PAUSE_BROADCAST -> pipChannel?.invokeMethod("pipAction_playPause", null)
                ACTION_SKIP_NEXT_BROADCAST -> pipChannel?.invokeMethod("pipAction_skipNext", null)
                ACTION_FORWARD_10_BROADCAST -> pipChannel?.invokeMethod("pipAction_forward10", null)
                ACTION_STOP_BROADCAST -> {
                    pipChannel?.invokeMethod("pipAction_stop", null)
                    val stopIntent = Intent(this@MainActivity, BackgroundPlaybackService::class.java)
                        .setAction(BackgroundPlaybackService.ACTION_STOP)
                    startService(stopIntent)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(ACTION_PLAY_PAUSE_BROADCAST)
                addAction(ACTION_SKIP_NEXT_BROADCAST)
                addAction(ACTION_FORWARD_10_BROADCAST)
                addAction(ACTION_STOP_BROADCAST)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(actionReceiver, filter)
            }
            receiverRegistered = true
        }

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipSupported" -> {
                    val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                    result.success(supported)
                }
                "setAutoEnter" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val aspectNum = call.argument<Int>("aspectNumerator") ?: 16
                    val aspectDen = call.argument<Int>("aspectDenominator") ?: 9
                    shouldAutoEnterPip = enabled
                    pipAspectNumerator = aspectNum.coerceAtLeast(1)
                    pipAspectDenominator = aspectDen.coerceAtLeast(1)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        updatePipParams(autoEnter = enabled)
                    }
                    result.success(null)
                }
                "enterPip" -> {
                    val aspectNum = (call.argument<Int>("aspectNumerator") ?: pipAspectNumerator).coerceAtLeast(1)
                    val aspectDen = (call.argument<Int>("aspectDenominator") ?: pipAspectDenominator).coerceAtLeast(1)
                    enterPipNow(aspectNum, aspectDen)
                    result.success(null)
                }
                "updatePipState" -> {
                    currentIsPlaying = call.argument<Boolean>("isPlaying") ?: currentIsPlaying
                    currentHasNext = call.argument<Boolean>("hasNext") ?: currentHasNext
                    call.argument<String>("title")?.let { currentTitle = it }
                    val aspectNum = call.argument<Int>("aspectNumerator")
                    val aspectDen = call.argument<Int>("aspectDenominator")
                    if (aspectNum != null && aspectDen != null) {
                        pipAspectNumerator = aspectNum.coerceAtLeast(1)
                        pipAspectDenominator = aspectDen.coerceAtLeast(1)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode) {
                        try {
                            setPictureInPictureParams(
                                PictureInPictureParams.Builder()
                                    .setActions(buildPipActions())
                                    // Форма уже открытого PiP-окна должна следовать за
                                    // соотношением сторон ТЕКУЩЕГО видео — иначе при
                                    // автопереходе с вертикального видео на горизонтальное
                                    // (и наоборот) окно остаётся в старой форме.
                                    .setAspectRatio(Rational(pipAspectNumerator, pipAspectDenominator))
                                    .build()
                            )
                        } catch (e: Exception) { /* игнорируем */ }
                    }
                    result.success(null)
                }
                "startBackgroundService" -> {
                    currentTitle = call.argument<String>("title") ?: currentTitle
                    currentIsPlaying = call.argument<Boolean>("isPlaying") ?: true
                    val intent = Intent(this, BackgroundPlaybackService::class.java).apply {
                        putExtra(BackgroundPlaybackService.EXTRA_TITLE, currentTitle)
                        putExtra(BackgroundPlaybackService.EXTRA_IS_PLAYING, currentIsPlaying)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stopBackgroundService" -> {
                    val intent = Intent(this, BackgroundPlaybackService::class.java)
                        .setAction(BackgroundPlaybackService.ACTION_STOP)
                    startService(intent)
                    result.success(null)
                }
                "updateBackgroundNotification" -> {
                    currentTitle = call.argument<String>("title") ?: currentTitle
                    currentIsPlaying = call.argument<Boolean>("isPlaying") ?: currentIsPlaying
                    val intent = Intent(this, BackgroundPlaybackService::class.java).apply {
                        putExtra(BackgroundPlaybackService.EXTRA_TITLE, currentTitle)
                        putExtra(BackgroundPlaybackService.EXTRA_IS_PLAYING, currentIsPlaying)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "saveFileWithPicker" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val suggestedName = call.argument<String>("suggestedName") ?: "file"
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                    if (sourcePath == null || !File(sourcePath).exists()) {
                        result.error("NO_SOURCE", "Исходный файл не найден", null)
                    } else if (pendingSaveResult != null) {
                        // Уже есть незавершённое сохранение — не даём запустить второе.
                        result.error("BUSY", "Уже открыт диалог сохранения", null)
                    } else {
                        pendingSaveResult = result
                        pendingSaveSourcePath = sourcePath
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mimeType
                            putExtra(Intent.EXTRA_TITLE, suggestedName)
                        }
                        try {
                            startActivityForResult(intent, REQUEST_CODE_SAVE_FILE)
                        } catch (e: Exception) {
                            pendingSaveResult = null
                            pendingSaveSourcePath = null
                            result.error("NO_PICKER", "Не удалось открыть системный диалог: ${e.message}", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun buildPipActions(): ArrayList<RemoteAction> {
        val actions = ArrayList<RemoteAction>()

        val playPauseIcon = if (currentIsPlaying) R.drawable.ic_pip_pause else R.drawable.ic_pip_play
        val playPauseTitle = if (currentIsPlaying) "Pause" else "Play"
        actions.add(RemoteAction(
            Icon.createWithResource(this, playPauseIcon), playPauseTitle, playPauseTitle,
            PendingIntent.getBroadcast(
                this, 1, Intent(ACTION_PLAY_PAUSE_BROADCAST).setPackage(packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        ))

        if (currentHasNext) {
            actions.add(RemoteAction(
                Icon.createWithResource(this, R.drawable.ic_pip_skip_next), "Next", "Next video",
                PendingIntent.getBroadcast(
                    this, 3, Intent(ACTION_SKIP_NEXT_BROADCAST).setPackage(packageName),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            ))
        }

        return actions
    }

    private fun updatePipParams(autoEnter: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val builder = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(pipAspectNumerator, pipAspectDenominator))
                .setActions(buildPipActions())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(autoEnter)
            }
            setPictureInPictureParams(builder.build())
        } catch (e: Exception) { /* игнорируем */ }
    }

    private fun enterPipNow(aspectNum: Int, aspectDen: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(aspectNum, aspectDen))
                .setActions(buildPipActions())
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) { /* устройство не поддерживает PiP */ }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            if (shouldAutoEnterPip) {
                enterPipNow(pipAspectNumerator, pipAspectDenominator)
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }

    override fun onDestroy() {
        if (receiverRegistered) {
            try { unregisterReceiver(actionReceiver) } catch (e: Exception) { }
            receiverRegistered = false
        }
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE_SAVE_FILE) return

        val pendingResult = pendingSaveResult
        val sourcePath = pendingSaveSourcePath
        pendingSaveResult = null
        pendingSaveSourcePath = null

        if (pendingResult == null) return // отменён/дубль — нечего завершать

        val destUri: Uri? = if (resultCode == RESULT_OK) data?.data else null
        if (destUri == null) {
            // Пользователь отменил диалог — это НЕ ошибка, просто отмена.
            pendingResult.success(false)
            return
        }
        if (sourcePath == null) {
            pendingResult.error("NO_SOURCE", "Исходный файл потерян", null)
            return
        }

        try {
            // Потоковое копирование — файл не грузится в память целиком, что
            // важно для больших видео (в отличие от предыдущего подхода
            // через file_picker + bytes, который читал весь файл в RAM).
            contentResolver.openOutputStream(destUri)?.use { output ->
                FileInputStream(File(sourcePath)).use { input ->
                    input.copyTo(output, bufferSize = 1 shl 16) // 64KB буфер
                }
            } ?: throw Exception("Не удалось открыть выбранное место для записи")
            pendingResult.success(true)
        } catch (e: Exception) {
            pendingResult.error("WRITE_FAILED", "Не удалось сохранить файл: ${e.message}", null)
        }
    }
}
