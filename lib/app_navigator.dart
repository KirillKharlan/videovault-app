import 'package:flutter/widgets.dart';

/// Ключ корневого Navigator приложения: нужен, чтобы показывать диалоги из
/// мест, где нет своего BuildContext (например, пункт «Громкость» в меню
/// полноэкранного плеера).
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
