import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  readyToInstall,
  needsPermission,
  error,
}

/// Новая сборка, найденная в последнем релизе GitHub.
class UpdateInfo {
  final int build;
  final String tag;
  final String apkUrl;
  final int size;
  final String notes;
  const UpdateInfo({
    required this.build,
    required this.tag,
    required this.apkUrl,
    required this.size,
    required this.notes,
  });
}

/// Обновление приложения прямо из него: GitHub Actions после каждой удачной
/// сборки публикует релиз `build-<номер>` с APK (см. .github/workflows/build.yml),
/// приложение смотрит последний релиз, качает APK и запускает установку.
///
/// Репозиторий и номер текущей сборки «вшиваются» при сборке в CI через
/// `--dart-define=UPDATE_REPO=...` и `--dart-define=BUILD_NUMBER=...`; в
/// локальных сборках их нет — проверка обновлений там отключена.
/// Работает для ПУБЛИЧНОГО репозитория (релизы читаются без авторизации).
class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const String repo = String.fromEnvironment('UPDATE_REPO');
  static const int currentBuild = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
  static bool get enabled => repo.isNotEmpty && currentBuild > 0;

  static const MethodChannel _channel = MethodChannel('com.videovault/updater');

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(minutes: 5),
  ));

  UpdateStatus status = UpdateStatus.idle;
  UpdateInfo? available;
  double progress = 0;
  String? error;
  String? _apkPath;

  void _set(UpdateStatus s, {String? err}) {
    status = s;
    error = err;
    notifyListeners();
  }

  /// Смотрит последний релиз. После вызова см. [status]: `available`
  /// (новая сборка найдена, подробности в [available]), `upToDate` или `error`.
  Future<void> check() async {
    if (!enabled) return;
    if (status == UpdateStatus.checking || status == UpdateStatus.downloading) return;
    _set(UpdateStatus.checking);
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repo/releases/latest',
        options: Options(headers: {'Accept': 'application/vnd.github+json'}),
      );
      final data = resp.data ?? const <String, dynamic>{};
      final tag = (data['tag_name'] ?? '').toString();
      final m = RegExp(r'(\d+)$').firstMatch(tag);
      final build = m == null ? 0 : int.parse(m.group(1)!);
      if (build <= currentBuild) {
        available = null;
        _set(UpdateStatus.upToDate);
        return;
      }
      Map<String, dynamic>? apk;
      final assets = data['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is Map && (a['name'] ?? '').toString().toLowerCase().endsWith('.apk')) {
            apk = a.cast<String, dynamic>();
            break;
          }
        }
      }
      if (apk == null || apk['browser_download_url'] == null) {
        throw Exception('В релизе $tag нет APK-файла');
      }
      available = UpdateInfo(
        build: build,
        tag: tag,
        apkUrl: apk['browser_download_url'].toString(),
        size: (apk['size'] as num?)?.toInt() ?? 0,
        notes: (data['body'] ?? '').toString().trim(),
      );
      _set(UpdateStatus.available);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      _set(UpdateStatus.error,
          err: code == 404
              ? 'Релизов пока нет (или репозиторий приватный — тогда приложение не может их читать)'
              : 'Не удалось проверить обновления: ${e.message ?? e.type.name}');
    } catch (e) {
      _set(UpdateStatus.error, err: '$e');
    }
  }

  /// Скачивает APK найденной сборки и запускает установку.
  Future<void> downloadAndInstall() async {
    final info = available;
    if (info == null || status == UpdateStatus.downloading) return;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (!await dir.exists()) await dir.create(recursive: true);
      // Старые скачанные APK не нужны.
      await for (final f in dir.list()) {
        if (f is File && f.path.toLowerCase().endsWith('.apk')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      final path = '${dir.path}/VideoVault-${info.build}.apk';

      progress = 0;
      _set(UpdateStatus.downloading);
      var lastPercent = -1;
      await _dio.download(
        info.apkUrl,
        path,
        onReceiveProgress: (received, total) {
          final t = total > 0 ? total : info.size;
          if (t <= 0) return;
          progress = (received / t).clamp(0.0, 1.0).toDouble();
          final percent = (progress * 100).floor();
          if (percent != lastPercent) {
            lastPercent = percent;
            notifyListeners();
          }
        },
      );

      final length = await File(path).length();
      if (info.size > 0 && length != info.size) {
        try {
          await File(path).delete();
        } catch (_) {}
        throw Exception('Файл скачался не полностью ($length из ${info.size} байт). Попробуйте ещё раз');
      }
      _apkPath = path;
      await install();
    } on DioException catch (e) {
      _set(UpdateStatus.error, err: 'Ошибка скачивания: ${e.message ?? e.type.name}');
    } catch (e) {
      _set(UpdateStatus.error, err: '$e');
    }
  }

  /// Запускает системный установщик для уже скачанного APK. Если у приложения
  /// ещё нет права ставить пакеты, открывает нужную страницу настроек —
  /// после разрешения вызывается снова (кнопка «Установить»).
  Future<void> install() async {
    final path = _apkPath;
    if (path == null || !await File(path).exists()) {
      _set(UpdateStatus.error, err: 'Файл обновления не найден — скачайте заново');
      return;
    }
    try {
      final res = await _channel.invokeMethod<String>('install', {'path': path});
      switch (res) {
        case 'started':
          _set(UpdateStatus.readyToInstall);
          break;
        case 'needs_permission':
          _set(UpdateStatus.needsPermission);
          break;
        default:
          _set(UpdateStatus.error, err: 'Не удалось запустить установку ($res)');
      }
    } on PlatformException catch (e) {
      _set(UpdateStatus.error, err: e.message ?? 'Не удалось запустить установку');
    } on MissingPluginException {
      _set(UpdateStatus.error, err: 'Установка недоступна в этой сборке');
    }
  }
}
