import 'package:flutter/material.dart';

/// Показывает bottom sheet с гарантированным отступом снизу (чтобы контент
/// не перекрывался системными кнопками навигации телефона), и с поддержкой
/// прокрутки — критично в горизонтальной ориентации, где высота экрана
/// намного меньше и длинные списки (диапазоны повтора, действия с видео и
/// т.д.) иначе просто обрезаются без возможности пролистать до конца.
Future<T?> showSafeModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color backgroundColor = const Color(0xFF16161E),
  bool isScrollControlled = true,
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
        // ConstrainedBox + SingleChildScrollView: шторка не будет выше, чем
        // позволяет экран (с запасом под системные жесты/клавиатуру), а если
        // контент не помещается — появится прокрутка вместо обрезки.
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
          child: SingleChildScrollView(child: builder(ctx)),
        ),
      ),
    ),
  );
}
