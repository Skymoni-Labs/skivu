package com.skyjjgw.independent.ski

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Local, bounded latest-frame capture. No recording, files, encoding, model upload or token storage. */
class PhoneScreenCaptureService : Service() {
    companion object {
        @Volatile internal var active: PhoneScreenCaptureService? = null
        internal fun stop(context: android.content.Context) {
            active = null
            context.stopService(Intent(context, PhoneScreenCaptureService::class.java))
        }
        private const val STOP = "skivu.capture.STOP"
    }
    internal val session = UUID.randomUUID().toString()
    private val thread = HandlerThread("skivu-latest-frame")
    private lateinit var handler: Handler
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var surfaces = emptyList<ImageReader>()
    private var latest: Image? = null
    private var scratch: ByteBuffer? = null
    @Volatile private var stopped = false
    @Volatile private var visible = true
    @Volatile private var lastRequest = SystemClock.uptimeMillis()
    private data class Request(val afterNs: Long, val width: Int, val height: Int,
        val result: CompletableFuture<Pixels>)
    internal data class Pixels(val bitmap: Bitmap, val capturedAt: Long, val session: String)
    private var waiting: Request? = null

    override fun onCreate() { super.onCreate(); thread.start(); handler = Handler(thread.looper) }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP || intent == null) { stopSelf(); return START_NOT_STICKY }
        if (projection != null) return START_NOT_STICKY
        try {
            val prefs = getSharedPreferences("skivu.device-engine.v1", 0)
            require(prefs.getBoolean("enabled", false) && prefs.getBoolean("control", false) &&
                SkivuAccessibilityService.connected != null)
            val notifications = getSystemService(NotificationManager::class.java)
            notifications.createNotificationChannel(NotificationChannel("skivu-screen-capture", "高速识屏", NotificationManager.IMPORTANCE_LOW))
            val stop = PendingIntent.getService(this, 0, Intent(this, PhoneScreenCaptureService::class.java).setAction(STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val notification = Notification.Builder(this, "skivu-screen-capture")
                .setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("高速识屏已开启")
                .setContentText("仅用于本次手机操作，可随时停止")
                .setOngoing(true).addAction(Notification.Action.Builder(null, "停止识屏", stop).build()).build()
            startForeground(4113, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            @Suppress("DEPRECATION")
            val consent = intent.getParcelableExtra<Intent>("consent") ?: error("缺少本次屏幕授权。")
            val token = getSystemService(MediaProjectionManager::class.java)
                .getMediaProjection(intent.getIntExtra("resultCode", 0), consent) ?: error("屏幕授权已失效。")
            projection = token
            token.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() { stopped = true; if (active === this@PhoneScreenCaptureService) active = null; stopSelf() }
                override fun onCapturedContentResize(width: Int, height: Int) {
                    val size = screenSize()
                    if (width != size.first || height != size.second) { stopSelf(); return }
                    if (reader?.width != width || reader?.height != height) {
                        try { resize(width, height) } catch (_: Exception) { stopSelf() }
                    }
                }
                override fun onCapturedContentVisibilityChanged(isVisible: Boolean) { visible = isVisible }
            }, handler)
            handler.post {
                try {
                    if (stopped) return@post
                    val size = screenSize()
                    surfaces = makeSurfaces(size.first, size.second)
                    val surface = surfaces.first(); reader = surface
                    display = token.createVirtualDisplay("Skivu local recognition", size.first, size.second,
                        resources.displayMetrics.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                        surface.surface, null, handler)
                    if (!stopped) active = this
                    handler.postDelayed(idleCheck, 5_000)
                } catch (_: Exception) { stopSelf() }
            }
        } catch (_: Exception) { stopSelf() }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun screenSize(): Pair<Int, Int> {
        val metrics = android.util.DisplayMetrics()
        getSystemService(DisplayManager::class.java).getDisplay(android.view.Display.DEFAULT_DISPLAY).getRealMetrics(metrics)
        return metrics.widthPixels to metrics.heightPixels
    }
    private val idleCheck = object : Runnable {
        override fun run() {
            if (stopped) return
            if (SystemClock.uptimeMillis() - lastRequest > 120_000 ||
                getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked) stopSelf()
            else handler.postDelayed(this, 5_000)
        }
    }
    private fun makeReader(width: Int, height: Int): ImageReader {
        val created = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
        created.setOnImageAvailableListener({ source ->
            if (stopped) return@setOnImageAvailableListener
            try {
                val fresh = source.acquireLatestImage() ?: return@setOnImageAvailableListener
                if(reader !== source) { fresh.close(); return@setOnImageAvailableListener }
                latest?.close(); latest = fresh
                deliver()
            } catch (_: Exception) { stopSelf() }
        }, handler)
        return created
    }
    private fun makeSurfaces(width:Int,height:Int):List<ImageReader> {
        val first=makeReader(width,height)
        return try { listOf(first,makeReader(width,height)) }
        catch(error:Exception) { first.close();throw error }
    }
    private fun resize(width: Int, height: Int) {
        waiting?.result?.completeExceptionally(IllegalStateException("屏幕尺寸已变化。")); waiting = null
        latest?.close(); latest = null
        val old = surfaces
        try {
            surfaces = makeSurfaces(width,height)
            val fresh = surfaces.first(); reader = fresh
            display?.resize(width, height, resources.displayMetrics.densityDpi)
            display?.surface = fresh.surface
        } finally { old.forEach { it.close() } }
    }
    private fun deliver() {
        val request = waiting ?: return
        if (request.result.isDone) { waiting = null; return }
        val image = latest ?: return
        // Never label an old queued buffer as a new capture. Unknown producer clocks
        // or a paused source use the existing screenshot backend instead.
        val capturedAt=PhoneFrameClock.capturedAt(image.timestamp,request.afterNs,System.nanoTime(),SystemClock.uptimeMillis())?:return
        if (!visible ||
            image.width != request.width || image.height != request.height) return
        var bitmap: Bitmap? = null
        try {
            val plane = image.planes.single(); require(plane.pixelStride == 4)
            val pixels = plane.buffer.duplicate()
            bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
            if (plane.rowStride == image.width * 4) {
                pixels.rewind(); bitmap.copyPixelsFromBuffer(pixels)
            } else {
                val length = image.width * image.height * 4
                val buffer = scratch?.takeIf { it.capacity() == length } ?: ByteBuffer.allocateDirect(length).also { scratch = it }
                buffer.clear()
                for (row in 0 until image.height) {
                    pixels.limit(pixels.capacity()); pixels.position(row * plane.rowStride)
                    pixels.limit(pixels.position() + image.width * 4); buffer.put(pixels)
                }
                buffer.flip(); bitmap.copyPixelsFromBuffer(buffer)
            }
            val value = Pixels(bitmap, capturedAt, session)
            if (!request.result.complete(value)) bitmap.recycle()
            bitmap = null
        } catch (e: Exception) { request.result.completeExceptionally(e) }
        finally { bitmap?.recycle(); waiting = null }
    }

    /** Called off the main thread, after pre-capture privacy checks and overlay removal. */
    internal fun capture(afterNs: Long, width: Int, height: Int, check: () -> Unit): Pixels? {
        if (stopped || active !== this) return null
        lastRequest = SystemClock.uptimeMillis()
        val future = CompletableFuture<Pixels>()
        val request = Request(afterNs, width, height, future)
        handler.post {
            if (stopped || active !== this) future.completeExceptionally(IllegalStateException("高速识屏已停止。"))
            else {
                waiting?.result?.cancel(false); waiting = request; deliver()
                if(waiting === request && !future.isDone) {
                    // A static screen need not produce another buffer. Switch between two
                    // bounded surfaces on the same authorized display to request fresh pixels;
                    // never pretend the timestamp of a retained image has advanced.
                    try {
                        latest?.close(); latest = null
                        val next = surfaces.first { it !== reader }
                        next.acquireLatestImage()?.close()
                        reader = next
                        display?.surface = next.surface
                    } catch(error:Exception) { future.completeExceptionally(error);waiting=null;stopSelf() }
                }
            }
        }
        val deadline = SystemClock.uptimeMillis() + 150
        var handedOver = false
        try {
            while (SystemClock.uptimeMillis() < deadline) {
                check()
                if (stopped || active !== this) return null
                try { return future.get(20, TimeUnit.MILLISECONDS).also { handedOver = true } } catch (_: TimeoutException) { }
            }
            return null
        } catch (e: java.util.concurrent.ExecutionException) {
            return null
        } catch (e: java.util.concurrent.CancellationException) {
            return null
        } finally {
            if (!handedOver) {
                if (!future.cancel(false) && !future.isCompletedExceptionally) future.getNow(null)?.bitmap?.recycle()
            }
            handler.post { if (waiting === request) waiting = null }
        }
    }

    override fun onDestroy() {
        stopped = true
        if (active === this) active = null
        handler.post {
            handler.removeCallbacks(idleCheck)
            waiting?.result?.cancel(false); waiting = null
            latest?.close(); latest = null
            display?.release(); display = null
            surfaces.forEach { it.close() }; surfaces = emptyList(); reader = null
            projection?.stop(); projection = null; scratch = null
            thread.quitSafely()
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
