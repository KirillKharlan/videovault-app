package com.example.videovault

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileFilter
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Modifier
import java.util.concurrent.Executors

/**
 * Мост Flutter <-> yt-dlp, встроенный в приложение (библиотека youtubedl-android:
 * Python + yt-dlp + ffmpeg внутри APK). Канал "com.videovault/ytdlp".
 *
 * Весь код, который трогает API библиотеки, собран в ЭТОМ файле: если новая
 * версия библиотеки поменяет сигнатуры, править нужно только его.
 *
 * Методы (Dart -> Kotlin):
 *   init                                   — распаковка Python/yt-dlp/ffmpeg (один раз)
 *   version                                — версия yt-dlp (диагностика)
 *   info     {url}                         — JSON метаданных (yt-dlp --dump-single-json)
 *   download {url,outDir,id,format,sort}   — скачивание в outDir/<id>.<ext>, ответ — путь к файлу
 *   cancel   {id}                          — остановить скачивание с этим id
 *   update                                 — обновить yt-dlp до последней версии, ответ {before, after, detail}
 * Kotlin -> Dart: "progress" {id, progress(0..100), eta(сек)}.
 */
class YtDlpBridge(
    private val context: Context,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val initLock = Any()
    @Volatile private var initialized = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> runAsync(result) {
                ensureInit()
                "ok"
            }
            "version" -> runAsync(result) {
                ensureInit()
                val request = YoutubeDLRequest(emptyList<String>())
                request.addOption("--version")
                YoutubeDL.getInstance().execute(request).out.trim()
            }
            "info" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("ARGS", "Не указан url", null)
                    return
                }
                runAsync(result) {
                    ensureInit()
                    val request = YoutubeDLRequest(url)
                    request.addOption("--dump-single-json")
                    request.addOption("--no-playlist")
                    request.addOption("--no-warnings")
                    YoutubeDL.getInstance().execute(request).out
                }
            }
            "download" -> {
                val url = call.argument<String>("url")
                val outDir = call.argument<String>("outDir")
                val id = call.argument<String>("id")
                val format = call.argument<String>("format")
                val sort = call.argument<String>("sort") ?: ""
                if (url.isNullOrBlank() || outDir.isNullOrBlank() || id.isNullOrBlank() || format.isNullOrBlank()) {
                    result.error("ARGS", "Не хватает аргументов для скачивания", null)
                    return
                }
                runAsync(result) {
                    ensureInit()
                    download(url, outDir, id, format, sort)
                }
            }
            "update" -> runAsync(result) {
                ensureInit()
                updateYtDlp()
            }
            "cancel" -> {
                val id = call.argument<String>("id")
                runAsync(result) {
                    if (id.isNullOrBlank()) false else YoutubeDL.getInstance().destroyProcessById(id)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun currentVersion(): String = try {
        val request = YoutubeDLRequest(emptyList<String>())
        request.addOption("--version")
        YoutubeDL.getInstance().execute(request).out.trim()
    } catch (e: Throwable) {
        "не запускается (${e.message?.lineSequence()?.firstOrNull() ?: e.javaClass.simpleName})"
    }

    /**
     * Обновляет yt-dlp внутри приложения до последней стабильной версии (в библиотеку
     * зашита версия на момент её выпуска — для YouTube она быстро устаревает).
     * Метод библиотеки вызывается через рефлексию: его сигнатура менялась между
     * версиями (с каналом обновления и без), и так сборка не зависит от неё.
     * Если метод недоступен или упал — пробуем встроенное самообновление `yt-dlp -U`.
     */
    private fun updateYtDlp(): Map<String, String> {
        val before = currentVersion()
        var detail: String
        try {
            detail = "библиотека: " + callLibraryUpdate()
        } catch (e: Throwable) {
            detail = "библиотека не обновила (" + describe(e).lineSequence().first() + ")"
            try {
                val request = YoutubeDLRequest(emptyList<String>())
                request.addOption("-U")
                val out = YoutubeDL.getInstance().execute(request).out.trim()
                detail += "; yt-dlp -U: " + out.lineSequence().lastOrNull().orEmpty()
            } catch (e2: Throwable) {
                detail += "; yt-dlp -U тоже не вышло (" + describe(e2).lineSequence().first() + ")"
            }
        }
        return mapOf("before" to before, "after" to currentVersion(), "detail" to detail)
    }

    private fun callLibraryUpdate(): String {
        val yt = YoutubeDL.getInstance()
        val method = yt.javaClass.methods
            .filter { it.name == "updateYoutubeDL" }
            .minByOrNull { it.parameterTypes.size }
            ?: throw NoSuchMethodException("в библиотеке нет updateYoutubeDL")
        val args: Array<Any?> = when (method.parameterTypes.size) {
            1 -> arrayOf(context)
            2 -> arrayOf(context, defaultUpdateChannel(method.parameterTypes[1]))
            else -> throw IllegalStateException("неожиданная сигнатура updateYoutubeDL: ${method.parameterTypes.size} арг.")
        }
        try {
            val target = if (Modifier.isStatic(method.modifiers)) null else yt
            return method.invoke(target, *args)?.toString() ?: "готово"
        } catch (e: InvocationTargetException) {
            throw e.targetException ?: e
        }
    }

    /** Канал обновления «stable» (в разных версиях библиотеки он объявлен по-разному). */
    private fun defaultUpdateChannel(type: Class<*>): Any {
        for (name in listOf("_STABLE", "STABLE")) {
            val v = runCatching { type.getField(name).get(null) }.getOrNull()
            if (v != null && type.isInstance(v)) return v
        }
        for (nested in type.declaredClasses) {
            if (nested.simpleName.equals("STABLE", ignoreCase = true)) {
                val v = runCatching { nested.getField("INSTANCE").get(null) }.getOrNull()
                if (v != null && type.isInstance(v)) return v
            }
        }
        val companion = runCatching { type.getField("Companion").get(null) }.getOrNull()
        if (companion != null) {
            val getter = companion.javaClass.methods.firstOrNull {
                it.parameterTypes.isEmpty() &&
                    (it.name.equals("get_STABLE", true) || it.name.equals("getSTABLE", true))
            }
            val v = runCatching { getter?.invoke(companion) }.getOrNull()
            if (v != null && type.isInstance(v)) return v
        }
        if (type.isEnum) {
            type.enumConstants?.firstOrNull { it.toString().contains("STABLE", ignoreCase = true) }
                ?.let { return it }
        }
        throw IllegalStateException("не удалось выбрать канал обновления (${type.name})")
    }

    private fun ensureInit() {
        if (initialized) return
        synchronized(initLock) {
            if (initialized) return
            YoutubeDL.getInstance().init(context)
            FFmpeg.getInstance().init(context)
            initialized = true
        }
    }

    private fun download(url: String, outDir: String, id: String, format: String, sort: String): String {
        val request = YoutubeDLRequest(url)
        request.addOption("-f", format)
        if (sort.isNotEmpty()) request.addOption("-S", sort)
        request.addOption("--merge-output-format", "mp4")
        request.addOption("--no-playlist")
        request.addOption("--no-mtime")
        request.addOption("--newline")
        request.addOption("--concurrent-fragments", "4")
        request.addOption("--retries", "5")
        request.addOption("--fragment-retries", "5")
        request.addOption("-o", "$outDir/$id.%(ext)s")

        try {
            YoutubeDL.getInstance().execute(request, id) { progress, eta, _ ->
                mainHandler.post {
                    channel.invokeMethod(
                        "progress",
                        mapOf("id" to id, "progress" to progress.toDouble(), "eta" to eta),
                    )
                }
            }
        } catch (e: Throwable) {
            // Недокачанные .part и промежуточные дорожки не должны оставаться на диске.
            removeLeftovers(outDir, id)
            throw e
        }

        val path = pickResult(outDir, id)
        if (path == null) {
            removeLeftovers(outDir, id)
            throw IllegalStateException("yt-dlp завершился, но итоговый файл не найден")
        }
        return path
    }

    /** Итоговый файл: <id>.mp4, иначе самый большой из <id>.* (без .part/.ytdl). */
    private fun pickResult(outDir: String, id: String): String? {
        val files = File(outDir).listFiles(FileFilter { f ->
            f.isFile && f.name.startsWith("$id.") &&
                !f.name.endsWith(".part") && !f.name.endsWith(".ytdl") && !f.name.endsWith(".temp")
        }) ?: return null
        val chosen = files.firstOrNull { it.name == "$id.mp4" } ?: files.maxByOrNull { it.length() }
        return chosen?.absolutePath
    }

    private fun removeLeftovers(outDir: String, id: String) {
        File(outDir).listFiles(FileFilter { it.isFile && it.name.startsWith("$id.") })
            ?.forEach { runCatching { it.delete() } }
    }

    /** Выполняет [block] в фоне и возвращает результат/ошибку во Flutter в главном потоке. */
    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Throwable) {
                val message = describe(e)
                mainHandler.post { result.error("YTDLP", message, null) }
            }
        }
    }

    /**
     * Текст ошибки для показа в приложении: цепочка причин (ExceptionInInitializerError
     * сам по себе пустой — настоящая причина лежит в cause). Для «странных» ошибок
     * без сообщения и для java.lang.Error добавляем первые строки стека; обычные
     * ошибки yt-dlp (длинный stderr в сообщении) остаются без стека.
     */
    private fun describe(error: Throwable): String {
        val sb = StringBuilder()
        var current: Throwable? = error
        var depth = 0
        while (current != null && depth < 5) {
            if (depth > 0) sb.append("\n← ")
            sb.append(current.javaClass.name)
            val msg = current.message
            if (!msg.isNullOrBlank()) sb.append(": ").append(msg.take(2000))
            val next = current.cause?.takeIf { it !== current }
            if (next == null && (current is Error || msg.isNullOrBlank())) {
                current.stackTrace.take(6).forEach { sb.append("\n    at ").append(it) }
            }
            current = next
            depth++
        }
        return sb.toString()
    }
}
