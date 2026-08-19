package com.example.videovault

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.videovault/pip"
    private var pipChannel: MethodChannel? = null

    // Управляется из Flutter: должны ли мы автоматически войти в PiP, когда
    // пользователь уходит из приложения (Домой / Недавние). Включается пока
    // открыт плеер и видео играет, выключается в остальных случаях.
    private var shouldAutoEnterPip = false
    private var pipAspectNumerator = 16
    private var pipAspectDenominator = 9

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        // Android 12+: плавный автоматический вход через setAutoEnterEnabled —
                        // системе не нужно ждать onUserLeaveHint.
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
                else -> result.notImplemented()
            }
        }
    }

    private fun updatePipParams(autoEnter: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val builder = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(pipAspectNumerator, pipAspectDenominator))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(autoEnter)
            }
            setPictureInPictureParams(builder.build())
        } catch (e: Exception) {
            // Некорректное соотношение сторон на некоторых устройствах — игнорируем,
            // это не критично, просто автовход не подстроится идеально.
        }
    }

    private fun enterPipNow(aspectNum: Int, aspectDen: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(aspectNum, aspectDen))
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) {
            // Устройство не поддерживает PiP или параметры недопустимы — просто не входим.
        }
    }

    // Для Android 8.0–11 (до появления setAutoEnterEnabled в Android 12): единственный
    // надёжный момент войти в PiP — когда пользователь уходит из активности.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            if (shouldAutoEnterPip) {
                enterPipNow(pipAspectNumerator, pipAspectDenominator)
            }
        }
        // На Android 12+ вход обрабатывается системой автоматически через
        // setAutoEnterEnabled (см. updatePipParams) — здесь ничего не делаем.
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }
}
