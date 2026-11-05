package top.yunov.clipkeep

import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "clipkeep/media_store"
    private val cookieChannelName = "clipkeep/webview_cookie"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cookieChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCookie" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("bad_args", "url required", null)
                        } else {
                            try {
                                val manager = CookieManager.getInstance()
                                manager.setAcceptCookie(true)
                                result.success(manager.getCookie(url))
                            } catch (e: Exception) {
                                result.error("cookie_failed", e.message, null)
                            }
                        }
                    }
                    "flush" -> {
                        try {
                            CookieManager.getInstance().flush()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("cookie_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveAudio" -> {
                        val path = call.argument<String>("path")
                        val displayName = call.argument<String>("displayName")
                        if (path == null || displayName == null) {
                            result.error("bad_args", "path/displayName required", null)
                        } else {
                            try {
                                val saved = saveAudioToDownloads(path, displayName)
                                if (saved != null) result.success(saved)
                                else result.error("save_failed", "unable to save audio", null)
                            } catch (e: Exception) {
                                result.error("save_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 保存音频到系统「下载/ClipKeep」目录。
    private fun saveAudioToDownloads(sourcePath: String, displayName: String): String? {
        val source = File(sourcePath)
        if (!source.exists()) return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, "audio/mp4")
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/ClipKeep",
                )
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return null
            resolver.openOutputStream(uri).use { out ->
                if (out == null) return null
                FileInputStream(source).use { input -> input.copyTo(out) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val downloadsDir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "ClipKeep",
            )
            if (!downloadsDir.exists()) downloadsDir.mkdirs()
            val dest = File(downloadsDir, displayName)
            source.copyTo(dest, overwrite = true)
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(dest.absolutePath),
                arrayOf("audio/mp4"),
                null,
            )
            return dest.absolutePath
        }
    }
}
