plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.videovault"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    // Постоянный keystore (android/keystore/videovault.keystore, закоммичен в репо).
    // Раньше здесь неявно использовался debug-конфиг по умолчанию — на GitHub
    // Actions он создаётся заново на каждом раннере => разная подпись каждой
    // сборки => Android требует полного удаления вместо обновления поверх.
    // Переопределяем "debug" конфиг на наш зафиксированный файл — release
    // builds уже ссылаются на signingConfigs.getByName("debug"), так что
    // больше ничего менять не нужно.
    signingConfigs {
        getByName("debug") {
            storeFile = file("../keystore/videovault.keystore")
            storePassword = "videovault123"
            keyAlias = "videovault"
            keyPassword = "videovault123"
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.videovault"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // youtubedl-android (yt-dlp на телефоне) требует minSdk 24+
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true

        // Только arm64: нативные библиотеки Python+ffmpeg из youtubedl-android
        // весят десятки МБ на каждую архитектуру. Все современные телефоны — arm64.
        // Если понадобится 32-битный ARM или эмулятор x86 — добавить сюда.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // youtubedl-android распаковывает свои .so (python, ffmpeg) на диск и запускает
    // их как процессы — для этого нативные библиотеки не должны храниться сжатыми в APK.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 (минификация/обфускация) выключен: с ним youtubedl-android падал при
            // инициализации (ExceptionInInitializerError, классы вида "y6.e"). Размер
            // APK немного вырастет. Вернуть минификацию можно, когда будет ясно,
            // какие классы нужно сохранить (правила — в proguard-rules.pro).
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.3")

    // FileProvider для установки обновления (UpdateFileProvider.kt)
    implementation("androidx.core:core:1.13.1")

    // yt-dlp + Python + ffmpeg прямо на телефоне (опция «На телефоне»).
    // Версия плавающая в пределах 0.17.x, чтобы не упереться в несуществующий
    // точный номер. Если Gradle не находит артефакт — посмотреть актуальную
    // версию на Maven Central (io.github.junkfood02.youtubedl-android) и
    // поменять здесь; когда всё заработает — зафиксировать точную версию.
    val ytdlpVersion = "0.17.+"
    implementation("io.github.junkfood02.youtubedl-android:library:$ytdlpVersion")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:$ytdlpVersion")
}