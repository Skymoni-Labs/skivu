/**
 * 屏幕空间的背景来源：按层叠顺序画出同一 Activity 里压在某个 window 之下的全部 window
 *
 * 自带 window 的玻璃（[LiquidGlassToast]）底下可能叠着好几层：Activity 自己的 window、
 * Dialog / BottomSheetDialog、挂在它们上面的 PopupWindow。它们分属不同的 view 树，
 * 而 [LiquidGlassView.backdropSource] 只能指一棵。这个 View 充当那个来源：[onDraw] 时把
 * 每个 window 的根视图按层叠顺序画到它在屏幕上的位置；带 FLAG_DIM_BEHIND 的 window
 * 先按 dimAmount 盖一层黑（变暗层由 SurfaceFlinger 合成，不在任何 view 树里）。
 *
 * 它本身不挂到任何 window 上：未挂载的 View 屏幕坐标恒为 (0, 0)，而各条捕获路径都按
 * "玻璃与来源的屏幕坐标差"定位，所以这里的画布坐标就是屏幕坐标。各 window 的根视图
 * 用公开的 [View.draw] 画，与跨 window 的 backdropSource 走同一条路（见 [BackdropCapture]）。
 *
 * 画不出来的：别的进程的 window（输入法、系统栏）、window 动画（SurfaceFlinger 上的变换）、
 * 跨 window 模糊（FLAG_BLUR_BEHIND）。
 */
package com.example.liquidglass

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.view.inspector.WindowInspector
import java.lang.reflect.Field
import kotlin.math.roundToInt

internal class WindowStackBackdrop(context: Context) : View(context) {

    /** 玻璃所在 window 的根视图：它自己和叠在它上面的 window 都不画 */
    var ownWindow: View? = null

    private val layers = ArrayList<View>()
    private val selfLocation = IntArray(2)
    private val rootLocation = IntArray(2)

    override fun onDraw(canvas: Canvas) {
        val own = ownWindow ?: return
        AppWindows.collectBelow(own, layers)
        getLocationOnScreen(selfLocation)
        try {
            for (i in layers.indices) {
                val root = layers[i]
                val lp = root.layoutParams as? WindowManager.LayoutParams
                // 变暗层夹在这个 window 和它下面的全部内容之间
                if (i > 0 && lp != null && lp.flags and WindowManager.LayoutParams.FLAG_DIM_BEHIND != 0) {
                    val dim = (lp.dimAmount.coerceIn(0f, 1f) * 255f).roundToInt()
                    if (dim > 0) canvas.drawColor(Color.argb(dim, 0, 0, 0))
                }
                root.getLocationOnScreen(rootLocation)
                val save = canvas.save()
                canvas.translate(
                    (rootLocation[0] - selfLocation[0]).toFloat(),
                    (rootLocation[1] - selfLocation[1]).toFloat()
                )
                // window 只显示自己范围内的内容
                canvas.clipRect(0, 0, root.width, root.height)
                // 公开的 View.draw 不带滚动偏移（同 BackdropCapture.drawContent）
                canvas.translate(-root.scrollX.toFloat(), -root.scrollY.toFloat())
                root.draw(canvas)
                canvas.restoreToCount(save)
            }
        } finally {
            // 帧与帧之间不持有别的 window 的根视图
            layers.clear()
        }
    }
}

/**
 * 进程内的 window 列表，以及同一 Activity 名下各 window 的层叠顺序
 *
 * 层叠顺序按 WMS 的规则还原：同一 Activity（同一个 app token）的顶层 window 里，
 * Activity 自己的 window（TYPE_BASE_APPLICATION）恒在最底层，其余（Dialog 等）
 * 按添加顺序从下往上、后加的在上；子 window（PopupWindow 之类）紧跟在所挂的 window 之后。
 * 只在主线程调用。
 */
internal object AppWindows {

    private const val TAG = "AppWindows"

    private var legacyGlobal: Any? = null
    private var legacyViews: Field? = null
    private var legacyTried = false

    private val ownRect = Rect()
    private val otherRect = Rect()
    private val location = IntArray(2)

    /** 进程内所有 window 的根视图，按添加顺序 */
    fun roots(): List<View> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return WindowInspector.getGlobalWindowViews()
        }
        return legacyRoots()
    }

    /**
     * API 24–28 没有公开入口，读 WindowManagerGlobal.mViews（P 上在灰名单里，可以访问）。
     * 读不到时返回空表：调用方拿不到底下的 window，只影响画面，不影响功能
     */
    @SuppressLint("PrivateApi", "DiscouragedPrivateApi")
    private fun legacyRoots(): List<View> {
        if (!legacyTried) {
            legacyTried = true
            try {
                val cls = Class.forName("android.view.WindowManagerGlobal")
                legacyGlobal = cls.getMethod("getInstance").invoke(null)
                legacyViews = cls.getDeclaredField("mViews").apply { isAccessible = true }
            } catch (e: Exception) {
                Log.w(TAG, "WindowManagerGlobal.mViews unavailable", e)
            }
        }
        val field = legacyViews ?: return emptyList()
        return try {
            (field.get(legacyGlobal) as? List<*>)?.filterIsInstance<View>() ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * 把与 [own] 同属一个 Activity、层叠在它之下的可见 window 根视图，
     * 按从下往上的顺序放进 [out]
     */
    fun collectBelow(own: View, out: MutableList<View>) {
        out.clear()
        val token = params(own)?.token ?: return
        val roots = roots()
        for (root in topLevel(roots, token)) {
            if (root === own) return
            if (!isVisible(root)) continue
            out += root
            addSubWindows(root, roots, out)
        }
    }

    /**
     * 同一 Activity 里是否有比 [own] 后加进来、叠在它上面并且挡住它的可见顶层 window：
     * 和它有重叠，或者带变暗层（变暗层铺满整个屏幕，压在那个 window 之下的都会变暗）
     */
    fun isCovered(own: View): Boolean {
        val token = params(own)?.token ?: return false
        own.getLocationOnScreen(location)
        ownRect.set(location[0], location[1], location[0] + own.width, location[1] + own.height)
        var passedOwn = false
        for (root in topLevel(roots(), token)) {
            if (root === own) {
                passedOwn = true
                continue
            }
            if (!passedOwn || !isVisible(root)) continue
            val lp = params(root) ?: continue
            if (lp.flags and WindowManager.LayoutParams.FLAG_DIM_BEHIND != 0 && lp.dimAmount > 0f) {
                return true
            }
            root.getLocationOnScreen(location)
            otherRect.set(location[0], location[1], location[0] + root.width, location[1] + root.height)
            if (Rect.intersects(ownRect, otherRect)) return true
        }
        return false
    }

    /** [token] 名下的顶层 window，按层叠顺序从下往上 */
    private fun topLevel(roots: List<View>, token: IBinder): List<View> {
        val result = ArrayList<View>(roots.size)
        var baseCount = 0
        for (root in roots) {
            val lp = params(root) ?: continue
            if (lp.token != token || isSubWindow(lp)) continue
            // Activity 自己的 window 可能比 onCreate 里弹出的 Dialog 晚加进来，但在 WMS 里恒在最底层
            if (lp.type == WindowManager.LayoutParams.TYPE_BASE_APPLICATION) {
                result.add(baseCount++, root)
            } else {
                result += root
            }
        }
        return result
    }

    private fun addSubWindows(parent: View, roots: List<View>, out: MutableList<View>) {
        val token = parent.windowToken ?: return
        for (root in roots) {
            val lp = params(root) ?: continue
            if (isSubWindow(lp) && lp.token == token && isVisible(root)) {
                out += root
                addSubWindows(root, roots, out)
            }
        }
    }

    private fun params(root: View): WindowManager.LayoutParams? =
        root.layoutParams as? WindowManager.LayoutParams

    private fun isSubWindow(lp: WindowManager.LayoutParams): Boolean =
        lp.type >= WindowManager.LayoutParams.FIRST_SUB_WINDOW &&
            lp.type <= WindowManager.LayoutParams.LAST_SUB_WINDOW

    private fun isVisible(root: View): Boolean = root.isShown && root.width > 0 && root.height > 0
}
