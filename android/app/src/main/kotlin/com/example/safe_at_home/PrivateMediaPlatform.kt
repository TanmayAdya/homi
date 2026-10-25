package com.example.safe_at_home

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt

class PrivateMediaPlatform(private val context: Context, private val messenger: BinaryMessenger) {
    private val worker = Executors.newSingleThreadExecutor()
    fun register() {
        MethodChannel(messenger, "safe_at_home/private_media").setMethodCallHandler { call, result ->
            worker.execute {
                try {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    val answer: Any? = when (call.method) {
                        "prepareCaptureStorage" -> { clearRawCopies(); null }
                        "clearTemporaryMedia" -> {
                            try { clearRawCopies() } finally { DraftShareCache.clear(context.cacheDir, null) }
                            null
                        }
                        "clearSharedDraftCopy" -> { DraftShareCache.clear(context.cacheDir, args["name"] as String); null }
                        "privateRootDirectory" -> File(context.noBackupFilesDir, "sah-private").apply { mkdirs() }.canonicalPath
                        "preparePrivateDirectory" -> owned(args["path"] as String).apply { check(mkdirs() || isDirectory) }.canonicalPath
                        "normalizeImage" -> {
                            val file = owned(args["path"] as String)
                            check(file.isFile && file.length() in 1..64L * 1024 * 1024)
                            encode(decode(file))
                        }
                        "editImage" -> {
                            val bytes = args["bytes"] as ByteArray
                            check(bytes.size in 1..8 * 1024 * 1024)
                            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                            check(options.outWidth in 1..2048 && options.outHeight in 1..2048)
                            val original = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: error("decode")
                            val bitmap = original.copy(Bitmap.Config.ARGB_8888, true) ?: error("copy")
                            if (bitmap !== original) original.recycle()
                            encode(edit(bitmap, args))
                        }
                        else -> error("method")
                    }
                    Handler(Looper.getMainLooper()).post { result.success(answer) }
                } catch (_: Exception) {
                    Handler(Looper.getMainLooper()).post {
                        result.error("PRIVATE_MEDIA_FAILED", "Private media could not be prepared.", null)
                    }
                }
            }
        }
    }
    private fun clearRawCopies() {
        val cache = context.cacheDir.canonicalFile
        val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        cache.listFiles()?.forEach { entry ->
            if (entry.canonicalFile.parentFile != cache) return@forEach
            if ((entry.isFile && entry.name.startsWith("CAP") && entry.extension.lowercase() == "jpg") ||
                (entry.isDirectory && uuid.matches(entry.name))) {
                check(entry.deleteRecursively())
            }
        }
        context.getSharedPreferences("flutter_image_picker_shared_preference", Context.MODE_PRIVATE).edit().clear().apply()
    }
    private fun owned(path: String): File {
        val file = File(path).canonicalFile
        val root = File(context.applicationInfo.dataDir).canonicalPath
        check(file.path.startsWith("$root/"))
        return file
    }
    private fun decode(file: File): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (Build.VERSION.SDK_INT >= 28) {
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                val w = info.size.width; val h = info.size.height
                check(w > 0 && h > 0 && w.toLong() * h <= 200_000_000L)
                val ratio = minOf(1.0, 2048.0 / max(w, h))
                decoder.setTargetSize(max(1, (w * ratio).roundToInt()), max(1, (h * ratio).roundToInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        check(bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outWidth.toLong() * bounds.outHeight <= 200_000_000L)
        val options = BitmapFactory.Options()
        while (max(bounds.outWidth, bounds.outHeight) / (options.inSampleSize.coerceAtLeast(1)) > 4096) {
            options.inSampleSize = options.inSampleSize.coerceAtLeast(1) * 2
        }
        var bitmap = BitmapFactory.decodeFile(file.path, options) ?: error("decode")
        val orientation = ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
        }
        if (!matrix.isIdentity) {
            val upright = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            if (upright !== bitmap) bitmap.recycle()
            bitmap = upright
        }
        val ratio = minOf(1.0, 2048.0 / max(bitmap.width, bitmap.height))
        if (ratio < 1) {
            val scaled = Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * ratio).roundToInt()), max(1, (bitmap.height * ratio).roundToInt()), true)
            if (scaled !== bitmap) bitmap.recycle()
            bitmap = scaled
        }
        return bitmap
    }
    private fun rect(value: Any?, w: Int, h: Int): RectF {
        val a = (value as List<*>).map { (it as Number).toDouble() }
        check(a.size == 4 && a.all { it.isFinite() } && a[0] >= 0 && a[1] >= 0 && a[2] > 0 && a[3] > 0 && a[0]+a[2] <= 1.000001 && a[1]+a[3] <= 1.000001)
        return RectF((a[0]*w).toFloat(), (a[1]*h).toFloat(), ((a[0]+a[2])*w).toFloat(), ((a[1]+a[3])*h).toFloat())
    }
    private fun edit(bitmap: Bitmap, args: Map<*, *>): Bitmap {
        val redactions = args["redactions"] as? List<*> ?: emptyList<Any>()
        check(redactions.size <= 20)
        val paint = Paint().apply { color = Color.BLACK; style = Paint.Style.FILL; isAntiAlias = false }
        val canvas = Canvas(bitmap)
        redactions.forEach {
            val r = rect(it, bitmap.width, bitmap.height)
            canvas.drawRect(floor(r.left), floor(r.top), ceil(r.right), ceil(r.bottom), paint)
        }
        val crop = args["crop"] ?: return bitmap
        val r = rect(crop, bitmap.width, bitmap.height)
        val x = floor(r.left).toInt().coerceAtLeast(0); val y = floor(r.top).toInt().coerceAtLeast(0)
        val w = (ceil(r.right).toInt().coerceAtMost(bitmap.width) - x)
        val h = (ceil(r.bottom).toInt().coerceAtMost(bitmap.height) - y)
        check(w >= 16 && h >= 16)
        val cropped = Bitmap.createBitmap(bitmap, x, y, w, h)
        if (cropped !== bitmap) bitmap.recycle()
        return cropped
    }
    private fun encode(bitmap: Bitmap): Map<String, Any> {
        try {
            val output = ByteArrayOutputStream()
            check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, output))
            val bytes = output.toByteArray()
            check(bytes.size <= 8 * 1024 * 1024)
            return mapOf("bytes" to bytes, "width" to bitmap.width, "height" to bitmap.height)
        } finally { bitmap.recycle() }
    }
}
