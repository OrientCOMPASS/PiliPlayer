package com.example.piliplus

import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer

/**
 * B 站缓存「导出到本地」(第二十七轮)。
 *
 * B 站的 DASH 缓存是分离流: video.m4s(纯视频 fMP4) + audio.m4s(纯音频 fMP4),
 * 文件管理器/相册都认不出来。这里用 MediaExtractor + MediaMuxer 做**流级合并**
 * (只是重新封装, 不转码, 速度基本等于磁盘读写), 产物写到系统「下载」目录:
 *   * Android 10+: MediaStore.Downloads(作用域存储下无需任何存储权限);
 *   * Android 9-: 直写 /sdcard/Download(需要 WRITE_EXTERNAL_STORAGE,
 *     Dart 侧已按 sdkInt 提前申请) + 通知媒体库扫描。
 *
 * Type1 缓存(单个 0.mp4, 音视频本来就已合并)直接字节拷贝, 不动内容。
 *
 * 通道 `piliplus/media_mux`:
 *   * Dart -> 原生: exportToDownloads / cancelExport;
 *   * 原生 -> Dart: onExportProgress(节流 200ms)。
 */
object MediaMuxExport {

    /** 单样本缓冲。8K HEVC 关键帧一般 <2MB, 4MB 足够; 真超了由异常路径兜底 */
    private const val BUFFER_BYTES = 4 * 1024 * 1024
    private const val COPY_BUFFER_BYTES = 256 * 1024
    private const val PROGRESS_INTERVAL_MS = 200L

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var running = false

    @Volatile
    private var cancelRequested = false

    private var channel: MethodChannel? = null

    private class CancelledException : Exception("cancelled")

    /** 编码/轨道等"换台设备也没法导"的问题, Dart 侧转成可读提示 */
    private class UnsupportedException(message: String) : Exception(message)

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        val ch = MethodChannel(messenger, "piliplus/media_mux")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "exportToDownloads" -> {
                    val videoPath = call.argument<String>("videoPath")
                    val audioPath = call.argument<String>("audioPath")
                    val displayName = call.argument<String>("displayName")
                    // copy=true: 源已是合流单文件 mp4(Type1 的 0.mp4), 直接字节拷贝;
                    // 否则一律走 MediaExtractor/MediaMuxer 重新封装(m4s 是 fMP4,
                    // 哪怕没有音频轨也要 remux 成普通 MP4 才能被相册等识别)
                    val copyOnly = call.argument<Boolean>("copy") ?: false
                    when {
                        videoPath.isNullOrEmpty() || displayName.isNullOrEmpty() ->
                            result.error("bad_args", "videoPath/displayName required", null)
                        running ->
                            result.error("busy", "another export in progress", null)
                        else ->
                            startExport(
                                appContext, videoPath, audioPath,
                                copyOnly, displayName, result
                            )
                    }
                }
                "cancelExport" -> {
                    cancelRequested = true
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startExport(
        context: Context,
        videoPath: String,
        audioPath: String?,
        copyOnly: Boolean,
        displayName: String,
        result: MethodChannel.Result
    ) {
        running = true
        cancelRequested = false
        Thread {
            var out: Output? = null
            try {
                out = Output.create(context, displayName)
                try {
                    if (copyOnly && audioPath.isNullOrEmpty()) {
                        copyStream(File(videoPath), out)
                    } else {
                        muxStreams(videoPath, audioPath, out)
                    }
                } finally {
                    out.closeRaw()
                }
                if (cancelRequested) {
                    out.discard(context)
                    mainHandler.post { result.success(mapOf("ok" to false, "cancelled" to true)) }
                } else {
                    val name = out.publish(context)
                    val uri = out.uri?.toString() ?: ""
                    mainHandler.post {
                        result.success(mapOf("ok" to true, "name" to name, "uri" to uri))
                    }
                }
            } catch (e: CancelledException) {
                out?.discard(context)
                mainHandler.post { result.success(mapOf("ok" to false, "cancelled" to true)) }
            } catch (e: UnsupportedException) {
                out?.discard(context)
                val msg = e.message ?: "unsupported"
                mainHandler.post { result.error("unsupported", msg, null) }
            } catch (e: Throwable) {
                out?.discard(context)
                val msg = e.message ?: e.toString()
                mainHandler.post { result.error("export_failed", msg, null) }
            } finally {
                running = false
            }
        }.start()
    }

    // ==================== 合流(DASH 分离流) ====================

    /** [audioPath] 为 null 时只重封装视频轨(无音轨缓存的兜底) */
    private fun muxStreams(videoPath: String, audioPath: String?, out: Output) {
        val videoFile = File(videoPath)
        if (!videoFile.exists()) throw IOException("视频流文件不存在: $videoPath")
        val audioFile = audioPath?.let { File(it) }
        if (audioFile != null && !audioFile.exists()) {
            throw IOException("音频流文件不存在: $audioPath")
        }
        val totalBytes = videoFile.length() + (audioFile?.length() ?: 0L)

        val videoExtractor = MediaExtractor()
        val audioExtractor = if (audioFile != null) MediaExtractor() else null
        var muxer: MediaMuxer? = null
        try {
            videoExtractor.setDataSource(videoPath)
            val videoIndex = selectTrack(videoExtractor, "video/")
                ?: throw UnsupportedException("视频流里找不到视频轨")
            val videoFormat = videoExtractor.getTrackFormat(videoIndex)
            videoExtractor.selectTrack(videoIndex)

            var audioFormat: MediaFormat? = null
            if (audioExtractor != null && audioFile != null) {
                audioExtractor.setDataSource(audioFile.absolutePath)
                val audioIndex = selectTrack(audioExtractor, "audio/")
                    ?: throw UnsupportedException("音频流里找不到音频轨")
                audioFormat = audioExtractor.getTrackFormat(audioIndex)
                audioExtractor.selectTrack(audioIndex)
            }

            muxer = out.newMuxer()
            val videoTrackOut: Int
            var audioTrackOut = -1
            try {
                videoTrackOut = muxer.addTrack(videoFormat)
                if (audioFormat != null) {
                    audioTrackOut = muxer.addTrack(audioFormat)
                }
            } catch (e: IllegalArgumentException) {
                throw UnsupportedException("当前音视频编码不支持导出为 MP4: ${e.message}")
            }
            if (videoFormat.containsKey(MediaFormat.KEY_ROTATION)) {
                val rotation = videoFormat.getInteger(MediaFormat.KEY_ROTATION)
                if (rotation != 0) {
                    muxer.setOrientationHint(rotation)
                }
            }
            muxer.start()

            // 双流按时间戳交错写入(先写时间戳小的), 保证产物交织良好可拖动
            val video = SampleSide(videoExtractor, videoTrackOut)
            val audio = if (audioExtractor != null && audioTrackOut >= 0) {
                SampleSide(audioExtractor, audioTrackOut)
            } else {
                null
            }
            var written = 0L
            var lastReport = 0L
            while (!video.eof || (audio != null && !audio.eof)) {
                if (cancelRequested) throw CancelledException()
                val side = when {
                    audio == null -> video
                    video.eof -> audio
                    audio.eof -> video
                    video.peekTime() <= audio.peekTime() -> video
                    else -> audio
                }
                written += side.writeNext(muxer)
                val now = SystemClock.elapsedRealtime()
                if (now - lastReport >= PROGRESS_INTERVAL_MS) {
                    lastReport = now
                    reportProgress(written, totalBytes)
                }
            }
            reportProgress(totalBytes, totalBytes)
        } finally {
            // 取消/出错时 muxer 可能一个样本都没写过, stop() 会抛, 全部吞掉;
            // 半成品文件由外层 discard() 清理
            try { muxer?.stop() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
            try { videoExtractor.release() } catch (_: Throwable) {}
            try { audioExtractor?.release() } catch (_: Throwable) {}
        }
    }

    private fun selectTrack(extractor: MediaExtractor, mimePrefix: String): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(mimePrefix)) return i
        }
        return null
    }

    /** 一路流的样本读取器: 前瞻一个样本, 供双流按时间戳交错 */
    private class SampleSide(
        private val extractor: MediaExtractor,
        private val muxTrack: Int
    ) {
        private val buffer: ByteBuffer = ByteBuffer.allocateDirect(BUFFER_BYTES)
        private val info = MediaCodec.BufferInfo()
        var eof = false
            private set
        private var primed = false

        fun peekTime(): Long {
            prime()
            return if (eof) Long.MAX_VALUE else info.presentationTimeUs
        }

        /** 写出当前样本, 返回样本字节数 */
        fun writeNext(muxer: MediaMuxer): Int {
            while (true) {
                prime()
                if (eof) return 0
                val flags = info.flags
                primed = false
                if (flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    // codec config 已在轨道 format 的 csd 里, 不能再喂给 muxer
                    extractor.advance()
                    continue
                }
                val size = info.size
                muxer.writeSampleData(muxTrack, buffer, info)
                extractor.advance()
                return size
            }
        }

        private fun prime() {
            if (primed || eof) return
            info.offset = 0
            info.size = extractor.readSampleData(buffer, 0)
            if (info.size < 0) {
                eof = true
                return
            }
            info.presentationTimeUs = extractor.sampleTime
            info.flags = extractor.sampleFlags
            primed = true
        }
    }

    // ==================== 拷贝(Type1 单文件 mp4) ====================

    private fun copyStream(src: File, out: Output) {
        if (!src.exists()) throw IOException("缓存文件不存在: ${src.absolutePath}")
        val total = src.length()
        var written = 0L
        var lastReport = 0L
        val buf = ByteArray(COPY_BUFFER_BYTES)
        val output: OutputStream = out.openWrite()
        try {
            FileInputStream(src).use { input ->
                while (true) {
                    if (cancelRequested) throw CancelledException()
                    val n = input.read(buf)
                    if (n < 0) break
                    output.write(buf, 0, n)
                    written += n
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastReport >= PROGRESS_INTERVAL_MS) {
                        lastReport = now
                        reportProgress(written, total)
                    }
                }
            }
            output.flush()
        } finally {
            // pfd 模式下 fd 所有权在 Output, 这里只 flush 不 close,
            // 由 closeRaw() 统一收口; 文件模式下正常关流
            if (out.pfd == null) {
                try { output.close() } catch (_: Throwable) {}
            }
        }
        reportProgress(total, total)
    }

    // ==================== 输出去向 ====================

    /**
     * 导出的落点。二选一:
     *  * [uri]+[pfd]: Android 10+ 的 MediaStore.Downloads 条目(先 IS_PENDING);
     *  * [file]: Android 9- 的 /sdcard/Download 直写文件。
     */
    private class Output private constructor(
        val uri: Uri?,
        val pfd: ParcelFileDescriptor?,
        val file: File?,
        private var name: String
    ) {
        companion object {
            fun create(context: Context, displayName: String): Output {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val resolver = context.contentResolver
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                        put(MediaStore.Downloads.MIME_TYPE, "video/mp4")
                        put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        ?: throw IOException("无法在系统下载目录创建文件")
                    val pfd = try {
                        resolver.openFileDescriptor(uri, "rw")
                    } catch (e: Throwable) {
                        try { resolver.delete(uri, null, null) } catch (_: Throwable) {}
                        throw e
                    }
                    if (pfd == null) {
                        try { resolver.delete(uri, null, null) } catch (_: Throwable) {}
                        throw IOException("无法打开输出文件")
                    }
                    return Output(uri, pfd, null, displayName)
                } else {
                    @Suppress("DEPRECATION")
                    val dir = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    if (!dir.exists() && !dir.mkdirs()) {
                        throw IOException("无法创建下载目录: ${dir.absolutePath}")
                    }
                    // 老系统没有 MediaStore 自动重名去重, 手动补 " (n)"
                    val base = displayName.removeSuffix(".mp4")
                    var candidate = File(dir, displayName)
                    var i = 1
                    while (candidate.exists()) {
                        candidate = File(dir, "$base ($i).mp4")
                        i++
                    }
                    return Output(null, null, candidate, candidate.name)
                }
            }
        }

        fun newMuxer(): MediaMuxer {
            val p = pfd
            return if (p != null) {
                // pfd 只在 Android 10+ 分支产生, MediaMuxer(fd) 需要 API 26+
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    MediaMuxer(p.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                } else {
                    throw UnsupportedException("当前系统版本不支持导出")
                }
            } else {
                MediaMuxer(
                    file!!.absolutePath,
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
                )
            }
        }

        fun openWrite(): OutputStream =
            if (pfd != null) {
                FileOutputStream(pfd.fileDescriptor)
            } else {
                FileOutputStream(file!!)
            }

        /** 写完收口: pfd 归 Output 管(muxer/流都不许关它) */
        fun closeRaw() {
            try { pfd?.close() } catch (_: Throwable) {}
        }

        /** 发布: MediaStore 去 IS_PENDING / 老系统通知媒体库; 返回最终显示名 */
        fun publish(context: Context): String {
            if (uri != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val resolver = context.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri, values, null, null)
                // 系统对重名会自动改成 "xxx (1).mp4", 读回真实名字给 Dart 展示
                try {
                    resolver.query(
                        uri,
                        arrayOf(MediaStore.Downloads.DISPLAY_NAME),
                        null, null, null
                    )?.use { c ->
                        if (c.moveToFirst()) {
                            c.getString(0)?.takeIf { it.isNotEmpty() }?.let { name = it }
                        }
                    }
                } catch (_: Throwable) {
                }
            } else if (file != null) {
                MediaScannerConnection.scanFile(
                    context, arrayOf(file.absolutePath), arrayOf("video/mp4"), null
                )
            }
            return name
        }

        /** 取消/失败: 半成品不能留在下载目录里 */
        fun discard(context: Context) {
            if (uri != null) {
                try { context.contentResolver.delete(uri, null, null) } catch (_: Throwable) {}
            } else {
                try { file?.delete() } catch (_: Throwable) {}
            }
        }
    }

    // ==================== 进度回传 ====================

    private fun reportProgress(written: Long, total: Long) {
        val ch = channel ?: return
        mainHandler.post {
            try {
                ch.invokeMethod("onExportProgress", mapOf("written" to written, "total" to total))
            } catch (_: Throwable) {
                // Dart 侧没挂监听(理论上不会), 丢进度无所谓
            }
        }
    }
}
