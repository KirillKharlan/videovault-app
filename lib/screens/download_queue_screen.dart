import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/database.dart';
import '../services/download_manager.dart';

/// Вкладка "Очередь" — появляется, когда загрузок две и больше. Для каждой
/// видно состояние и можно выбрать свой альбом (в том числе пока она ещё
/// ждёт или даже идёт): видео сохранится именно туда.
class DownloadQueueScreen extends StatelessWidget {
  const DownloadQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: DownloadManager.instance,
          builder: (context, _) {
            final mgr = DownloadManager.instance;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('Очередь загрузки',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: purple)),
                const SizedBox(height: 4),
                const Text('Качаются по одной, остальные ждут своей очереди.',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                const SizedBox(height: 20),
                if (mgr.jobs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Center(
                        child: Text('Очередь пуста', style: TextStyle(color: Colors.white38))),
                  ),
                for (final job in List<DownloadJob>.from(mgr.jobs))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _JobCard(job: job),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AlbumChoice {
  final Album? album;
  const _AlbumChoice(this.album);
}

class _JobCard extends StatelessWidget {
  final DownloadJob job;
  const _JobCard({required this.job});

  Future<void> _pickAlbum(BuildContext context) async {
    final albums = await AppDatabase().getAlbums();
    if (!context.mounted) return;
    final choice = await showDialog<_AlbumChoice>(
      context: context,
      builder: (dialogCtx) => SimpleDialog(
        title: const Text('Альбом для этой загрузки'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogCtx, const _AlbumChoice(null)),
            child: Row(children: [
              const Expanded(child: Text('Без альбома')),
              if (job.albumId == null) const Icon(Icons.check, size: 18),
            ]),
          ),
          for (final a in albums)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogCtx, _AlbumChoice(a)),
              child: Row(children: [
                Expanded(child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (job.albumId == a.id) const Icon(Icons.check, size: 18),
              ]),
            ),
        ],
      ),
    );
    if (choice == null) return; // закрыли без выбора
    DownloadManager.instance.setAlbum(job, choice.album?.id, choice.album?.name);
  }

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    final thumb = job.info?.thumbnail;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: thumb != null && thumb.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: thumb, width: 90, height: 54, fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => _placeholder(),
                  )
                : _placeholder(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(job.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 6),
              _status(purple),
            ]),
          ),
          if (!job.isActive)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Убрать из очереди',
              icon: const Icon(Icons.close, size: 18, color: Colors.white54),
              onPressed: () => DownloadManager.instance.remove(job),
            ),
        ]),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => _pickAlbum(context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(Icons.folder_outlined, size: 18, color: purple),
              const SizedBox(width: 8),
              Expanded(
                child: Text(job.albumName ?? 'Без альбома',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _placeholder() => Container(
        width: 90, height: 54, color: const Color(0xFF1E1E2A),
        child: const Icon(Icons.video_file, color: Colors.white38),
      );

  Widget _status(Color purple) {
    switch (job.status) {
      case DownloadJobStatus.queued:
        return const Text('В очереди', style: TextStyle(color: Colors.white38, fontSize: 12));
      case DownloadJobStatus.downloading:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LinearProgressIndicator(
            value: job.progress > 0 ? job.progress : null,
            backgroundColor: const Color(0xFF1E1E2A),
            valueColor: AlwaysStoppedAnimation(purple),
          ),
          const SizedBox(height: 4),
          Text('${(job.progress * 100).toInt()}% · ${job.statusText}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ]);
      case DownloadJobStatus.error:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(job.error ?? 'Ошибка',
              maxLines: 3, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          TextButton(
            style: TextButton.styleFrom(
                padding: EdgeInsets.zero, minimumSize: const Size(0, 28),
                alignment: Alignment.centerLeft),
            onPressed: () => DownloadManager.instance.retry(job),
            child: const Text('Повторить'),
          ),
        ]);
    }
  }
}
