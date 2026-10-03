package com.example.piliplus

import android.app.Activity
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Intent
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Rational
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout
import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper
import io.flutter.plugin.common.MethodChannel

/**
 * 系统画中画专用的**独立 Activity** —— 第二十轮 需求2。
 *
 * 为什么要单独一个 Activity: 系统 PiP 收起的是"调用 enterPictureInPictureMode
 * 的那个 Activity"。本工程的主 Activity 是 FlutterActivity, 一旦它进 PiP,
 * 整个应用(所有 Flutter 页面)都被塞进小窗里, 应用内没法继续浏览。
 * moonlight-android 能做到"PiP 时继续浏览", 正是因为串流跑在独立的
 * `Game` Activity 里(manifest: supportsPictureInPicture + singleTask +
 * excludeFromRecents + noHistory), 主界面 `PcView` 是另一个 Activity。
 * 这里照搬同一套结构。
 *
 * 画面怎么过来: Flutter 是单 Activity/单引擎, 视频由 mpv 渲染进 media_kit 在
 * Flutter 纹理注册表里创建的 Surface。所以进 PiP 时把 mpv 的 `--wid`
 * (一个指向 android.view.Surface 的 JNI 全局引用指针, 见 media_kit 的
 * VideoOutput.createSurface)改指到**本 Activity 的 SurfaceView**, 按 media_kit
 * 自己的顺序做 `vo=null -> wid=<新> -> vo=gpu`; 退出 PiP 再指回原来那个。
 * 播放器实例全程不重建: 不重新拉流、不丢进度、不重新缓冲。
 *
 * 与 Dart 的通信走 `piliplus/pip` 通道(同一个 FlutterEngine 的 messenger,
 * 由 MainActivity 缓存): 本 Activity 把 surface 就绪/失效、展开、关闭等事件
 * 推给 Dart, Dart 反过来调 start/stop。
 */
class PipActivity : Activity(), SurfaceHolder.Callback {

    companion object {
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_TITLE = "title"

        /** surfaceDestroyed 里等 Dart 把 mpv 从这个 surface 上摘下来的时间。
         *  回调返回之后 surface 随时失效, 继续往里渲染就是 use-after-free;
         *  Dart 在 UI isolate 上跑(不依赖主线程), 所以短暂阻塞主线程是安全的。 */
        private const val DETACH_WAIT_MS = 260L

        @Volatile
        private var instance: PipActivity? = null

        /** Dart 侧兜底: 需要强制关掉 PiP 窗口时用 */
        fun finishCurrent() {
            val activity = instance
            if (activity != null && !activity.isFinishing) {
                activity.finish()
            }
        }

        fun isAlive(): Boolean = instance != null
    }

    private var wid: Long = 0
    private var inPip = false
    private var pipRequested = false

    /** 已经通知过 Dart"用户展开了", 避免 onStop/onDestroy 再补一发"关闭" */
    private var expandedNotified = false

    /** 已经通知过 Dart"窗口被关掉了" */
    private var closedNotified = false

    private lateinit var surfaceView: SurfaceView
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        val root = FrameLayout(this)
        root.setBackgroundColor(0xFF000000.toInt())
        root.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        setContentView(root)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onResume() {
        super.onResume()
        updatePipParams(autoEnter = true)
        // 这个 Activity 生来就是为了当 PiP 窗口的: 一可见就进 PiP
        if (!pipRequested) {
            pipRequested = true
            enterPipNow()
        }
    }

    private fun enterPipNow() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            notifyDart("onFailed", mapOf("reason" to "sdk<26"))
            finish()
            return
        }
        try {
            // 必须用带 params 的重载: 无参版返回 void(Kotlin 里没法当布尔用),
            // 而且显式进入时 params 里不能带 autoEnterEnabled(那是"用户离开时
            // 自动进入"的开关, 两处都开会让系统拒掉这次调用)。
            val params = buildPipParams(autoEnter = false)
            if (params == null) {
                notifyDart("onFailed", mapOf("reason" to "params=null"))
                finish()
                return
            }
            if (!enterPictureInPictureMode(params)) {
                notifyDart("onFailed", mapOf("reason" to "enterPictureInPictureMode=false"))
                finish()
            }
        } catch (e: Throwable) {
            notifyDart("onFailed", mapOf("reason" to (e.message ?: e.javaClass.simpleName)))
            finish()
        }
    }

    private fun updatePipParams(autoEnter: Boolean) {
        val params = buildPipParams(autoEnter) ?: return
        try {
            setPictureInPictureParams(params)
        } catch (e: Throwable) {
        }
    }

    private fun buildPipParams(autoEnter: Boolean): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val w = intent.getIntExtra(EXTRA_WIDTH, 16).coerceIn(1, 4096)
        val h = intent.getIntExtra(EXTRA_HEIGHT, 9).coerceIn(1, 4096)
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(w, h))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnter)
            try {
                builder.setSeamlessResizeEnabled(true)
            } catch (e: Throwable) {
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val title = intent.getStringExtra(EXTRA_TITLE)
            if (!title.isNullOrEmpty()) {
                builder.setTitle(title)
            }
        }
        addMediaActions(builder)
        return builder.build()
    }

    /** PiP 窗口的系统按钮: 快退 / 播放暂停 / 快进(与 AndroidHelper 同一套媒体键) */
    private fun addMediaActions(builder: PictureInPictureParams.Builder) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mbr = try {
            MediaHelper.getMediaButtonReceiverComponent(this)
        } catch (e: Throwable) {
            null
        } ?: return
        val actions = ArrayList<RemoteAction>(3)
        addAction(actions, mbr, R.drawable.ic_player_rewind_10s, "ACTION_REWIND",
            PlaybackState.ACTION_REWIND.toInt())
        addAction(actions, mbr, R.drawable.ic_player_play, "ACTION_PLAY_PAUSE",
            PlaybackState.ACTION_PLAY_PAUSE.toInt())
        addAction(actions, mbr, R.drawable.ic_player_fast_forward_10s, "ACTION_FAST_FORWARD",
            PlaybackState.ACTION_FAST_FORWARD.toInt())
        builder.setActions(actions)
    }

    private fun addAction(
        actions: ArrayList<RemoteAction>,
        mbr: android.content.ComponentName,
        iconRes: Int,
        title: String,
        playbackAction: Int
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val pending = try {
            MediaHelper.buildMediaButtonPendingIntent(this, mbr, playbackAction)
        } catch (e: Throwable) {
            null
        } ?: return
        try {
            actions.add(
                RemoteAction(
                    Icon.createWithResource(this, iconRes),
                    title,
                    title,
                    pending
                )
            )
        } catch (e: Throwable) {
        }
    }

    // ==================== Surface: mpv 的渲染目标 ====================

    override fun surfaceCreated(holder: SurfaceHolder) {
        releaseWid()
        wid = try {
            MediaKitAndroidHelper.newGlobalObjectRef(holder.surface)
        } catch (e: Throwable) {
            0L
        }
        // 首次 = 交接; 之后(PiP 尺寸变化导致 surface 重建) = 重新交接
        notifyDart("onSurfaceReady", mapOf("wid" to wid))
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // 窗口尺寸变化: vo=gpu 自己会跟着窗口重配, 这里只把尺寸告诉 Dart 备查
        notifyDart(
            "onSurfaceChanged",
            mapOf("wid" to wid, "width" to width, "height" to height)
        )
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        notifyDart("onSurfaceLost", mapOf("wid" to wid))
        try {
            // 等 Dart 把 mpv 摘下来(见 DETACH_WAIT_MS 注释)
            Thread.sleep(DETACH_WAIT_MS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        releaseWid()
    }

    private fun releaseWid() {
        val old = wid
        wid = 0
        if (old != 0L) {
            try {
                MediaKitAndroidHelper.deleteGlobalObjectRef(old)
            } catch (e: Throwable) {
            }
        }
    }

    // ==================== PiP 生命周期 ====================

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        val wasInPip = inPip
        inPip = isInPictureInPictureMode
        notifyDart("onPipModeChanged", mapOf("inPip" to isInPictureInPictureMode))
        if (wasInPip && !isInPictureInPictureMode && !expandedNotified && !isFinishing) {
            // 用户点了 PiP 窗口的"展开": 画面交还 Flutter 播放页
            expandedNotified = true
            notifyDart("onExpanded", null)
        }
        updatePipParams(autoEnter = isInPictureInPictureMode)
    }

    override fun onStop() {
        super.onStop()
        if (inPip && !expandedNotified && !closedNotified) {
            // 还在 PiP 状态就被 stop = 窗口被划掉/关掉: 播放该结束了
            closedNotified = true
            notifyDart("onClosed", null)
        }
    }

    override fun onDestroy() {
        if (!expandedNotified && !closedNotified) {
            closedNotified = true
            notifyDart("onClosed", null)
        }
        releaseWid()
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 从 PiP 展开态按 Home: 再收回去(与主 Activity 的自动画中画一致)
        if (!inPip && !isFinishing) {
            enterPipNow()
        }
    }

    // ==================== 与 Dart 通信 ====================

    private fun notifyDart(method: String, args: Map<String, Any>?) {
        val messenger = MainActivity.dartMessenger ?: return
        mainHandler.post {
            try {
                MethodChannel(messenger, PipChannel.NAME).invokeMethod(method, args)
            } catch (e: Throwable) {
                // 引擎已销毁(应用被杀)之类: PiP 窗口自己收尾即可
            }
        }
    }
}

/** Dart <-> PiP Activity 的通道名与命令(集中一处, 免得两边写串) */
object PipChannel {
    const val NAME = "piliplus/pip"
    const val START = "start"
    const val STOP = "stop"
    const val IS_ALIVE = "isAlive"
}

/** 供 MainActivity 调用: 启动 PiP Activity(独立任务, 不打扰主 Activity) */
object PipLauncher {
    fun start(
        activity: Activity,
        width: Int,
        height: Int,
        title: String?
    ): Boolean {
        return try {
            val intent = Intent(activity, PipActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                putExtra(PipActivity.EXTRA_WIDTH, width)
                putExtra(PipActivity.EXTRA_HEIGHT, height)
                if (!title.isNullOrEmpty()) putExtra(PipActivity.EXTRA_TITLE, title)
            }
            activity.startActivity(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }
}
