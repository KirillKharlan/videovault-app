package com.example.videovault

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Установка скачанного обновления приложения. Канал "com.videovault/updater".
 *
 *   install {path} -> "started" | "needs_permission" | "missing_file"
 *
 * "needs_permission": у приложения нет права ставить пакеты — открываем
 * системную страницу «Установка неизвестных приложений» именно для него;
 * после разрешения пользователь возвращается и повторяет установку.
 */
class AppUpdater(private val activity: Activity) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "install" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("ARGS", "Не указан путь к APK", null)
                    return
                }
                try {
                    result.success(install(path))
                } catch (e: Throwable) {
                    result.error("INSTALL", e.message ?: e.toString(), null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun install(path: String): String {
        val file = File(path)
        if (!file.exists()) return "missing_file"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(settings)
            return "needs_permission"
        }

        val uri = FileProvider.getUriForFile(
            activity, "${activity.packageName}.updatefileprovider", file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        activity.startActivity(intent)
        return "started"
    }
}
