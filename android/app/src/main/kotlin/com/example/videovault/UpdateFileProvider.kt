package com.example.videovault

import androidx.core.content.FileProvider

/**
 * Собственный подкласс FileProvider: у плагинов (share_plus и др.) свои
 * провайдеры, а два объявления одного и того же класса в манифесте
 * конфликтуют при слиянии.
 */
class UpdateFileProvider : FileProvider()
