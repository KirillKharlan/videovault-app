import 'package:flutter/material.dart';

/// Показывает bottom sheet с гарантированным отступом снизу, чтобы контент
/// не перекрывался системными кнопками навигации телефона (жест/кнопки).
///
/// Раньше нижний пункт (обычно "Delete") оказывался частично под системной
/// панелью — эта обёртка добавляет SafeArea + дополнительный отступ.
Future<T?> showSafeModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color backgroundColor = const Color(0xFF16161E),
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: backgroundColor,
    isScrollControlled: isScrollControlled,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewPadding.bottom > 0 ? 8 : 16,
        ),
        child: builder(ctx),
      ),
    ),
  );
}
