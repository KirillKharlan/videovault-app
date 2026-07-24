# 🗺️ КАРТА ПРОЕКТА — videovault-app (Flutter)

> Для быстрой ориентации без пересмотра всех файлов. Обновляй при
> структурных изменениях.

## Структура (только код, без gradle/build мусора)

```
videovault-app/
├── lib/
│   ├── main.dart                      ← точка входа, MaterialApp, тема (тёмная,
│   │                                     фиолетовый акцент), обработка shared
│   │                                     intent (ссылки из YouTube/TikTok "Поделиться")
│   ├── api/
│   │   └── api_client.dart             ← HTTP-клиент к backend (Render).
│   │                                     baseUrl задан здесь же.
│   │                                     Модели: VideoInfo, TaskProgress
│   ├── models/
│   │   └── database.dart                ← SQLite (sqflite). Таблицы: albums, videos.
│   │                                     Классы: Album, Video, AppDatabase (singleton),
│   │                                     DBChangeNotifier (реактивные обновления UI),
│   │                                     normalizeForSearch (поиск без учёта пунктуации)
│   ├── services/
│   │   ├── download_service.dart         ← Оркестрация скачивания:
│   │   │                                   POST /api/download → task_id →
│   │   │                                   polling /api/progress → скачивание файла
│   │   │                                   + миниатюры с /api/file, сохранение в БД
│   │   └── gallery_import_service.dart    ← Импорт видео из галереи телефона
│   │                                     (image_picker + flutter_video_thumbnail_plus)
│   ├── screens/
│   │   ├── home_screen.dart              ← Список всех видео (главный экран).
│   │   │                                   Автообновление через DBChangeNotifier,
│   │   │                                   импорт из галереи, поиск.
│   │   ├── albums_screen.dart             ← Список альбомов + AlbumDetailScreen
│   │   │                                   с кнопкой "Add videos"
│   │   ├── album_video_picker_screen.dart  ← Мультивыбор видео для добавления
│   │   │                                    в альбом (с нумерацией выбора)
│   │   ├── download_screen.dart            ← Экран "Скачать видео": ввод URL,
│   │   │                                    получение инфо, редактирование
│   │   │                                    названия, выбор качества/альбома
│   │   └── player_screen.dart              ← Просмотр видео (video_player + chewie),
│   │                                       слайдер громкости
│   └── widgets/
│       ├── video_card.dart                 ← UI-карточка видео. Поддерживает режим
│       │                                     мультивыбора (selectionMode/selected/
│       │                                     selectionOrder) для album_video_picker
│       └── safe_bottom_sheet.dart           ← showSafeModalBottomSheet — обёртка
│                                            над showModalBottomSheet с защитой от
│                                            перекрытия системными кнопками навигации
├── android/
│   ├── app/src/main/AndroidManifest.xml    ← разрешения (INTERNET, POST_NOTIFICATIONS,
│   │                                        READ_MEDIA_VIDEO/IMAGES), intent-filter
│   │                                        для share (SEND) и MAIN
│   └── app/src/main/kotlin/.../MainActivity.kt
├── .github/workflows/build.yml              ← CI: сборка APK через GitHub Actions
├── pubspec.yaml                              ← зависимости (dio, sqflite, video_player,
│                                               receive_sharing_intent, cached_network_image,
│                                               image_picker, flutter_video_thumbnail_plus)
└── README.md
```

## Поток данных: скачивание видео

```
download_screen.dart
  → api_client.fetchInfo(url)           [POST /api/info]
  → показывает title/duration/качества
  → пользователь жмёт "Скачать"
  → download_service.download()
      → api_client.startDownload()       [POST /api/download] → task_id
      → цикл: api_client.getProgress()   [GET /api/progress/<id>] каждые ~2 сек
      → когда status=="done":
          → скачивает файл                [GET /api/file/<id>]
          → сохраняет в AppDatabase (таблица videos)
```

## Важные детали реализации

- **baseUrl** backend URL захардкожен в `api_client.dart` — если меняется
  адрес на Render, обновлять здесь.
- **Таймауты** увеличены (90 сек на info/download-старт) — Render free plan
  засыпает и может не успеть ответить за стандартные 30 сек.
- **quality** отправляется как строка: `"best"` или число вроде `"720"`
  (без `p` — `p` добавляется только в UI для отображения, не в запросе).
- **Share-интеграция**: `receive_sharing_intent` ловит URL когда юзер жмёт
  "Поделиться" в YouTube/TikTok → открывает download_screen с уже
  заполненным полем.
- **SQLite** — данные видео (путь к файлу, альбом, метаданные) хранятся
  локально на телефоне, backend не хранит историю пользователя.
- **APK собирается через GitHub Actions** (не локально) — см.
  `.github/workflows/build.yml`. После пуша в репо — актions сам собирает
  и публикует artifact с APK.

## Известные особенности / грабли

- Если сервер на Render "спит" — первый запрос может занять 20-40 сек,
  UI должен показывать это состояние, а не сразу считать ошибкой.
- `TaskProgress.status` может быть: `queued`, `downloading`, `done`, `error`
  — polling должен корректно завершаться на `done`/`error`.
- Video duration/качество могут прийти пустыми для YouTube Shorts —
  это баг backend, не Flutter (см. PROJECT_MAP_BACKEND.md).

## Что смотреть при новой ошибке

1. Ошибка похожа на текст с сервера (bot/format/unsupported и т.п.) —
   смотри backend, не Flutter
2. "Задача не найдена" в UI — смотри `download_service.dart` (polling
   логика) и backend `tasks.json`
3. UI не обновляется / зависает — смотри `download_screen.dart`
   state management (`setState`, `StreamBuilder` если есть)
4. Проблемы с APK/сборкой — смотри `.github/workflows/build.yml` и
   `pubspec.yaml` на предмет несовместимых версий пакетов

## Новые фичи (второй раунд правок)

- **Реактивные обновления**: `DBChangeNotifier.instance` — ChangeNotifier-синглтон
  в database.dart. Все write-операции (insert/update/delete) вызывают `.bump()`.
  HomeScreen/AlbumsScreen/AlbumDetailScreen подписываются в initState через
  `addListener(_load)`, отписываются в dispose. Больше нет ручной кнопки Refresh.
- **Мультивыбор видео в альбом**: AlbumDetailScreen → кнопка "+" →
  AlbumVideoPickerScreen. Видео НЕ удаляются из общего списка (просто меняется
  `album_id`). VideoCard поддерживает `selectionMode`/`selected`/`selectionOrder`
  для подсветки и нумерации выбора.
- **safe_bottom_sheet.dart**: все bottom sheets теперь через
  `showSafeModalBottomSheet` вместо голого `showModalBottomSheet` — фикс
  перекрытия системными кнопками навигации телефона.
- **Громкость**: PlayerScreen — иконка в шапке открывает Slider (0-100%),
  управляет `VideoPlayerController.setVolume()` напрямую, отдельно от
  встроенного mute-переключателя Chewie.
- **Переименование при скачивании**: DownloadScreen — поле "Название" после
  получения инфо, редактируемое, с кнопкой сброса к оригиналу. Передаётся в
  `DownloadService.download(customTitle: ...)`.
- **Импорт из галереи**: `gallery_import_service.dart` — image_picker для
  выбора видео + flutter_video_thumbnail_plus для генерации превью + video_player для
  чтения длительности. Кнопка на HomeScreen (иконка галереи в шапке).
- **Поиск без учёта пунктуации**: `normalizeForSearch()` в database.dart —
  убирает все не-буквенно-цифровые символы перед сравнением. searchVideos
  теперь фильтрует в Dart (не SQL LIKE), т.к. нужна polnaya нормализация.
- **Миниатюры YouTube**: при скачивании сервис скачивает превью по URL из
  `VideoInfo.thumbnail` и сохраняет локально (`thumbs/thumb_<taskId>.jpg`),
  путь пишется в `Video.thumbnailPath`. Раньше этого не было — карточки
  показывали только заглушку.
- **Длительность видео**: раньше `Video.duration` всегда сохранялся как 0.
  Теперь `DownloadService.download()` принимает `VideoInfo? info` (уже
  полученный через /api/info) и берёт `info.duration` напрямую — без лишнего
  сетевого запроса.

## Известные ограничения нового кода

- Автоподгрузка (infinite scroll) НЕ реализована в классическом смысле —
  вместо этого весь список подгружается сразу, но обновляется автоматически
  (реактивно) без ручной кнопки. Для типичного личного использования (сотни,
  не десятки тысяч видео) это нормально по производительности. Если библиотека
  вырастет очень большой — тогда стоит добавить настоящую пагинацию с LIMIT/OFFSET.
- flutter_video_thumbnail_plus генерирует превью только для видео из галереи (локальный
  импорт) — для скачанных с YouTube используется официальное превью с сервера.

## Фикс сборки (video_thumbnail → flutter_video_thumbnail_plus)

`video_thumbnail: ^0.5.3` был заброшен — его `android/build.gradle` вызывает
устаревший `jcenter()`, которого больше не существует, что ломает сборку на
AGP 9+ ("Could not find method jcenter()"). Заменён на активно поддерживаемый
`flutter_video_thumbnail_plus: ^1.0.5` — тот же функционал, другой API:
- Класс: `FlutterVideoThumbnailPlus` (не `VideoThumbnail`)
- `imageFormat: ImageFormat.png` (без namespace-префикса, само название пакета
  уже уникально)
- `thumbnailPath` — теперь это ПОЛНЫЙ путь к файлу назначения (с расширением),
  а не путь к директории как было в старом пакете
