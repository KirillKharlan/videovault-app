# youtubedl-android (yt-dlp на телефоне): внутри используется рефлексия
# (Jackson-маппинг, запуск процессов), поэтому R8 не должен вырезать/переименовывать классы.
-keep class com.yausername.** { *; }
-dontwarn com.yausername.**
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**

# Зависимости youtubedl-android, которые читают ресурсы/классы по имени.
-keep class org.apache.commons.** { *; }
-dontwarn org.apache.commons.**
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*
# Пока отлаживаем запуск — имена классов должны быть читаемыми в ошибках.
-dontobfuscate
