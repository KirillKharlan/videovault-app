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
│   │                                     Классы: Album, Video, AppDatabase (singleton)
│   ├── services/
│   │   └── download_service.dart         ← Оркестрация скачивания:
│   │                                     POST /api/download → task_id →
│   │                                     polling /api/progress → скачивание
│   │                                     файла с /api/file, сохранение в БД
│   ├── screens/
│   │   ├── home_screen.dart              ← Список всех видео (главный экран)
│   │   ├── albums_screen.dart             ← Список альбомов + создание/переим./удаление
│   │   ├── download_screen.dart            ← Экран "Скачать видео": ввод URL,
│   │   │                                    получение инфо, выбор качества/альбома
│   │   └── player_screen.dart              ← Просмотр скачанного видео (video_player)
│   └── widgets/
│       └── video_card.dart                 ← UI-карточка видео (превью+название)
├── android/
│   ├── app/src/main/AndroidManifest.xml    ← разрешения, intent-filter для share
│   └── app/src/main/kotlin/.../MainActivity.kt
├── .github/workflows/build.yml              ← CI: сборка APK через GitHub Actions
├── pubspec.yaml                              ← зависимости (dio, sqflite, video_player,
│                                               receive_sharing_intent, cached_network_image)
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
