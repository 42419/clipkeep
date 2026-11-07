package top.yunov.clipkeep

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "clipkeep/media_store"
    private val cookieChannelName = "clipkeep/webview_cookie"
    private val storagePermissionRequest = 1001
    private val saveExecutor = Executors.newSingleThreadExecutor()
    private val pendingSaves = mutableListOf<PendingSave>()
    private var awaitingPermission = false

    private data class PendingSave(
        val path: String,
        val displayName: String,
        val mime: String,
        val result: MethodChannel.Result,
    )

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
                    "clearCookies" -> {
                        try {
                            CookieManager.getInstance().removeAllCookies {
                                CookieManager.getInstance().flush()
                                result.success(true)
                            }
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
                    "saveFile" -> saveFile(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    /// 把 App 私有目录里的成品复制到系统下载目录 Download/ClipKeep。
    /// Android 10+ 走 MediaStore；Android 7~9 需要运行时权限。
    /// 复制放到单线程队列执行，避免几百 MB 文件阻塞 platform main thread 触发 ANR。
    private fun saveFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val displayName = call.argument<String>("displayName")
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        if (path == null || displayName == null) {
            result.error("bad_args", "path/displayName required", null)
            return
        }
        val pending = PendingSave(path, displayName, mime, result)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingSaves.add(pending)
            if (!awaitingPermission) {
                awaitingPermission = true
                requestPermissions(
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    storagePermissionRequest,
                )
            }
            return
        }
        enqueueSave(pending)
    }

    private fun enqueueSave(pending: PendingSave) {
        try {
            saveExecutor.execute {
                val saved = try {
                    copyToDownloads(pending.path, pending.displayName, pending.mime)
                } catch (e: Exception) {
                    runOnUiThread { pending.result.error("save_failed", e.message, null) }
                    return@execute
                }
                runOnUiThread {
                    if (saved != null) {
                        pending.result.success(saved)
                    } else {
                        pending.result.error("save_failed", "无法写入下载目录", null)
                    }
                }
            }
        } catch (e: Exception) {
            pending.result.error("save_failed", e.message, null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != storagePermissionRequest) {
            return
        }
        awaitingPermission = false
        val queue = pendingSaves.toList()
        pendingSaves.clear()
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            queue.forEach(::enqueueSave)
        } else {
            queue.forEach {
                it.result.error("permission_denied", "缺少存储权限", null)
            }
        }
    }

    override fun onDestroy() {
        awaitingPermission = false
        val queue = pendingSaves.toList()
        pendingSaves.clear()
        queue.forEach {
            it.result.error("activity_destroyed", "页面已销毁，保存未完成", null)
        }
        saveExecutor.shutdown()
        super.onDestroy()
    }

    private fun copyToDownloads(path: String, displayName: String, mime: String): String? {
        val source = File(path)
        if (!source.exists()) {
            return null
        }
        val relative = "${Environment.DIRECTORY_DOWNLOADS}/ClipKeep"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, relative)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return null
            try {
                resolver.openOutputStream(uri).use { out ->
                    if (out == null) {
                        throw IllegalStateException("无法写入下载目录")
                    }
                    FileInputStream(source).use { input -> input.copyTo(out) }
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return "$relative/$displayName"
        }
        val downloadsDir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "ClipKeep",
        )
        if (!downloadsDir.exists() && !downloadsDir.mkdirs()) {
            return null
        }
        // Android 7~9：先写临时文件，成功后改名，避免半截文件或覆盖用户已有文件。
        val dot = displayName.lastIndexOf('.')
        val base = if (dot > 0) displayName.substring(0, dot) else displayName
        val ext = if (dot > 0) displayName.substring(dot) else ""
        var dest = File(downloadsDir, displayName)
        var suffix = 1
        while (dest.exists()) {
            dest = File(downloadsDir, "$base ($suffix)$ext")
            suffix += 1
        }
        val temp = File(downloadsDir, ".$displayName.part")
        try {
            source.copyTo(temp, overwrite = true)
            if (!temp.renameTo(dest)) {
                temp.delete()
                return null
            }
        } catch (e: Exception) {
            temp.delete()
            throw e
        }
        MediaScannerConnection.scanFile(
            applicationContext,
            arrayOf(dest.absolutePath),
            arrayOf(mime),
            null,
        )
        return "$relative/${dest.name}"
    }
}
