# 🗺️ КАРТА ПРОЕКТА — videovault-app (Flutter)

> Быстрая ориентация без перечитывания всех файлов. Обновляй при структурных
> изменениях. Последняя сверка с кодом: ноябрь 2026. Контекст и договорённости
> с владельцем — в `claude/claude.md`.

## Что это

Android-приложение: скачивает видео по ссылке (YouTube, TikTok, Instagram и др.) через
свой бэкенд (`videovault-backend`, Render) и хранит их в локальной библиотеке с альбомами,
плеером (повтор диапазонов, пропуски, фоновый звук, PiP) и экспортом (галерея, MP3, обрезка).
Всё, что относится к библиотеке, хранится **на телефоне**; бэкенд истории не держит.

## Структура (только код)

```
videovault-app/
├── lib/
│   ├── main.dart                  ← вход, тёмная тема (фиолетовый акцент), нижнее меню,
│   │                                приём ссылок из «Поделиться» (receive_sharing_intent)
│   ├── api/api_client.dart        ← HTTP к бэкенду. baseUrl захардкожен.
│   │                                Классы: ApiClient, VideoInfo, TaskProgress, ApiException
│   ├── models/database.dart       ← sqflite (версия 6). Album, Video, SkipSegment, RepeatRange,
│   │                                AppDatabase (синглтон), DBChangeNotifier, normalizeForSearch
│   ├── services/
│   │   ├── download_manager.dart  ← ОЧЕРЕДЬ загрузок (DownloadJob, по одной за раз), живёт вне экранов
│   │   ├── download_service.dart  ← одна загрузка: /api/download → опрос /api/progress →
│   │   │                            файл с /api/file → миниатюра → запись в БД; уведомления, ретраи
│   │   ├── playback_manager.dart  ← синглтон плеера (ChangeNotifier), см. ниже
│   │   ├── local_ytdlp_service.dart ← yt-dlp НА ТЕЛЕФОНЕ: канал `com.videovault/ytdlp` (init, version, info, download, cancel),
│   │   │                            разбор JSON в VideoInfo, селекторы формата как на сервере
│   │   ├── update_service.dart    ← обновление приложения из GitHub Releases (ChangeNotifier): проверка, скачивание APK, установка
│   │   ├── sponsorblock_service.dart ← автопропуск рекламы: после скачивания YouTube-видео берёт сегменты из SponsorBlock API и кладёт в video_skips
│   │   ├── download_foreground.dart ← Dart-сторона foreground-сервиса скачивания (канал `com.videovault/dlservice`): begin/update/end со счётчиком
│   │   ├── pip_service.dart       ← MethodChannel `com.videovault/pip` (PiP, фоновый сервис, SAF)
│   │   ├── media_export_service.dart ← галерея (gal), обрезка, mp4→mp3 (ffmpeg_kit), сохранение на устройство
│   │   ├── gallery_import_service.dart ← импорт видео из галереи (image_picker + превью)
│   │   ├── video_edit_service.dart     ← переименование, своя обложка, «горизонтальный просмотр»
│   │   ├── video_delete_service.dart   ← полное удаление (файл + обложка + БД; закрывает плеер)
│   │   ├── settings_service.dart       ← shared_preferences; режим «Видео / Музыка»
│   │   └── url_utils.dart              ← нормализация ссылок для детекта дубликатов
│   ├── screens/
│   │   ├── home_screen.dart            ← Videos: список, поиск, импорт из галереи, мультивыбор/удаление
│   │   ├── albums_screen.dart          ← Albums + AlbumDetailScreen («+» открывает пикер)
│   │   ├── album_video_picker_screen.dart ← мультивыбор видео в альбом с нумерацией
│   │   ├── download_screen.dart        ← ввод URL, инфо, название, качество, альбом
│   │   ├── download_queue_screen.dart  ← Queue: задания очереди, смена альбома, retry, удаление
│   │   ├── player_screen.dart          ← плеер (video_player + chewie), панели диапазонов/пропусков/таймера
│   │   └── settings_screen.dart        ← Settings: режим воспроизведения
│   └── widgets/
│       ├── video_card.dart             ← карточка; режим выбора (selectionMode/selected/selectionOrder)
│       ├── video_actions_sheet.dart    ← меню видео: выбрать, поделиться, альбомы, переименовать,
│       │                                 обложка, «горизонтальный просмотр»
│       ├── video_albums_dialog.dart    ← выбор альбомов для видео (несколько сразу)
│       ├── selection_bar.dart          ← панель действий при мультивыборе
│       └── safe_bottom_sheet.dart      ← showSafeModalBottomSheet (учёт системной навигации)
├── android/app/src/main/
│   ├── AndroidManifest.xml            ← разрешения, intent-filter SEND (share) и MAIN
│   └── kotlin/com/example/videovault/
│       ├── MainActivity.kt            ← канал `com.videovault/pip`, PiP-кнопки, SAF-сохранение; регистрирует канал yt-dlp
│       ├── AppUpdater.kt              ← канал `com.videovault/updater`: install(path) → запуск системного установщика APK
│       ├── UpdateFileProvider.kt      ← FileProvider для отдачи APK установщику (cache/updates/, см. res/xml/update_file_paths.xml)
│       ├── DownloadForegroundService.kt ← foreground-сервис (dataSync) на время скачивания: держит процесс и CPU, уведомление с прогрессом и «Отменить»
│       ├── DownloadServiceBridge.kt   ← канал `com.videovault/dlservice`: start/stop, событие `cancel` из уведомления
│       ├── YtDlpBridge.kt             ← мост к youtubedl-android (Python+yt-dlp+ffmpeg внутри APK); ВЕСЬ код, трогающий API библиотеки
│       └── BackgroundPlaybackService.kt ← foreground-сервис фонового звука (PARTIAL_WAKE_LOCK)
├── android/keystore/videovault.keystore ← постоянный ключ подписи (см. «Сборка»)
├── .github/workflows/build.yml        ← CI: сборка APK
├── pubspec.yaml
└── claude/claude.md, PROJECT_MAP_APP.md, README.md
```

## Скачивание: только на телефоне

Все загрузки идут через yt-dlp, встроенный в приложение (`LocalYtdlpService`, `YtDlpBridge.kt`); выбора «через сервер / авто» больше нет
(из кода убраны `DownloadMode`, серверная ветка `DownloadService`, ретраи и опрос задач). Скачивание: `DownloadService._doDownloadLocal` —
yt-dlp пишет в папку видео как `l<ms>.<ext>`, затем файл переименовывается и идёт общий финал `_finishVideo` (миниатюра, уведомление,
запись в БД). Инфо о видео и список качеств — тоже локально (`yt-dlp --dump-single-json`). Недокачанные `l<число>.*` старше часа чистятся
при следующей загрузке (`_cleanupStaleParts`). Прогресс yt-dlp считается отдельно для видео- и аудиодорожки, процент может «сбрасываться».
Скачивание идёт под foreground-сервисом (`DownloadForeground`, тип dataSync): продолжается при сворачивании и блокировке экрана, в шторке прогресс
и кнопка «Отменить» (есть также на экране загрузки и в очереди; `DownloadManager.cancelActive` → `DownloadService.cancelCurrent` →
`yt-dlp` процесс убивается, недокачанное удаляется). Обрыв сети: до 3 попыток подряд, каждая ДОКАЧИВАЕТ (id загрузки `DownloadJob.localId` стабилен,
yt-dlp продолжает `.part`); упавшую загрузку можно повторить кнопкой — тоже с докачкой, из очереди убрать — файлы удалятся. Если приложение
смахнуть из недавних, загрузка прерывается (процесс убивается). «Только аудио»: в окне выбора качества плитки m4a и MP3 (`quality` = `audio_m4a`/`audio_mp3`,
`yt-dlp -x --audio-format`).
yt-dlp внутри приложения — версия, зашитая в библиотеку на момент выпуска, поэтому он обновляется: при каждом входе в приложение (запуск и
возврат из фона; не чаще раза в 20 мин и не во время скачивания; SnackBar сообщает о новой версии) и кнопкой в Настройках; `YtDlpBridge.updateYtDlp`
вызывает `updateYoutubeDL` библиотеки через рефлексию, запасной вариант — `yt-dlp -U`. Свежему yt-dlp нужен Python ≥ 3.11 — подходит ли встроенный,
видно по «после обновления». Серверный бэкенд (`videovault-backend`) приложением больше не используется; `api/api_client.dart` оставлен ради модели `VideoInfo`.

Android: зависимости `io.github.junkfood02.youtubedl-android:library` и `:ffmpeg` (версия `0.17.+`, см. `build.gradle.kts`), `minSdk ≥ 24`,
только `arm64-v8a`, `useLegacyPackaging = true`, правила R8 в `android/app/proguard-rules.pro` (минификация сейчас выключена).

## Обновление приложения из приложения

CI (`.github/workflows/build.yml`) после удачной сборки публикует **GitHub Release** `build-<run_number>` с файлом
`VideoVault-<run_number>.apk` (хранятся 5 последних) и «вшивает» в приложение `--dart-define=UPDATE_REPO=<owner/repo>` и
`--dart-define=BUILD_NUMBER=<run_number>`. `UpdateService`: при запуске (через 3 с) и по кнопке в Настройках читает
`GET https://api.github.com/repos/<repo>/releases/latest`, номер сборки берёт из тега (`build-123` → 123); новее установленной —
скачивает APK (dio) в `cache/updates/`, проверяет размер и вызывает `AppUpdater.install` → системный установщик. Первый раз Android
просит разрешить этому приложению «установку неизвестных приложений» (`REQUEST_INSTALL_PACKAGES`), потом установка проходит поверх
(подпись та же — постоянный keystore). В локальных сборках (без dart-define) проверка отключена. **Репозиторий должен быть публичным**:
релизы читаются без токена. Права `contents: write` для workflow заданы в самом файле; если организация запрещает — включить
Settings → Actions → General → Workflow permissions → Read and write.

## Главный экран, настройки загрузки

- **Сортировка** (`HomeSort` в `home_screen.dart`, значок ⇅ в шапке, выбор хранится в `SettingsService.homeSort`): новые / старые / по названию /
  по исполнителю (автору, `Video.uploader`; видео без автора — в конце) / по длительности. Автор показывается под названием на карточке.
- **«Продолжить просмотр»** — лента над сеткой: начатые, но не досмотренные (позиция > 10 с и до конца > 10 с) видео, последние сверху, до 10 штук;
  только в режиме «Видео» и без поискового запроса (`last_played_at` обновляется в `updateLastPosition`).
- **Качество по умолчанию** (Настройки → «Загрузка», `SettingsService.defaultQuality`): «Спрашивать каждый раз» / «Лучшее» / высота. Если у видео
  есть такое качество — окно выбора пропускается (SnackBar «Скачивание: …»); если нет — обычное окно с жёлтым пояснением
  (`download_screen._qualityFromPreset`, `notice` в `_pickQualityForDownload`).
- **Автопропуск рекламы** (`SettingsService.sponsorBlock`, по умолчанию включён): только YouTube; категории sponsor / selfpromo / interaction.

## Навигация (main.dart)

Нижнее меню: **Videos · Albums · [Альбом] · Download · [Queue] · Settings**.
- Queue видна только при 2+ загрузках.
- Вкладка альбома появляется, когда в Albums открыли альбом (`_openAlbum`): подпись — название (до 9 символов, полное в tooltip).
  Она живёт, пока её не закрыли крестиком в шапке (или системным «назад», пока вкладка на экране): с неё можно уходить на другие
  вкладки и возвращаться — список, прокрутка и режим выбора сохраняются (`IndexedStack`). Открыли другой альбом — вкладка заменяется.
  Переименование/удаление альбома подхватывает `_refreshOpenAlbum` (слушает `DBChangeNotifier`).
- Страницы `IndexedStack` фиксированы: 0 Videos, 1 Albums, 2 Download, 3 Queue, 4 Settings, 5 Album; порядок в меню задаёт список `order`
  в `MainScreen.build` (`toDisplay`/`toReal` по нему). При 6 вкладках подписи показываются только у выбранной.
- Правка альбома: долгое нажатие на альбом → «Изменить» либо карандаш в шапке экрана/вкладки альбома → `showAlbumEditDialog`
  (`widgets/album_edit_dialog.dart`): название, значок (30 штук, `kAlbumIcons`) и цвет (`kAlbumColors`). Значок виден на карточке альбома
  и во вкладке альбома в нижнем меню.
- Порядок видео в альбоме: долгое нажатие на видео → «Выбрать» → режим выбора; в нём видео можно зажать и перетащить на место другого
  (`LongPressDraggable` + `DragTarget`, `_moveVideos`): вниз — после целевого, вверх — перед ним; если перетаскиваемое среди выбранных, переносятся
  все выбранные блоком. У верхнего/нижнего края при перетаскивании появляются зоны автопрокрутки. Порядок сохраняется (`setAlbumOrder`) и
  становится порядком воспроизведения (плейлист плеера = список альбома).
- `AlbumDetailScreen(onClose, isActive)`: `onClose != null` — режим вкладки (крестик вместо «назад»); `isActive` нужен, чтобы `PopScope`
  скрытой вкладки не блокировал «назад» на остальных.
- Ссылка из «Поделиться» переключает на страницу 2 с заполненным полем URL.

## Бэкенд-API (api_client.dart)

`baseUrl = https://videovault-server.onrender.com`. Если адрес Render изменился, правь только здесь.

| Метод | Таймаут | Назначение |
|---|---|---|
| `POST /api/info` | 90 с | метаданные: title, thumbnail, duration, uploader, platform, qualities, quality_sizes. `fetchInfo(url, refresh: true)` — мимо кэша сервера |
| `POST /api/fetch` | 3 мин (до заголовков) | **основной путь**: сразу видео потоком (`video/mp4`) либо JSON `{mode:"task",task_id}` |
| `POST /api/download` | 90 с | старт задачи, ответ `task_id` (запасной путь; также вызывается, если сервер старый и `/api/fetch` отвечает 404/405) |
| `GET /api/progress/<id>` | 15 с | статус задачи |
| `GET /api/file/<id>` | — | сам файл (`fileUrl`), качается через dio |
| `GET /health` | 10 с | пинг/«разбудить» сервер |

Таймаут 90 с нужен, потому что Render free засыпает, и первый запрос идёт 15–40 с.
`quality` уходит строкой: `"best"` или число без `p` (`"720"`); бэкенд также понимает `mp3`/`audio`.

## Поток: скачивание

```
download_screen: кнопка «Скачать»
  → `_loadInfo(url)` — локальный yt-dlp (--dump-single-json): название, превью, длительность, качества с размерами
  → окно выбора качества (`_pickQualityForDownload`): название можно изменить, «Обновить список качеств»
  → выбор качества ставит загрузку в очередь (DownloadManager, по одной за раз)
     → DownloadService.download → _doDownloadLocal:
         yt-dlp качает прямо в папку видео (формат/сортировка как раньше в ytdlp_worker.py), прогресс — колбэком из Kotlin
         → файл переименовывается в <название>_<id>.mp4
         → миниатюра в thumbs/thumb_<id>.jpg → Video в БД (album_videos по albumIdResolver на момент сохранения)
```

- Альбом задания можно менять до самого сохранения (`albumIdResolver`, `DownloadManager.setAlbum`).
- Одиночное упавшее задание убирается из очереди (ошибка показана на экране загрузки), при 2+ остаётся для retry.
- `wakelock_plus` держит устройство активным на время загрузки.
- Дубликаты: `findVideoBySourceUrl` + `normalizeUrl` из `url_utils.dart`.

## БД (sqflite, `videovault.db`, версия 9)

| Таблица | Поля / назначение |
|---|---|
| `albums` | id, name, cover_path, created_at, icon (ключ из `models/album_style.dart`), color (ARGB) |
| `videos` | id, title, file_path, thumbnail_path, source_url, platform, duration, file_size, ~~album_id~~ (легаси, не использовать), letterbox_landscape, last_position_ms, added_at, uploader (автор/канал; у старых видео NULL), last_played_at (для «Продолжить просмотр») |
| `album_videos` | (album_id, video_id) PK, added_at, position — видео ↔ альбомы, многие-ко-многим; `position` — свой порядок в альбоме (NULL = не задавали: такие идут сверху от новых к старым, остальные по возрастанию position; `setAlbumOrder`) |
| `repeat_ranges` | video_id, label, start_ms, end_ms, is_default, end_behavior (`loop` по умолчанию) |
| `video_skips` | video_id, start_ms, end_ms — «пропуски» (например, реклама) |

Миграции: `onUpgrade` ступенями `oldVersion < 2…9`. При изменении схемы поднимай версию и добавляй ступень.
`DBChangeNotifier.bump()` вызывается при записях; экраны подписываются на него в `initState`
(`addListener(_load)`). Исключение: позиция просмотра (`updateLastPosition`) bump не делает.
Поиск (`searchVideos`) фильтрует в Dart через `normalizeForSearch` (игнорирует пунктуацию и регистр).

## Плеер (playback_manager.dart)

**Фоновый звук.** `video_player` на Android привязан к поверхности: при сворачивании она уничтожается, и плагин останавливает плеер —
звук обрывался, хотя foreground-сервис держал процесс. Теперь при включённом «Свернуть, звук в фоне» (`isBackgroundAudio`) менеджер
слушает `AppLifecycleState` (`_LifecycleBridge`): на `hidden/paused` звук передаётся `AudioPlayer` из `just_audio` (`_switchToAudioEngine`,
позиция сохраняется), на `resumed` — обратно в видео (`_returnToVideo`). Пропуски, диапазон повтора и переход к следующему видео работают
в обоих режимах через общий `_tick(pos, dur, playing, seek, play)`; следующий ролик в фоне грузится в аудио-движок (`_loadInAudioEngine`).
Чтобы в момент сворачивания не было провала, аудиоплеер открывает файл заранее (`_prepareAudio`), а передача запускается по самому
раннему сигналу — `Activity.onUserLeaveHint` (Домой/недавние; канал `com.videovault/pip`, метод `userLeaveHint`), с поправкой позиции на
прошедшее время и ~150 мс перекрытия, пока видео не заглушено. `hidden/paused` остаются запасным путём. Если вместо этого включился PiP —
звук возвращается видео (`_onPipChanged`).
**Громкость** — `PlaybackManager.volume/setVolume`, общая для видео и аудио-движка; ползунок в шапке плеера и пункт «Громкость» в меню ⋮
chewie (`widgets/volume_dialog.dart`, работает и в полноэкранном режиме, где виден только вкл/выкл звука).

Синглтон, переживает закрытие экрана. Умеет:
- продолжить с места остановки (`last_position_ms`); в режиме **Музыка** позиция не сохраняется;
- диапазоны повтора (сохранённые и «на лету»: `applyRange`, `setAdhocRange`) с поведением в конце;
- пропуски (`addSkip`, `removeSkip`, `setSkipsEnabled`, режим разметки `startMarkingSkip`);
- плейлист и переход по кругу (`playNext`, `playFirst`);
- таймер сна, фоновый звук (`enableBackgroundAudio`), PiP, wakelock;
- громкость слайдером (`VideoPlayerController.setVolume`).

## Нативная часть и канал `com.videovault/pip`

Методы: `isPipSupported`, `setAutoEnter`, `enterPip`, `updatePipState`, `startBackgroundService`,
`stopBackgroundService`, `updateBackgroundNotification`, `saveFileWithPicker` (SAF).
Разрешения: INTERNET, POST_NOTIFICATIONS, READ_MEDIA_VIDEO/IMAGES, READ/WRITE_EXTERNAL_STORAGE,
FOREGROUND_SERVICE(+MEDIA_PLAYBACK), WAKE_LOCK. **Не добавлять `file_picker`/`file_saver`**: ломали сборку.

## Сборка

- CI: `.github/workflows/build.yml` — на push в `master` или вручную. Java 17 (zulu), Flutter stable,
  `flutter clean` → `pub get` → `flutter build apk --release --build-number=${{ github.run_number }}`.
  APK выкладывается артефактом `VideoVault-APK`. `run_number` растёт, поэтому Android предлагает обновление.
- Подпись: постоянный `android/keystore/videovault.keystore` лежит в репозитории намеренно, release-сборка
  подписывается им (через `signingConfigs.getByName("debug")` в `build.gradle.kts`). Благодаря этому APK
  из разных сборок ставятся поверх друг друга. Для публикации в магазин нужен отдельный ключ.
- Локально: `flutter pub get` → `flutter build apk --release`
  (результат: `build/app/outputs/flutter-apk/app-release.apk`).
- Claude собрать проект не может: ошибки сборки присылает владелец логом.

## Зависимости (pubspec.yaml)

Нативные (Gradle, не pubspec): youtubedl-android `library` + `ffmpeg` — yt-dlp, Python и ffmpeg внутри APK (+десятки МБ).

Используются: `http`, `dio`, `sqflite`, `path`, `path_provider`, `video_player`, `chewie`,
`shared_preferences`, `cached_network_image`, `share_plus` (12.x), `receive_sharing_intent`,
`flutter_local_notifications`, `wakelock_plus`, `image_picker`, `flutter_video_thumbnail_plus`,
`gal`, `ffmpeg_kit_flutter_new_audio`.

Объявлены, но **в `lib/` не импортируются**: `permission_handler`, `timeago`, `intl`, `share_handler`
(и закомментированный дубль `receive_sharing_intent`). Можно удалить при очередной чистке зависимостей,
после проверки сборки.

Нюансы API:
- `share_plus` 12: `SharePlus.instance.share(ShareParams(files: [XFile(path)]))`.
- `flutter_video_thumbnail_plus` заменил заброшенный `video_thumbnail` (тот вызывал `jcenter()` и ломал
  сборку на AGP 9+). Класс `FlutterVideoThumbnailPlus`, `thumbnailPath` — полный путь к файлу с расширением.
- `ffmpeg_kit_flutter` снят с pub.dev; используется форк `ffmpeg_kit_flutter_new_audio` (с lame для MP3).

## Что смотреть при новой ошибке

1. Текст похож на серверный (bot / format / unsupported / cookies) → смотри бэкенд (`PROJECT_MAP_BACKEND.md`).
2. «Задача не найдена» → сервер перезапустился посреди задачи; смотри опрос в `download_service.dart`
   и `reconcile_stale_tasks` в бэкенде.
3. UI не обновляется → подписка на `DBChangeNotifier` и `setState` в экране.
4. Ошибка сборки → `build.yml`, `pubspec.yaml` (версии пакетов), лог GitHub Actions.
5. Видео без длительности/качеств (Shorts) → обычно баг бэкенда, не Flutter.

## Известные ограничения

- Список видео грузится целиком (без пагинации): для сотен записей нормально, для десятков тысяч нужен LIMIT/OFFSET.
- Превью для скачанных видео берётся с сервера YouTube; `flutter_video_thumbnail_plus` — только для импорта из галереи.
- Не реализовано: скачивание плейлиста, субтитры, вкладка-ярлык последнего альбома
  (в этой базе нет `album_shortcut_service.dart`).
