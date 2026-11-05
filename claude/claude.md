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
- `video_edit_service.dart`, `video_delete_service.dart`, `url_utils.dart` (нормализация ссылок для
  детекта дубликатов), `album_shortcut_service.dart` — **нет в текущей базе**.

БД (sqflite, версия **6**, миграции в `onUpgrade`): `albums`, `videos` (колонка `album_id` — легаси,
не использовать), `album_videos` (видео ↔ альбомы, многие-ко-многим), `repeat_ranges`,
`video_skips`. Позиция просмотра — `videos.last_position_ms` (без `DBChangeNotifier.bump()`).

Нативная часть (`android/.../MainActivity.kt`, `BackgroundPlaybackService.kt`): PiP-кнопки,
фоновый звук, SAF-сохранение. Не добавлять `file_picker`/`file_saver` — они ломали сборку.
`share_plus` 12: `SharePlus.instance.share(ShareParams(files: [XFile(path)]))`.

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
