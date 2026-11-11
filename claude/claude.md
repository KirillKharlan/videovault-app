# VideoVault — контекст проекта для Claude

Приложение для скачивания видео по ссылке (YouTube, TikTok, Instagram и др.) и просмотра в
собственной библиотеке. Flutter-клиент + Python-бэкенд на Render. Отвечать пользователю **по-русски**.

## Правила работы (договорённости с владельцем)
- **Не уменьшать количество попыток скачивания** в бэкенде без явной просьбы
  (`max_attempts` в `download_task`, сейчас `len(CLIENT_ATTEMPTS) * 20`).
- Собрать и запустить проект у Claude нельзя — сборка идёт через **GitHub Actions**
  (`flutter build apk --release`). Поэтому: после правок проверять хотя бы баланс скобок/синтаксис
  и честно говорить, что не собиралось. Ошибки сборки владелец присылает логом.
- Отдавать результат zip-архивами **без вложенной папки** (файлы в корне архива):
  `videovault-app-fixed.zip`, `videovault-backend-fixed.zip`.
- Не гадать про чужие пакеты: версии/API у Flutter-пакетов часто ломаются — проверять по документации
  (особенно `share_plus`, `file_picker`, `yt-dlp`).
- Перед работой сверять присланный архив с рабочей копией: владелец может прислать более раннюю
  версию, чем последний zip Claude (так уже терялась вкладка-ярлык альбома).

## Клиент (Flutter, `lib/`)
Нижнее меню: **Videos · Albums · Download · Queue (только при 2+ загрузках) · Settings**.
IndexedStack имеет фиксированные страницы (0 Videos, 1 Albums, 2 Download, 3 Queue, 4 Settings);
индексы меню пересчитываются в `MainScreen.build`.

Сервисы (`lib/services/`):
- `download_manager.dart` — **очередь** загрузок (`DownloadJob`, по одной за раз), живёт вне экранов.
  Альбом у каждой загрузки можно менять до самого сохранения (`albumIdResolver`).
  Одиночная упавшая загрузка из очереди убирается (ошибка показана на экране загрузки).
- `download_service.dart` — запрос к бэкенду, опрос прогресса, скачивание файла на телефон,
  сохранение `Video` в БД. Инфо о видео может прийти позже старта (`infoFuture`).
- `playback_manager.dart` — синглтон плеера: продолжить с места остановки, диапазоны повтора,
  **пропуски** (реклама), таймер сна, фоновый звук, PiP, переход по кругу по плейлисту.
- `pip_service.dart` — MethodChannel `com.videovault/pip`: PiP, foreground-сервис фонового звука
  (с PARTIAL_WAKE_LOCK), нативное сохранение файла через SAF (`saveFileWithPicker`).
- `media_export_service.dart` — галерея (`gal`), обрезка/MP3 через `ffmpeg_kit_flutter_new_audio`.
- `settings_service.dart` — `shared_preferences`, режим «Видео/Музыка» (в музыке позиция не сохраняется).
- `video_edit_service.dart` (переименование, обложка, «горизонтальный просмотр»), `video_delete_service.dart`,
  `url_utils.dart` (нормализация ссылок для детекта дубликатов), `gallery_import_service.dart` (импорт из галереи).
- `album_shortcut_service.dart` — **нет в текущей базе** (см. «Что ещё не сделано»).

БД (sqflite, версия **6**, миграции в `onUpgrade`): `albums`, `videos` (колонка `album_id` — легаси,
не использовать), `album_videos` (видео ↔ альбомы, многие-ко-многим), `repeat_ranges`,
`video_skips`. Позиция просмотра — `videos.last_position_ms` (без `DBChangeNotifier.bump()`).

Нативная часть (`android/.../MainActivity.kt`, `BackgroundPlaybackService.kt`): PiP-кнопки,
фоновый звук, SAF-сохранение. Не добавлять `file_picker`/`file_saver` — они ломали сборку.
`share_plus` 12: `SharePlus.instance.share(ShareParams(files: [XFile(path)]))`.

## Скачивание: один запрос (`/api/fetch`)
`DownloadService` сначала вызывает `ApiClient.fetch`: сервер либо сразу отдаёт видео потоком (`_receiveStream` пишет в `dl_<id>.part`,
потом переименование), либо возвращает `task_id` — тогда прежняя схема (polling `/api/progress` + `/api/file`). Прямой поток
возможен только для одиночных mp4 (TikTok, Instagram, YouTube 360p); YouTube 720p+ идёт через задачу. Сборка этого изменения
не проверялась (Dart-тулчейна у Claude нет) — при ошибках сборки присылай лог.

## Скачивание на телефоне (экспериментальная опция, `DownloadMode`)
Settings → «Способ скачивания»: server / local / auto. Код: `local_ytdlp_service.dart` (Dart), `YtDlpBridge.kt` (Kotlin, канал
`com.videovault/ytdlp`), ветка `_doDownloadLocal` в `download_service.dart`. **Не проверено сборкой и запуском** — написано по памяти об
API библиотеки youtubedl-android (fork junkfood02). Что наиболее вероятно придётся поправить по логу сборки/запуска:
1. координаты и версия Gradle-артефакта (`0.17.+`, группа `io.github.junkfood02.youtubedl-android`);
2. сигнатуры API в `YtDlpBridge.kt`: `YoutubeDL.getInstance().init/execute/destroyProcessById`, `FFmpeg.getInstance().init`,
   колбэк прогресса из 3 аргументов `(Float, Long, String)`, `YoutubeDLResponse.out`;
3. YouTube на телефоне может требовать JS-рантайм для yt-dlp (на сервере это Deno) — если извлечение падает с ошибкой про
   n-challenge/JS, это главный риск всей затеи; TikTok/Instagram от него не зависят;
4. R8 (правила в `proguard-rules.pro`), `minSdk 24`, `abiFilters arm64-v8a`.
Первый запуск на устройстве: `ExceptionInInitializerError` при init (и имена классов вида `y6.e`) — R8 минифицировал библиотеку.
Поэтому для release выключены `isMinifyEnabled/isShrinkResources` и добавлен `-dontobfuscate`; ошибки из Kotlin теперь содержат цепочку
причин и верх стека (`YtDlpBridge.describe`). Если без R8 всё заработает — вернуть минификацию с нужными keep-правилами.
Обновление yt-dlp: кнопка в Настройках + автообновление раз в 12 ч (`LocalYtdlpService.update/autoUpdateIfDue`, `YtDlpBridge.updateYtDlp`).
Открытый вопрос: хватает ли встроенного Python (свежему yt-dlp нужен ≥ 3.11) — смотреть «после обновления» в результате кнопки.
Не сделано: foreground-сервис для долгих загрузок, отмена, выбор способа для одного видео.

## Обновление из приложения
CI публикует GitHub Release `build-N` с APK, `UpdateService` его скачивает и ставит через `AppUpdater.kt` (FileProvider
`UpdateFileProvider`). Подробности — в `PROJECT_MAP_APP.md`. Не проверено сборкой. Ограничение: только публичный репозиторий.

## Фоновый звук и громкость
См. «Плеер» в `PROJECT_MAP_APP.md`: при сворачивании звук уходит в `just_audio` (video_player теряет Surface в фоне). Не проверено сборкой.
Если в фоне всё равно тишина — смотреть, приходят ли `hidden/paused` (`_onLifecycle`) и не падает ли `_switchToAudioEngine` (ошибки там молча глотаются).

## Gradle и AGP
CI берёт Flutter `stable` без закрепления версии, и он периодически поднимает минимальные Gradle/AGP (ноябрь 2026: сначала Gradle 9.3.1,
потом AGP 9.1.1 и рекомендация Gradle 9.5.0). Сейчас: Gradle 9.5.0 (`android/gradle/wrapper/gradle-wrapper.properties`), AGP 9.1.1
(`android/settings.gradle.kts`). При похожей ошибке — поднять версии; если новый Gradle ломает Kotlin-плагин (2.3.20) — вернуть 9.3.1 при AGP 9.1.1.

## Документация
`README.md`, `PROJECT_MAP_APP.md` (карта кода, БД, API, сборка) и `PROJECT_MAP_BACKEND.md`/`README_DEPLOY.md` бэкенда
сверены с кодом в ноябре 2026. Объявленные, но не используемые в `lib/` пакеты: `permission_handler`, `timeago`, `intl`,
`share_handler`. Адрес бэкенда: `https://videovault-server.onrender.com` (`api_client.dart`). Постоянный keystore
(`android/keystore/`) лежит в репо намеренно — подпись сборок в CI.

## Бэкенд (Python, Render free)
- `app.py` — Flask + gunicorn (`gthread`, 1 воркер, 8 потоков). `/api/info`, `/api/download`,
  `/api/progress`, `/api/file`. Клиенты YouTube перебираются партиями по 3 параллельно;
  глобально запоминается последний рабочий клиент; негативный кэш для недоступных видео.
- `ytdlp_worker.py` — yt-dlp как библиотека **в подпроцессе** (изоляция от OOM, по stdin JSON,
  по stdout JSON-события). Зависание >90 с без прогресса = попытка убивается и идёт следующая.
- Переменные окружения: `YT_PROXIES` (список через запятую), `YT_COOKIES_B64`, `POT_PROVIDER_URL`
  (вручную, **не** через `fromService` в `render.yaml`), `DEBUG_VERBOSE`.
- PO Token: отдельный сервис `videovault-pot-provider` (образ `brainicism/bgutil-ytdlp-pot-provider`).
- Cookies YouTube быстро протухают с серверного IP (`LOGIN_REQUIRED` / «Sign in to confirm you're
  not a bot») — обновлять `YT_COOKIES_B64`. Windows: 
  `[Convert]::ToBase64String([IO.File]::ReadAllBytes("cookies.txt")) | Set-Clipboard`.
- Идея «переиспользовать ссылки из /api/info при скачивании» пробовалась и откатана: ссылки на файл
  протухают. Скачивание и инфо идут **параллельно и независимо**.
- Spotify качать нельзя (DRM). Возможен только мост «метаданные Spotify → поиск на YouTube».

## Что ещё не сделано
- Скачивание плейлиста целиком (убрать `--no-playlist`, выбор видео; ложится на очередь).
- Субтитры (язык оригинала + английский, переключатель в плеере).
- Вкладка-ярлык последнего открытого альбома (была сделана, в текущую базу не попала).
- Идеи на потом: встроенный браузер YouTube (webview), передача видео по локальной Wi-Fi,
  мост Spotify → YouTube.
