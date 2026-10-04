import 'package:flutter/material.dart';
import '../services/settings_service.dart';

/// Вкладка "Настройки" — сюда добавляем прочие настройки приложения по
/// мере необходимости (сейчас — только режим воспроизведения).
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
