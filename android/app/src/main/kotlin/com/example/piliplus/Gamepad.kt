package com.example.piliplus

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent

/**
 * 手柄摇杆轴值缓存 —— 第十九轮「VR 操作模式的手柄控制」。
 *
 * 摇杆是 `MotionEvent` 的**模拟轴**(AXIS_Z / AXIS_RZ …), Flutter 只把
 * `KeyEvent` 送进 Dart, 模拟轴根本不会过桥, 所以在 Activity 侧把最新一次
 * 摇杆读数缓存下来, Dart(VrControlLayer)按需轮询读取。
 *
 * 轴语义(安卓标准映射):
 *  * 左摇杆 = AXIS_X / AXIS_Y
 *  * 右摇杆 = AXIS_Z / AXIS_RZ   ← VR 环视用这一根
 *  * 十字键模拟量 = AXIS_HAT_X / AXIS_HAT_Y
 *  * 方向: 右/下为 +1, 左/上为 −1
 *
 * 线程: `onGenericMotionEvent` 在主线程写, Dart 的轮询也在主线程读,
 * 加 `@Volatile` 只是让语义明确(不存在撕裂的 float 写)。
 */
object Gamepad {

    @Volatile
    var rightX: Float = 0f
        private set

    @Volatile
    var rightY: Float = 0f
        private set

    @Volatile
    var leftX: Float = 0f
        private set

    @Volatile
    var leftY: Float = 0f
        private set

    @Volatile
    var hatX: Float = 0f
        private set

    @Volatile
    var hatY: Float = 0f
        private set

    /** 最近一次摇杆事件的时刻(uptimeMillis); 0 = 从没接过 */
    @Volatile
    private var lastEventUptime: Long = 0L

    /** 是否接过摇杆事件(用于 Dart 侧判断"这台设备到底有没有手柄") */
    @Volatile
    var everSeen: Boolean = false
        private set

    fun onGenericMotionEvent(event: MotionEvent) {
        val source = event.source
        if ((source and InputDevice.SOURCE_JOYSTICK) != InputDevice.SOURCE_JOYSTICK &&
            (source and InputDevice.SOURCE_GAMEPAD) != InputDevice.SOURCE_GAMEPAD
        ) {
            return
        }
        rightX = axis(event, MotionEvent.AXIS_Z)
        rightY = axis(event, MotionEvent.AXIS_RZ)
        leftX = axis(event, MotionEvent.AXIS_X)
        leftY = axis(event, MotionEvent.AXIS_Y)
        hatX = axis(event, MotionEvent.AXIS_HAT_X)
        hatY = axis(event, MotionEvent.AXIS_HAT_Y)
        lastEventUptime = SystemClock.uptimeMillis()
        everSeen = true
    }

    /** 轮询快照: 轴值 + 最近一次摇杆事件的年龄(毫秒, 用于丢弃陈旧读数) */
    fun snapshot(): Map<String, Any> {
        val age = if (lastEventUptime <= 0L) {
            Long.MAX_VALUE
        } else {
            (SystemClock.uptimeMillis() - lastEventUptime).coerceAtLeast(0L)
        }
        return mapOf(
            "rightX" to rightX.toDouble(),
            "rightY" to rightY.toDouble(),
            "leftX" to leftX.toDouble(),
            "leftY" to leftY.toDouble(),
            "hatX" to hatX.toDouble(),
            "hatY" to hatY.toDouble(),
            "ageMs" to age,
            "seen" to everSeen
        )
    }

    fun reset() {
        rightX = 0f
        rightY = 0f
        leftX = 0f
        leftY = 0f
        hatX = 0f
        hatY = 0f
        lastEventUptime = 0L
    }

    private fun axis(event: MotionEvent, axis: Int): Float = try {
        val v = event.getAxisValue(axis)
        if (v.isNaN() || v.isInfinite()) 0f else v
    } catch (e: Throwable) {
        0f
    }
}
