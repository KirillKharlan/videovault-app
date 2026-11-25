package com.example.videovault

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Канал "com.videovault/dlservice": Flutter запускает/обновляет/останавливает
 * foreground-сервис скачивания.
 *   start {title, text, percent} — запустить сервис или обновить уведомление
 *   stop                         — остановить сервис
 * Kotlin -> Dart: "cancel" (кнопка «Отменить» в уведомлении).
 */
class DownloadServiceBridge(
    private val context: Context,
    channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        DownloadForegroundService.onCancelRequested = {
            mainHandler.post { channel.invokeMethod("cancel", null) }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                try {
                    val intent = Intent(context, DownloadForegroundService::class.java)
                        .setAction(DownloadForegroundService.ACTION_START)
                        .putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "VideoVault")
                        .putExtra(DownloadForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        .putExtra(DownloadForegroundService.EXTRA_PERCENT, call.argument<Int>("percent") ?: -1)
                    ContextCompat.startForegroundService(context, intent)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("DLSERVICE", e.message ?: e.toString(), null)
                }
            }
            "stop" -> {
                try {
                    context.stopService(Intent(context, DownloadForegroundService::class.java))
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("DLSERVICE", e.message ?: e.toString(), null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
