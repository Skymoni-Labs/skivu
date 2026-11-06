package com.skyjjgw.independent.ski

import android.app.*
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import org.skivu.engine.adb.EmbeddedAdbEngine
import java.net.NetworkInterface
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Keep Android's pairing dialog visible while its code is entered by RemoteInput.
 * Discovery follows the same local-device filtering as Shizuku's AdbMdns.
 */
class EmbeddedPairingService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private lateinit var backend: EmbeddedAdbEngine
    private lateinit var nsd: NsdManager
    private var listening = false
    private var closed = false
    private var completed = false
    private var port: Int? = null
    private var serviceName: String? = null
    private val expire = Runnable { stopSelf() }
    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(type: String) { listening = true; if(closed) stopDiscovery() }
        override fun onDiscoveryStopped(type: String) { listening = false }
        override fun onStartDiscoveryFailed(type: String, error: Int) { update("未能发现配对窗口，请检查系统无线调试后重试。") }
        override fun onStopDiscoveryFailed(type: String, error: Int) { listening = false }
        override fun onServiceLost(info: NsdServiceInfo) {
            if(info.serviceName == serviceName && !busy.get()) { port = null; update("等待系统配对窗口…") }
        }
        @Suppress("DEPRECATION")
        override fun onServiceFound(info: NsdServiceInfo) {
            if(closed) return
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, code: Int) {}
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val local = NetworkInterface.getNetworkInterfaces().asSequence().any { iface ->
                        iface.inetAddresses.asSequence().any { it.hostAddress == info.host?.hostAddress }
                    }
                    if(!closed && local && info.port in 1024..65535) {
                        port = info.port; serviceName = info.serviceName
                        update("已发现本机配对窗口，请输入系统显示的六位配对码。")
                    }
                }
            })
        }
    }
    override fun onCreate() {
        super.onCreate()
        backend = EmbeddedAdbEngine(applicationContext)
        nsd = getSystemService(NsdManager::class.java)
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("skivu-embedded-pairing", "内置引擎配对", NotificationManager.IMPORTANCE_HIGH))
        startForeground(84, notification("等待系统配对窗口…"))
        try { nsd.discoverServices("_adb-tls-pairing._tcp",NsdManager.PROTOCOL_DNS_SD,discovery) }
        catch (_: Exception) { update("无法发现本机配对窗口，请检查无线调试和通知设置。") }
        main.postDelayed(expire,10 * 60 * 1000L)
    }
    private fun notification(text: String, reply: Boolean = true): Notification {
        val open = PendingIntent.getActivity(this,85,Intent(this,MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this,86,Intent(this,EmbeddedPairingService::class.java).setAction("stop"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = Notification.Builder(this,"skivu-embedded-pairing")
            .setSmallIcon(android.R.drawable.ic_menu_manage).setContentTitle("Skivu 内置引擎配对")
            .setContentText(text).setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open).setOngoing(reply)
        if(reply) {
            val targetPort = port
            if(targetPort != null && !busy.get()) {
                val input = RemoteInput.Builder("pairCode").setLabel("六位配对码").build()
                val action = PendingIntent.getService(this,87,Intent(this,EmbeddedPairingService::class.java)
                    .setAction("pair").putExtra("port",targetPort), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                builder.addAction(Notification.Action.Builder(null,"输入配对码",action).addRemoteInput(input).build())
            }
            builder.addAction(Notification.Action.Builder(null,"停止配对",stop).build())
        }
        return builder.build()
    }
    private fun update(text: String) { main.post {
        if(!closed) getSystemService(NotificationManager::class.java).notify(84,notification(text))
    } }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if(intent?.action == "stop") { stopSelf(); return START_NOT_STICKY }
        if(intent?.action != "pair") return START_NOT_STICKY
        val expectedPort = intent.getIntExtra("port",-1)
        val code = RemoteInput.getResultsFromIntent(intent)?.getCharSequence("pairCode")?.toString().orEmpty().trim()
        if(expectedPort != port || !Regex("^[0-9]{6}$").matches(code)) {
            update("配对窗口已变化或代码无效，请使用当前系统窗口重新输入。")
            return START_NOT_STICKY
        }
        if(!busy.compareAndSet(false,true)) return START_NOT_STICKY
        update("正在验证系统配对…")
        worker.execute {
            try {
                backend.pair(expectedPort,code)
                main.post {
                    if(!closed) {
                        completed = true
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        getSystemService(NotificationManager::class.java).cancel(84)
                        getSystemService(NotificationManager::class.java).notify(85,
                            notification("系统配对完成。返回 Skivu，填写无线调试连接端口以验证身份。",false))
                        stopSelf()
                    }
                }
            } catch (_: Exception) {
                busy.set(false); update("配对未完成。请检查当前配对码与系统窗口后重试。")
            } catch (_: LinkageError) {
                busy.set(false); update("此系统暂不支持当前内置配对后端。")
            }
        }
        return START_NOT_STICKY
    }
    private fun stopDiscovery() {
        if(listening) try { nsd.stopServiceDiscovery(discovery) } catch (_: IllegalArgumentException) {}
    }
    override fun onDestroy() {
        closed = true; main.removeCallbacks(expire)
        stopDiscovery(); backend.close(); worker.shutdownNow()
        if(!completed) stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
