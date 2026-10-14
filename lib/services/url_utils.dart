/// Приводит ссылку на видео к "ключу", одинаковому для разных форм одной и
/// той же ссылки (youtu.be/ID, youtube.com/watch?v=ID, shorts/ID, ссылки с
/// трекинговыми параметрами si=, utm_*, igsh= и т.п.) — нужно для детекта
/// дубликатов при скачивании.
String normalizeVideoUrl(String raw) {
  final trimmed = raw.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) return trimmed.toLowerCase();

  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www\.|m\.|music\.)'), '');

  if (host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
    return 'youtube:${uri.pathSegments.first}';
  }
  if (host == 'youtube.com') {
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return 'youtube:$v';
    final segs = uri.pathSegments;
    if (segs.length >= 2 && const {'shorts', 'embed', 'live', 'v'}.contains(segs[0])) {
      return 'youtube:${segs[1]}';
    }
  }

  const trackingExact = {
    'si', 'igsh', 'igshid', 'fbclid', 'feature', 'share_id', 'is_from_webapp',
    'sender_device', 'sender_web_id', 'ref', 'source', '_r', '_t', 'gclid',
  };
  final kept = <String, String>{};
  uri.queryParameters.forEach((k, val) {
    if (k.startsWith('utm_') || trackingExact.contains(k)) return;
    kept[k] = val;
  });
  final sortedKeys = kept.keys.toList()..sort();
  final query = sortedKeys.map((k) => '$k=${kept[k]}').join('&');
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '$host$path${query.isEmpty ? '' : '?$query'}'.toLowerCase();
}
