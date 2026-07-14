# VideoVault — Flutter App

Мобильное приложение для скачивания и просмотра видео офлайн.
Общается с бэкендом на Render.com через REST API.

---

## Установка Flutter (Windows)

1. Скачай Flutter SDK: https://docs.flutter.dev/get-started/install/windows
2. Распакуй в `C:\flutter`
3. Добавь `C:\flutter\bin` в PATH
4. Проверь: `flutter doctor`

---

## Сборка APK

```cmd
cd videovault-app
flutter pub get
flutter build apk --release
```

APK: `build\app\outputs\flutter-apk\app-release.apk`

---

## Установка на телефон (через USB)

```cmd
flutter install
```

или через adb:
```cmd
adb install build\app\outputs\flutter-apk\app-release.apk
```

---

## Важно: поменяй URL бэкенда

В файле `lib/api/api_client.dart` замени:
```dart
static const String baseUrl = 'https://videovault-api.onrender.com';
```
на свой URL с Render.

---

## Как деплоить бэкенд на Render

1. Залей папку `videovault-backend` на GitHub
2. Зайди на render.com → New Web Service
3. Выбери репозиторий
4. Build command: `pip install -r requirements.txt`
5. Start command: `uvicorn main:app --host 0.0.0.0 --port $PORT`
6. Plan: Free
7. Deploy → скопируй URL (например `https://videovault-api.onrender.com`)
