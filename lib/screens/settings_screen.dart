import 'package:flutter/material.dart';
import '../services/local_ytdlp_service.dart';
import '../widgets/safe_bottom_sheet.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';

/// Вкладка "Настройки" — сюда добавляем прочие настройки приложения по
/// мере необходимости (сейчас — режим воспроизведения и способ скачивания).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: SettingsService.instance,
          builder: (context, _) {
            final settings = SettingsService.instance;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('Настройки',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: purple)),
                const SizedBox(height: 24),

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Режим воспроизведения',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 12),
                    _ModeOption(
                      icon: Icons.movie_outlined,
                      title: 'Видео',
                      subtitle: 'Запоминает место, где остановились, и предлагает '
                          'продолжить оттуда или с сохранённого диапазона',
                      selected: settings.mode == PlaybackMode.video,
                      onTap: () => settings.setMode(PlaybackMode.video),
                    ),
                    const Divider(color: Color(0xFF2A2A38), height: 24),
                    _ModeOption(
                      icon: Icons.music_note_outlined,
                      title: 'Музыка',
                      subtitle: 'Не запоминает и не предлагает продолжить с места '
                          'остановки — каждое воспроизведение начинается заново '
                          '(диапазоны повтора по-прежнему работают)',
                      selected: settings.mode == PlaybackMode.music,
                      onTap: () => settings.setMode(PlaybackMode.music),
                    ),
                  ]),
                ),

                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('yt-dlp',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 4),
                    const Text(
                      'Видео скачиваются прямо на телефоне встроенным yt-dlp. Он сам '
                      'обновляется при каждом входе в приложение; здесь можно проверить '
                      'его работу и обновить вручную. Во время скачивания держите '
                      'приложение открытым.',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    const _LocalYtdlpCheck(),
                  ]),
                ),

                const SizedBox(height: 16),
                const _DownloadSettingsCard(),
                const SizedBox(height: 16),
                const _UpdateCard(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ModeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: selected ? purple : Colors.white38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: selected ? purple : Colors.white24),
        ]),
      ),
    );
  }
}

/// Диагностика: запускает yt-dlp внутри приложения и показывает его версию
/// либо текст ошибки (первый запуск распаковывает Python и ffmpeg).
class _LocalYtdlpCheck extends StatefulWidget {
  const _LocalYtdlpCheck();

  @override
  State<_LocalYtdlpCheck> createState() => _LocalYtdlpCheckState();
}

class _LocalYtdlpCheckState extends State<_LocalYtdlpCheck> {
  bool _busy = false;
  bool _ok = false;
  String? _result;

  Future<void> _update() async {
    setState(() { _busy = true; _result = null; });
    try {
      final r = await LocalYtdlpService.instance.update();
      if (!mounted) return;
      final changed = r.changed ? 'обновлён: ${r.before} → ${r.after}' : 'версия ${r.after} (без изменений)';
      setState(() { _busy = false; _ok = true; _result = 'yt-dlp $changed\n${r.detail}'; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _ok = false; _result = 'Не удалось обновить: $e'; });
    }
  }

  Future<void> _check() async {
    setState(() { _busy = true; _result = null; });
    try {
      final v = await LocalYtdlpService.instance.version();
      if (!mounted) return;
      setState(() { _busy = false; _ok = true; _result = 'yt-dlp на телефоне работает, версия $v'; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _ok = false; _result = 'Не запустился: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      OutlinedButton.icon(
        onPressed: _busy ? null : _check,
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.health_and_safety_outlined, size: 18),
        label: Text(_busy ? 'Подождите… (первый раз может занять до минуты)'
                          : 'Проверить yt-dlp на телефоне'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _update,
        icon: const Icon(Icons.system_update_alt, size: 18),
        label: const Text('Обновить yt-dlp до последней версии'),
      ),
      if (_result != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(_result!,
              style: TextStyle(color: _ok ? Colors.greenAccent : Colors.redAccent, fontSize: 12)),
        ),
    ]);
  }
}

/// Обновление приложения: проверка последнего релиза GitHub, скачивание APK
/// и запуск установки (см. services/update_service.dart).
class _UpdateCard extends StatelessWidget {
  const _UpdateCard();

  static String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ';

  @override
  Widget build(BuildContext context) {
    final updates = UpdateService.instance;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListenableBuilder(
        listenable: updates,
        builder: (context, _) {
          final info = updates.available;
          final status = updates.status;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Обновление приложения',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            Text(
              UpdateService.enabled
                  ? 'Установлена сборка #${UpdateService.currentBuild}'
                  : 'Проверка обновлений работает только в сборках из GitHub Actions',
              style: const TextStyle(fontSize: 15),
            ),
            if (UpdateService.enabled) ...[
              const SizedBox(height: 12),
              if (status == UpdateStatus.upToDate)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('У вас последняя сборка',
                      style: TextStyle(color: Colors.greenAccent, fontSize: 13)),
                ),
              if (status == UpdateStatus.error && updates.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText(updates.error!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
              if (info != null && status != UpdateStatus.upToDate) ...[
                Text('Доступна сборка #${info.build}'
                    '${info.size > 0 ? ' · ${_mb(info.size)}' : ''}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                if (info.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(info.notes,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
              ],
              if (status == UpdateStatus.downloading) ...[
                LinearProgressIndicator(value: updates.progress > 0 ? updates.progress : null),
                const SizedBox(height: 6),
                Text('Скачивание… ${(updates.progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ] else if (status == UpdateStatus.needsPermission) ...[
                const Text('Разрешите этому приложению установку обновлений в открывшихся '
                    'настройках, вернитесь сюда и нажмите «Установить».',
                    style: TextStyle(color: Colors.amberAccent, fontSize: 12)),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: updates.install,
                  icon: const Icon(Icons.system_update, size: 18),
                  label: const Text('Установить'),
                ),
              ] else if (status == UpdateStatus.readyToInstall) ...[
                const Text('Установка запущена. Если окно не появилось — нажмите кнопку ещё раз.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: updates.install,
                  icon: const Icon(Icons.system_update, size: 18),
                  label: const Text('Установить'),
                ),
              ] else if (status == UpdateStatus.available || (info != null && status == UpdateStatus.error)) ...[
                FilledButton.icon(
                  onPressed: updates.downloadAndInstall,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Скачать и установить'),
                ),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: status == UpdateStatus.checking ? null : updates.check,
                  icon: status == UpdateStatus.checking
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(status == UpdateStatus.checking ? 'Проверка…' : 'Проверить обновления'),
                ),
              ],
            ],
          ]);
        },
      ),
    );
  }
}

/// Настройки загрузки: качество по умолчанию и автопропуск рекламы.
class _DownloadSettingsCard extends StatelessWidget {
  const _DownloadSettingsCard();

  static const _presets = ['best', '2160', '1440', '1080', '720', '480', '360', '240'];

  static String _label(String? q) {
    if (q == null) return 'Спрашивать каждый раз';
    if (q == 'best') return 'Лучшее доступное';
    return '${q}p';
  }

  void _pickQuality(BuildContext context) {
    final settings = SettingsService.instance;
    showSafeModalBottomSheet(
      context: context,
      builder: (sheetCtx) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Качество по умолчанию',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        for (final q in <String?>[null, ..._presets])
          ListTile(
            title: Text(_label(q)),
            subtitle: q == null
                ? const Text('Окно выбора показывается при каждой загрузке')
                : null,
            trailing: settings.defaultQuality == q
                ? Icon(Icons.check, color: Theme.of(sheetCtx).colorScheme.primary)
                : null,
            onTap: () {
              settings.setDefaultQuality(q);
              Navigator.pop(sheetCtx);
            },
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            'Если такого качества у видео нет, появится обычное окно выбора '
            'с пояснением.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Загрузка', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _pickQuality(context),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const Icon(Icons.hd_outlined, color: Colors.white54),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Качество по умолчанию'),
                    Text(_label(settings.defaultQuality),
                        style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ]),
                ),
                const Icon(Icons.chevron_right, color: Colors.white38),
              ]),
            ),
          ),
          const Divider(color: Color(0xFF2A2A38), height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.fast_forward_outlined, color: Colors.white54),
            title: const Text('Автопропуск рекламы'),
            subtitle: const Text(
              'Видео с YouTube: после скачивания пропуски для спонсорских вставок '
              'и самопиара добавляются сами (SponsorBlock)',
              style: TextStyle(fontSize: 12),
            ),
            value: settings.sponsorBlock,
            onChanged: settings.setSponsorBlock,
          ),
        ]),
      ),
    );
  }
}
