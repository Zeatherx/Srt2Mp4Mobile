package com.example.srt2mp4_mobile

import android.app.Activity
import android.content.ContentValues
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Publishes finished MP4s on an I/O worker. Never requests all-files access. */
class VideoExporter(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "srt2mp4_mobile/video_export")
    private val worker = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private val publishing = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    // Accessed only by the single worker. Cancellation can delete only exports
    // created by this engine, never an arbitrary URI supplied over the channel.
    private val ownedExports = mutableSetOf<String>()

    @Suppress("DEPRECATION")
    private fun exportDirectory() = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
        "srt2mp4/export"
    )

    init {
        channel.setMethodCallHandler { call, result ->
            if (closed.get()) {
                result.error("EXPORT_CLOSED", "Video storage has been closed. Reopen the screen.", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "getExportInfo" -> {
                    if (Environment.getExternalStorageState() != Environment.MEDIA_MOUNTED) {
                        result.error("STORAGE_UNAVAILABLE", "Shared video storage is unavailable.", null)
                    } else {
                        result.success(mapOf("sdkInt" to Build.VERSION.SDK_INT,
                            "directory" to exportDirectory().absolutePath))
                    }
                }
                "cancelExport" -> {
                    cancelled.set(true)
                    result.success(null)
                }
                "publishVideo" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val name = call.argument<String>("fileName")
                    if (sourcePath == null || name == null ||
                        !Regex("^subtitled_[0-9]+\\.mp4$").matches(name)) {
                        result.error("INVALID_EXPORT", "Invalid video export request.", null)
                    } else if (!publishing.compareAndSet(false, true)) {
                        result.error("EXPORT_BUSY", "A video export is already running.", null)
                    } else {
                        cancelled.set(false)
                        submit(result) {
                            try {
                                val source = File(sourcePath).canonicalFile
                                val staging = File(activity.cacheDir, "srt2mp4_encoding").canonicalFile
                                require(source.parentFile == staging && source.isFile && source.length() > 0) {
                                    "The encoded video is unavailable."
                                }
                                val exported = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    publishMediaStore(source, name)
                                } else {
                                    publishLegacy(source, name)
                                }
                                publishing.set(false)
                                activity.runOnUiThread { result.success(exported) }
                            } catch (error: Exception) {
                                val code = if (cancelled.get()) "EXPORT_CANCELLED" else "EXPORT_FAILED"
                                publishing.set(false)
                                activity.runOnUiThread {
                                    result.error(code, error.message ?: "Could not export the video.", null)
                                }
                            }
                        }
                    }
                }
                "deleteExport" -> {
                    val value = call.argument<String>("uri")
                    submit(result) {
                        try {
                            require(value != null && ownedExports.contains(value)) {
                                "This export is not owned by the current job."
                            }
                            val uri = Uri.parse(value)
                            if (uri.scheme == "content") {
                                activity.contentResolver.delete(uri, null, null)
                            } else {
                                val file = File(requireNotNull(uri.path))
                                require(file.canonicalFile.parentFile == exportDirectory().canonicalFile)
                                if (file.exists() && !file.delete()) throw IOException("Could not delete cancelled export.")
                                MediaScannerConnection.scanFile(activity, arrayOf(file.path), null, null)
                            }
                            ownedExports.remove(value)
                            activity.runOnUiThread { result.success(null) }
                        } catch (error: Exception) {
                            activity.runOnUiThread { result.error("DELETE_FAILED", error.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun checkCancellation() {
        if (cancelled.get()) throw IOException("Video export cancelled.")
    }

    private fun submit(result: MethodChannel.Result, action: () -> Unit) {
        try {
            worker.execute(action)
        } catch (_: RejectedExecutionException) {
            publishing.set(false)
            result.error("EXPORT_CLOSED", "Video storage has been closed. Reopen the screen.", null)
        }
    }

    private fun rememberExport(uri: String) {
        ownedExports.add(uri)
        // Only recent exports can need cancellation rollback.
        if (ownedExports.size > 64) ownedExports.remove(ownedExports.first())
    }

    private fun copyVideo(source: File, output: OutputStream) {
        output.use { target ->
            source.inputStream().use { input ->
                val buffer = ByteArray(1024 * 1024)
                var transferred = 0L
                while (true) {
                    checkCancellation()
                    val read = input.read(buffer)
                    if (read < 0) break
                    target.write(buffer, 0, read)
                    transferred += read
                }
                target.flush()
                if (transferred != source.length()) throw IOException("The exported video is incomplete.")
            }
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun publishMediaStore(source: File, name: String): Map<String, Any> {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/srt2mp4/export/")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        checkCancellation()
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: throw IOException("Could not create the public video.")
        try {
            val stream = resolver.openOutputStream(uri, "w") ?: throw IOException("Could not open video storage.")
            copyVideo(source, stream)
            checkCancellation()
            // Query the assigned filename to account for collision handling.
            val actualName = resolver.query(uri, arrayOf(MediaStore.Video.Media.DISPLAY_NAME),
                null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                } ?: name
            val visible = ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }
            if (resolver.update(uri, visible, null, null) != 1) {
                throw IOException("Could not finalize the public video.")
            }
            rememberExport(uri.toString())
            return mapOf("uri" to uri.toString(), "path" to File(exportDirectory(), actualName).absolutePath,
                "size" to source.length())
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
                .onFailure { Log.w("VideoExporter", "Could not remove incomplete video", it) }
            throw error
        }
    }

    private fun publishLegacy(source: File, name: String): Map<String, Any> {
        val directory = exportDirectory()
        if (!directory.exists() && !directory.mkdirs()) throw IOException("Could not create the export directory.")
        val destination = File(directory, name)
        // Reserve a new filename rather than overwriting any user video.
        if (!destination.createNewFile()) throw IOException("An export with this name already exists. Please retry.")
        try {
            copyVideo(source, destination.outputStream())
            checkCancellation()
            MediaScannerConnection.scanFile(activity, arrayOf(destination.path), arrayOf("video/mp4"), null)
            val uri = Uri.fromFile(destination).toString()
            rememberExport(uri)
            return mapOf("uri" to uri, "path" to destination.absolutePath, "size" to destination.length())
        } catch (error: Exception) {
            if (!destination.delete()) Log.w("VideoExporter", "Could not remove incomplete legacy export")
            throw error
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        cancelled.set(true)
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
