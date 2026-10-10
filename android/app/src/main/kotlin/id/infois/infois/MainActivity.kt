package id.infois.infois

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Menyimpan file unduhan (PDF nota, lampiran, file dari Tim AI) ke folder
 * Download HP supaya mudah dicari di aplikasi Berkas.
 *
 * Android 10+ memakai MediaStore (tanpa izin penyimpanan); Android 9 ke bawah
 * menulis ke folder Download publik (izin WRITE_EXTERNAL_STORAGE, diminta dari
 * Dart bila belum ada: galat "permission").
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "id.infois/downloads").setMethodCallHandler { call, result ->
            if (call.method != "saveToDownloads") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val name = call.argument<String>("name")
            val mime = call.argument<String>("mime") ?: "application/octet-stream"
            if (path == null || name == null) {
                result.error("argument", "path dan name wajib", null)
                return@setMethodCallHandler
            }
            Thread {
                try {
                    val saved = saveToDownloads(File(path), name, mime)
                    runOnUiThread { result.success(saved) }
                } catch (error: SecurityException) {
                    runOnUiThread { result.error("permission", error.message, null) }
                } catch (error: Exception) {
                    runOnUiThread { result.error("failed", error.message, null) }
                }
            }.start()
        }
    }

    private fun saveToDownloads(source: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Folder Download tidak tersedia")
            try {
                val output = resolver.openOutputStream(uri) ?: throw IllegalStateException("File tidak bisa ditulis")
                output.use { out -> FileInputStream(source).use { input -> input.copyTo(out) } }
                val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                resolver.update(uri, done, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    return cursor.getString(0) ?: name
                }
            }
            return name
        }

        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("Izin penyimpanan belum diberikan")
        }
        @Suppress("DEPRECATION")
        val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        directory.mkdirs()
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var target = File(directory, name)
        var counter = 1
        while (target.exists()) {
            target = File(directory, "$base ($counter)$extension")
            counter++
        }
        source.copyTo(target)
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), arrayOf(mime), null)
        return target.name
    }
}
