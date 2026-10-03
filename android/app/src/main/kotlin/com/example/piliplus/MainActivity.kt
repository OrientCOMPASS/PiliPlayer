package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.view.KeyEvent
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        // content:// 导出的 fd -> 句柄。Dart 侧播放页退出后调 closeFd 关闭;
        // 兜底: 同时挂起的 fd 超过 4 个时关掉最旧的(防止异常路径泄漏)。
        private val openFds = HashMap<Int, ParcelFileDescriptor>()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "piliplus/local_media"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // 系统「用其他应用打开/分享」的视频: content:// 导出 fd,
                // Dart 侧以 fd://N 交给 mpv(fd 协议); file:// 直接回路径。
                "resolveContentMedia" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("bad_args", "uri required", null)
                    } else {
                        val handler = Handler(Looper.getMainLooper())
                        Thread {
                            try {
                                val parsed = Uri.parse(uriStr)
                                var name: String? = null
                                contentResolver.query(
                                    parsed,
                                    arrayOf(OpenableColumns.DISPLAY_NAME),
                                    null, null, null
                                )?.use { c ->
                                    if (c.moveToFirst()) name = c.getString(0)
                                }
                                if (name.isNullOrEmpty()) name = parsed.lastPathSegment
                                val out = HashMap<String, Any>()
                                out["name"] = if (name.isNullOrEmpty()) "视频" else name!!
                                if (parsed.scheme == "content") {
                                    val pfd = contentResolver.openFileDescriptor(parsed, "r")
                                        ?: error("openFileDescriptor returned null")
                                    synchronized(openFds) {
                                        if (openFds.size >= 4) {
                                            openFds.keys.minOrNull()?.let { oldest ->
                                                openFds.remove(oldest)?.close()
                                            }
                                        }
                                        openFds[pfd.fd] = pfd
                                    }
                                    out["fd"] = pfd.fd
                                } else {
                                    out["path"] = parsed.path ?: ""
                                }
                                handler.post { result.success(out) }
                            } catch (e: Exception) {
                                handler.post { result.error("resolve_failed", e.message, null) }
                            }
                        }.start()
                    }
                }
                "closeFd" -> {
                    val fd = call.argument<Int>("fd")
                    if (fd == null) {
                        result.success(true)
                    } else {
                        val handler = Handler(Looper.getMainLooper())
                        Thread {
                            synchronized(openFds) { openFds.remove(fd)?.close() }
                            handler.post { result.success(true) }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }


    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode

        if (keyCode == KeyEvent.KEYCODE_BUTTON_B || keyCode == KeyEvent.KEYCODE_BUTTON_C) {
            val backEvent = KeyEvent(
                event.downTime, event.eventTime, event.action,
                KeyEvent.KEYCODE_BACK, event.repeatCount, event.metaState,
                event.deviceId, event.scanCode, event.flags, event.source
            )
            return super.dispatchKeyEvent(backEvent)
        }

        if (keyCode == KeyEvent.KEYCODE_BUTTON_MODE || keyCode == KeyEvent.KEYCODE_BUTTON_START) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                moveTaskToBack(true) 
            }
            return true 
        }

        return super.dispatchKeyEvent(event)
    }
}
