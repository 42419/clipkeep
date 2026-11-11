package top.yunov.clipkeep

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "clipkeep/media_store"
    private val installerChannelName = "clipkeep/apk_installer"
    private val pickerChannelName = "clipkeep/file_picker"
    private val downloadsChannelName = "clipkeep/downloads_service"
    private val connectivityChannelName = "clipkeep/connectivity"
    private val pickImageRequest = 2001
    private val pickVideoRequest = 2002
    private val storagePermissionRequest = 1001
    private val notificationPermissionRequest = 1003
    private val saveExecutor = Executors.newSingleThreadExecutor()
    private val pendingSaves = mutableListOf<PendingSave>()
    private var awaitingPermission = false
    private var pendingPick: MethodChannel.Result? = null
    private var notificationPermissionAsked = false
    private var connectivitySink: EventChannel.EventSink? = null
    private var connectivityCallback: ConnectivityManager.NetworkCallback? = null

    private data class PendingSave(
        val path: String,
        val displayName: String,
        val mime: String,
        val result: MethodChannel.Result,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveFile" -> saveFile(call, result)
                    "extractAudio" -> extractAudio(call, result)
                    "convertToJpeg" -> convertToJpeg(call, result)
                    "openMedia" -> openMedia(call, result)
                    "shareMedia" -> shareMedia(call, result)
                    "freeBytes" -> {
                        try {
                            val dir = getExternalFilesDir(null) ?: filesDir
                            result.success(android.os.StatFs(dir.absolutePath).availableBytes)
                        } catch (e: Exception) {
                            result.error("free_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path required", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pickerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage" -> openMediaPicker("image/*", pickImageRequest, result)
                    "pickVideo" -> openMediaPicker("video/*", pickVideoRequest, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadsChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "ensurePermission") {
                    requestNotificationPermission()
                    result.success(true)
                    return@setMethodCallHandler
                }
                val action = when (call.method) {
                    "start" -> DownloadService.ACTION_START
                    "update" -> DownloadService.ACTION_UPDATE
                    "complete" -> DownloadService.ACTION_COMPLETE
                    "stop" -> DownloadService.ACTION_STOP
                    else -> null
                }
                if (action == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    requestNotificationPermission()
                    DownloadService.start(
                        this,
                        action,
                        call.argument<String>("title") ?: "ClipKeep",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: 0,
                        call.argument<Boolean>("indeterminate") ?: false,
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.error("service_failed", e.message, null)
                }
            }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            connectivityChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    connectivitySink = events
                    events?.success(isNetworkAvailable())
                    val manager =
                        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val callback =
                        object : ConnectivityManager.NetworkCallback() {
                            override fun onAvailable(network: Network) {
                                runOnUiThread { connectivitySink?.success(true) }
                            }

                            override fun onLost(network: Network) {
                                runOnUiThread {
                                    connectivitySink?.success(isNetworkAvailable())
                                }
                            }
                        }
                    connectivityCallback = callback
                    try {
                        manager.registerDefaultNetworkCallback(callback)
                    } catch (_: Exception) {
                        // 注册失败时不阻塞其他功能。
                    }
                }

                override fun onCancel(arguments: Any?) {
                    unregisterConnectivity()
                    connectivitySink = null
                }
            },
        )
    }

    private fun isNetworkAvailable(): Boolean {
        return try {
            val manager =
                getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = manager.activeNetwork ?: return false
            val caps = manager.getNetworkCapabilities(network) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } catch (_: Exception) {
            true
        }
    }

    private fun unregisterConnectivity() {
        val callback = connectivityCallback ?: return
        connectivityCallback = null
        try {
            val manager =
                getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            manager.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
            // 已注销或不可用时忽略。
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            notificationPermissionAsked
        ) {
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermissionAsked = true
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequest,
            )
        }
    }

    /// 选图片/视频：Android 13+ 用系统照片选择器（Photo Picker）；
    /// 不支持 Photo Picker 的系统退回 ACTION_GET_CONTENT，让用户从相册/文件管理器里选。
    private fun openMediaPicker(mime: String, requestCode: Int, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "另一个选择器还在运行", null)
            return
        }
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                    type = mime
                }
            } else {
                Intent(Intent.ACTION_GET_CONTENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                }
            }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            pendingPick = result
            startActivityForResult(intent, requestCode)
        } catch (e: Exception) {
            pendingPick = null
            result.error("picker_failed", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickImageRequest && requestCode != pickVideoRequest) {
            return
        }
        val pending = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        try {
            val displayName = queryDisplayName(uri) ?: "picked"
            val dot = displayName.lastIndexOf('.')
            val ext = if (dot in 1 until displayName.length - 1) {
                displayName.substring(dot + 1).lowercase()
            } else {
                ""
            }
            val target = File(
                cacheDir,
                "clipkeep_pick_${System.currentTimeMillis()}${if (ext.isEmpty()) "" else ".$ext"}",
            )
            contentResolver.openInputStream(uri).use { input ->
                if (input == null) {
                    throw IllegalStateException("无法读取所选文件")
                }
                target.outputStream().use { out -> input.copyTo(out) }
            }
            pending.success(target.absolutePath)
        } catch (e: Exception) {
            pending.error("pick_failed", e.message, null)
        }
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        return try {
            contentResolver
                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
        } catch (e: Exception) {
            null
        }
    }

    /// 从 MP4 复制音轨到 M4A（无损，不转码）；用于抖音「仅音频」。
    private fun extractAudio(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val output = call.argument<String>("output")
        if (input == null || output == null) {
            result.error("bad_args", "input/output required", null)
            return
        }
        saveExecutor.execute {
            try {
                val outFile = File(output)
                if (outFile.exists()) {
                    outFile.delete()
                }
                extractAudioTrack(input, output)
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("extract_failed", e.message ?: "提取音频失败", null)
                }
            }
        }
    }

    private fun extractAudioTrack(input: String, output: String) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(input)
            var trackIndex = -1
            var audioFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    audioFormat = format
                    break
                }
            }
            if (trackIndex < 0 || audioFormat == null) {
                throw IllegalStateException("视频没有音轨")
            }
            extractor.selectTrack(trackIndex)
            val mux = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            val outTrack = mux.addTrack(audioFormat)
            mux.start()
            val maxSize = if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            } else {
                1024 * 1024
            }
            val buffer = ByteBuffer.allocateDirect(maxSize.coerceAtLeast(64 * 1024))
            val info = MediaCodec.BufferInfo()
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) {
                    break
                }
                info.offset = 0
                info.size = size
                info.presentationTimeUs = extractor.sampleTime
                info.flags = extractor.sampleFlags
                mux.writeSampleData(outTrack, buffer, info)
                extractor.advance()
            }
            mux.stop()
        } finally {
            try {
                muxer?.release()
            } catch (_: Exception) {}
            extractor.release()
        }
    }

    /// 把图片转成无元数据的 JPEG（Motion Photo 要求）。
    private fun convertToJpeg(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val output = call.argument<String>("output")
        if (input == null || output == null) {
            result.error("bad_args", "input/output required", null)
            return
        }
        saveExecutor.execute {
            try {
                val bitmap = BitmapFactory.decodeFile(input)
                    ?: throw IllegalArgumentException("无法解码图片")
                FileOutputStream(output).use { stream ->
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 95, stream)
                }
                bitmap.recycle()
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("jpeg_failed", e.message ?: "图片转 JPEG 失败", null)
                }
            }
        }
    }

    /// 已完成记录：按 DISPLAY_NAME 在 MediaStore 里找回文件并打开。
    private fun openMedia(call: MethodCall, result: MethodChannel.Result) {
        val names = call.argument<List<String>>("names") ?: emptyList()
        val uri = findMediaUris(names).firstOrNull()
        if (uri == null) {
            result.error("not_found", "找不到已保存的文件，可能已被移动或删除", null)
            return
        }
        try {
            val mime = contentResolver.getType(uri) ?: "*/*"
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("open_failed", e.message, null)
        }
    }

    /// 已保存文件分享：单文件 ACTION_SEND，多文件 ACTION_SEND_MULTIPLE。
    private fun shareMedia(call: MethodCall, result: MethodChannel.Result) {
        val names = call.argument<List<String>>("names") ?: emptyList()
        val uris = findMediaUris(names)
        if (uris.isEmpty()) {
            result.error("not_found", "找不到已保存的文件，可能已被移动或删除", null)
            return
        }
        try {
            val mimes = uris.map { contentResolver.getType(it) ?: "*/*" }
            val mime = when {
                mimes.all { it.startsWith("image/") } -> "image/*"
                mimes.all { it.startsWith("video/") } -> "video/*"
                else -> "*/*"
            }
            val intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uris.first())
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = mime
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
                }
            }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(Intent.createChooser(intent, "分享"))
            result.success(true)
        } catch (e: Exception) {
            result.error("share_failed", e.message, null)
        }
    }

    private fun findMediaUris(names: List<String>): List<Uri> {
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        // Gal/MediaStore 重名时会给文件名加 (1) 后缀，用前缀匹配兜底。
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? OR " +
                "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ? ESCAPE '\\'"
        val out = mutableListOf<Uri>()
        for (name in names) {
            if (name.isBlank()) {
                continue
            }
            val escaped = name
                .replace("\\", "\\\\")
                .replace("%", "\\%")
                .replace("_", "\\_")
            try {
                contentResolver
                    .query(
                        collection,
                        projection,
                        selection,
                        arrayOf(name, "$escaped%"),
                        "${MediaStore.MediaColumns.DATE_ADDED} DESC",
                    )
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            out.add(ContentUris.withAppendedId(collection, cursor.getLong(0)))
                        }
                    }
            } catch (_: Exception) {
                // 单个文件查询失败不影响其余文件。
            }
        }
        return out
    }

    /// 用 FileProvider 把缓存的 APK 交给系统安装器。
    /// Android 8+ 首次使用需用户允许「安装未知应用」，被拒时系统会自行提示。
    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("安装包不存在")
        }
        val uri = FileProvider.getUriForFile(
            applicationContext,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
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
        unregisterConnectivity()
        awaitingPermission = false
        pendingPick?.let {
            it.error("activity_destroyed", "页面已销毁，选择未完成", null)
            pendingPick = null
        }
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
