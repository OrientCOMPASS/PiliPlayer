package com.example.piliplus

import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        // content:// 导出的 fd -> 句柄。Dart 侧播放页退出后调 closeFd/closeAllFds
        // 关闭; 兜底: 同时挂起的 fd 超过 MAX_OPEN_FDS 时按**打开顺序**(LinkedHashMap)
        // 关掉最旧的, 防止异常路径泄漏。
        //
        // 上限从 4 提到 16: ① SAF 目录里播一个视频会同时挂上视频本体与若干
        // 外挂字幕的 fd; ② 应用内画中画(小窗)期间会长期占着一个 fd, 而用户
        // 还在应用里继续浏览/播放别的文件 —— 上限太小会把正在用的挤掉
        // (mpv 拿到的是裸 fd, 句柄被关就是 EBADF)。
        private const val MAX_OPEN_FDS = 16

        private val openFds = object : LinkedHashMap<Int, ParcelFileDescriptor>() {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<Int, ParcelFileDescriptor>?
            ): Boolean {
                if (size > MAX_OPEN_FDS) {
                    try {
                        eldest?.value?.close()
                    } catch (e: Throwable) {
                    }
                    return true
                }
                return false
            }
        }

        private const val REQ_PICK_TREE = 0x5171

        /**
         * FlutterEngine 的 messenger, 给 PipActivity 用: 系统画中画跑在**独立
         * Activity**里(见 PipActivity 头注释), 它没有自己的引擎, 但要把
         * surface 就绪/展开/关闭这些事件送回同一个 Dart isolate。
         */
        // 注意: 不能写 `private set` —— 那样 setter 只在 companion 内部可见,
        // configureFlutterEngine(外部类)就赋不了值了。
        @Volatile
        var dartMessenger: BinaryMessenger? = null
    }

    private var pendingTreePick: MethodChannel.Result? = null

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
        dartMessenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "piliplus/local_media"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // 系统「用其他应用打开/分享」的视频: content:// 导出 fd,
                // Dart 侧以 fd://N 交给 mpv(fd 协议); file:// 直接回路径。
                // SAF(系统文件夹授权)浏览到的条目同样走这里 —— content://
                // document uri 就是它。
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
                                    synchronized(openFds) { openFds[pfd.fd] = pfd }
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
                // 播放页退出/切换来源时一次性回收, 避免 SAF 播放把 fd 攒满
                "closeAllFds" -> {
                    val handler = Handler(Looper.getMainLooper())
                    Thread {
                        synchronized(openFds) {
                            for (pfd in openFds.values) {
                                try {
                                    pfd.close()
                                } catch (e: Throwable) {
                                }
                            }
                            openFds.clear()
                        }
                        handler.post { result.success(true) }
                    }.start()
                }

                // ==================== SAF 目录浏览(第十九轮) ====================
                // 作用域存储下 dart:io 只能看到媒体文件, 用户"文件管理器里有、
                // 应用里找不到"就是这个原因; 走系统「选择文件夹」授权后, 用
                // DocumentsContract 列目录能看到该树下的全部条目。
                "safSupported" -> result.success(SafBrowser.isSupported())

                "safPickTree" -> {
                    if (pendingTreePick != null) {
                        result.error("busy", "already picking", null)
                    } else {
                        pendingTreePick = result
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                val initial = call.argument<String>("initialUri")
                                if (!initial.isNullOrEmpty() &&
                                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                                ) {
                                    try {
                                        putExtra(
                                            DocumentsContract.EXTRA_INITIAL_URI,
                                            Uri.parse(initial)
                                        )
                                    } catch (e: Throwable) {
                                    }
                                }
                            }
                            startActivityForResult(intent, REQ_PICK_TREE)
                        } catch (e: Throwable) {
                            pendingTreePick = null
                            result.error("no_picker", e.message, null)
                        }
                    }
                }

                "safTrees" -> onWorker(result) {
                    SafBrowser.persistedTrees(contentResolver)
                }

                "safList" -> {
                    val uriStr = call.argument<String>("uri")
                    val docId = call.argument<String>("docId")
                    if (uriStr == null) {
                        result.error("bad_args", "uri required", null)
                    } else {
                        onWorker(result) {
                            SafBrowser.listChildren(contentResolver, Uri.parse(uriStr), docId)
                        }
                    }
                }

                "safReleaseTree" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("bad_args", "uri required", null)
                    } else {
                        onWorker(result) {
                            SafBrowser.releaseTree(contentResolver, Uri.parse(uriStr))
                        }
                    }
                }

                "safHasAllFilesAccess" -> onWorker(result) { SafBrowser.hasAllFilesAccess() }

                "safOpenAllFilesSettings" -> result.success(
                    SafBrowser.openAllFilesAccessSettings(this)
                )

                else -> result.notImplemented()
            }
        }

        // 系统画中画(独立 PiP Activity, 见 PipActivity): Dart 侧只需要
        // "起窗口 / 关窗口 / 窗口还在不在", surface 与 mpv 的 wid 交接由
        // PipActivity 通过同一个通道反向推给 Dart。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PipChannel.NAME
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                PipChannel.START -> result.success(
                    PipLauncher.start(
                        this,
                        call.argument<Int>("width") ?: 16,
                        call.argument<Int>("height") ?: 9,
                        call.argument<String>("title")
                    )
                )

                PipChannel.STOP -> {
                    PipActivity.finishCurrent()
                    result.success(true)
                }

                PipChannel.IS_ALIVE -> result.success(PipActivity.isAlive())

                else -> result.notImplemented()
            }
        }

        // 手柄摇杆是 MotionEvent 模拟轴, 不会自动进 Flutter 的按键通道;
        // 这里缓存最新读数, VR 操作模式下由 Dart 轮询(见 Gamepad / VrControlLayer)。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "piliplus/gamepad"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "readAxes" -> result.success(Gamepad.snapshot())
                "reset" -> {
                    Gamepad.reset()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** ContentResolver 查询一律离开主线程; 结果回主线程交给 Dart */
    private fun onWorker(result: MethodChannel.Result, block: () -> Any?) {
        val handler = Handler(Looper.getMainLooper())
        Thread {
            try {
                val value = block()
                handler.post { result.success(value) }
            } catch (e: SafBrowser.SafException) {
                handler.post { result.error("saf_error", e.message, null) }
            } catch (e: Throwable) {
                handler.post { result.error("saf_failed", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_TREE) {
            val pending = pendingTreePick
            pendingTreePick = null
            if (pending != null) {
                val uri = data?.data
                if (resultCode == Activity.RESULT_OK && uri != null) {
                    val handler = Handler(Looper.getMainLooper())
                    Thread {
                        try {
                            val info = SafBrowser.persistTree(contentResolver, uri)
                            handler.post { pending.success(info) }
                        } catch (e: SafBrowser.SafException) {
                            handler.post { pending.error("saf_error", e.message, null) }
                        } catch (e: Throwable) {
                            handler.post {
                                pending.error("saf_failed", e.message ?: e.toString(), null)
                            }
                        }
                    }.start()
                } else {
                    // 用户取消: 明确回 null, Dart 侧不当成错误
                    pending.success(null)
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
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

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        try {
            Gamepad.onGenericMotionEvent(event)
        } catch (e: Throwable) {
        }
        return super.dispatchGenericMotionEvent(event)
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
