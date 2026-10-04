package com.example.piliplus

import android.app.Activity
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Intent
import android.content.res.Configuration
import android.graphics.SurfaceTexture
import android.graphics.drawable.Icon
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.Surface
import android.view.TextureView
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
 * 画面怎么过来: Flutter 是单 Activity/单引擎, 视频由 mpv 渲染进 media_kit
 * 创建的 Surface。所以进 PiP 时把 mpv 的 `--wid`(一个指向 android.view.Surface
 * 的 JNI 全局引用指针, 见 media_kit 的 VideoOutput.createSurface)改指到
 * **本 Activity 的 TextureView**, 按 media_kit 自己的顺序做
 * `vo=null -> wid=<新> -> vo=gpu`; 退出 PiP 再指回原来那个。
 * 播放器实例全程不重建: 不重新拉流、不丢进度、不重新缓冲。
 *
 * 用 TextureView 而不是 SurfaceView(第二十二轮真机反馈后的改动):
 * SurfaceView 是"在窗口上打洞"+独立图层, 进 PiP 的那段动画里窗口会被
 * 反复 resize/reparent, 系统会**销毁并重建它的 surface** —— 每次销毁我们都要
 * 阻塞等 Dart 把 mpv 摘下来(黑), 重建后再挂回去(画面), 于是真机上就是
 * "画面与黑屏来回闪烁"。TextureView 的 SurfaceTexture 只在 view 被移除时才销毁,
 * 窗口 resize/动画期间一直有效; 而且 SurfaceTexture 包出来的 Surface 正是
 * media_kit 喂给这个定制 libmpv 的同一种东西(它那边也是 SurfaceTexture),
 * 所以渲染路径是已验证过的。
 *
 * 与 Dart 的通信走 `piliplus/pip` 通道(同一个 FlutterEngine 的 messenger,
 * 由 MainActivity 缓存): 本 Activity 把 surface 就绪/失效、展开、关闭等事件
 * 推给 Dart, Dart 反过来调 start/stop。
 */
class PipActivity : Activity(), TextureView.SurfaceTextureListener {

    companion object {
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_TITLE = "title"

        /** surface 失效时等 Dart 把 mpv 摘下来的时间。
         *  回调返回之后这块 surface 随时会被回收, 继续往里渲染就是
         *  use-after-free(第二十一轮真机: 点 PiP 窗口叉号 -> app 闪退)。
         *  通知是**同步** invokeMethod 出去的(见 notifyDart), Dart 在 UI isolate
         *  上处理、setOption 是直连 FFI, 都不需要主线程, 所以这里阻塞主线程
         *  等它是安全的。200ms: Dart 侧摘除只要几毫秒, 留这么长是防它正忙。 */
        private const val DETACH_WAIT_MS = 200L

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

    /** 当前交给 mpv 的 Surface(由 TextureView 的 SurfaceTexture 包出来) */
    private var surface: Surface? = null

    /** 它对应的 JNI 全局引用指针, 也就是 mpv `--wid` 的值; 0 = 无 */
    private var wid: Long = 0

    private var inPip = false
    private var pipRequested = false

    /** 已经通知过 Dart"用户展开了", 避免 onStop/onDestroy 再补一发"关闭" */
    private var expandedNotified = false

    /** 已经通知过 Dart"窗口被关掉了" */
    private var closedNotified = false

    private lateinit var textureView: TextureView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        textureView = TextureView(this)
        textureView.surfaceTextureListener = this
        textureView.isOpaque = true
        val root = FrameLayout(this)
        root.setBackgroundColor(0xFF000000.toInt())
        root.addView(
            textureView,
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
        // autoEnter=false: 这个 Activity 是"生来就要进 PiP"的, 由 enterPipNow()
        // 显式进入; 同时开 autoEnter 会让系统再触发一次进入, 窗口来回重建。
        // 展开之后才打开 autoEnter(见 onPictureInPictureModeChanged), 那样按
        // Home 能重新缩回小窗。
        updatePipParams(autoEnter = false)
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
            // 而且显式进入时 params 里不能带 autoEnterEnabled。
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

    // ==================== 渲染目标: mpv 的 --wid ====================

    override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
        // SurfaceTexture 的默认缓冲尺寸是 1x1, 不显式设的话 mpv 只会渲染一个像素
        // (media_kit 那边也是这么做的)。这里按**窗口尺寸**设: 小窗不需要片源
        // 那么大的缓冲, 省显存也省带宽。
        try {
            st.setDefaultBufferSize(width, height)
        } catch (e: Throwable) {
        }
        val newSurface = try {
            Surface(st)
        } catch (e: Throwable) {
            null
        }
        if (newSurface == null) {
            notifyDart("onFailed", mapOf("reason" to "Surface(st)=null"))
            return
        }
        // 万一上一块 surface 还挂着(理论上不会: 中间必有 destroyed), 先摘掉
        if (wid != 0L) {
            notifyDart("onSurfaceLost", mapOf("wid" to wid))
            sleepForDetach()
            releaseSurface()
        }
        surface = newSurface
        wid = try {
            MediaKitAndroidHelper.newGlobalObjectRef(newSurface)
        } catch (e: Throwable) {
            0L
        }
        notifyDart(
            "onSurfaceReady",
            mapOf("wid" to wid, "width" to width, "height" to height)
        )
    }

    override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) {
        // PiP 窗口被拖动/缩放: TextureView 的 SurfaceTexture 不会因此重建,
        // 只要把缓冲尺寸跟上(wid 不变, 不需要重新交接)
        try {
            st.setDefaultBufferSize(width, height)
        } catch (e: Throwable) {
        }
        notifyDart(
            "onSurfaceChanged",
            mapOf("wid" to wid, "width" to width, "height" to height)
        )
    }

    override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
        // 同步通知 Dart 摘除, 然后等它落下去(见 DETACH_WAIT_MS 注释)
        notifyDart("onSurfaceLost", mapOf("wid" to wid))
        sleepForDetach()
        releaseSurface()
        // 返回 true: SurfaceTexture 由我们释放
        return true
    }

    override fun onSurfaceTextureUpdated(st: SurfaceTexture) {
        // 每帧都会回调, 什么都不做
    }

    private fun sleepForDetach() {
        try {
            Thread.sleep(DETACH_WAIT_MS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun releaseSurface() {
        val old = wid
        wid = 0
        if (old != 0L) {
            try {
                MediaKitAndroidHelper.deleteGlobalObjectRef(old)
            } catch (e: Throwable) {
            }
        }
        try {
            surface?.release()
        } catch (e: Throwable) {
        }
        surface = null
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
        releaseSurface()
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 从展开态按 Home: 再收回去(与主 Activity 的自动画中画一致)
        if (!inPip && !isFinishing) {
            enterPipNow()
        }
    }

    // ==================== 与 Dart 通信 ====================

    /**
     * 给 Dart 发事件。**必须同步发**, 不能 post 到主线程队列:
     * onStop -> surfaceDestroyed -> onDestroy 是同一次主线程调用序列, post 出去
     * 的消息要等这一串全部跑完才会被派发, 那时 surface 早已失效(第二十一轮
     * 真机: 点 PiP 窗口的叉号 -> mpv 往死窗口渲染 -> 闪退)。
     * 这些回调本身就在主线程, 直接 invokeMethod 即可(消息投递到 Dart 的 UI
     * 线程, 不需要主线程继续转)。
     */
    private fun notifyDart(method: String, args: Map<String, Any>?) {
        val messenger = MainActivity.dartMessenger ?: return
        try {
            MethodChannel(messenger, PipChannel.NAME).invokeMethod(method, args)
        } catch (e: Throwable) {
            // 引擎已销毁(应用被杀)之类: PiP 窗口自己收尾即可
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
