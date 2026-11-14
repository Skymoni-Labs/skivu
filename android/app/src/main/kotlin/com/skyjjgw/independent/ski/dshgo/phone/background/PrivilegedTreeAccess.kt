package com.skyjjgw.independent.ski.dshgo.phone.background

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.os.Binder
import android.os.Trace
import android.os.Build
import android.os.IBinder
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import java.lang.reflect.Proxy

/** One peer-wide short UiAutomation transaction, including every live node and exact close. */
internal class PrivilegedTreeAccess(private val context: Context) {
    class Failure(val code: String) : Exception()
    private val transactions = TreeTransactions<TreeConnection> { connection ->
        tracePhase("dsh.bg.treeClose") { connection.close() }
    }
    fun ready(): Boolean = transactions.ready()
    fun closeOwned(scope: Any): Boolean = transactions.closeOwned(scope)
    fun <T> read(scope: Any, display: Display, pkg: String, unavailable: String, body: (UiAutomation) -> T): T = try {
        transactions.read(scope, { TreeConnection(context, pkg) }) { connection ->
            val automation = try { tracePhase("dsh.bg.treeConnect") { connection.open(display) } }
                catch (_: Throwable) { throw Failure(unavailable) }
            body(automation)
        }
    } catch (_: TreeTransactions.CleanupPending) { throw Failure("treeCleanupPending") }

    private inline fun <T> tracePhase(name: String, body: () -> T): T {
        Trace.beginSection(name)
        try { return body() } finally { Trace.endSection() }
    }

    private class TreeConnection(private val context: Context, private val target: String) {
        private val clientType = Class.forName("android.accessibilityservice.IAccessibilityServiceClient")
        private val managerType = Class.forName("android.view.accessibility.IAccessibilityManager")
        private val manager = Class.forName("android.view.accessibility.IAccessibilityManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null,
                Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
                    .invoke(null, Context.ACCESSIBILITY_SERVICE))
        private val token = Binder()
        private val registration = TreeRegistration<Any> { original ->
            managerType.getMethod("unregisterUiTestAutomationService", clientType).invoke(manager, original)
        }
        private var automation: UiAutomation? = null

        fun open(display: Display): UiAutomation {
            if (Build.VERSION.SDK_INT < 34) throw Failure("textConnectionUnavailable")
            val connectionType = Class.forName("android.app.IUiAutomationConnection")
            val connection = Proxy.newProxyInstance(connectionType.classLoader, arrayOf(connectionType)) { proxy, method, args ->
                when (method.name) {
                    "asBinder" -> token
                    // Let UiAutomation reach its normal init/timeout state even if register's
                    // reply fails. The registration retains the client independently of this wait.
                    "connect" -> { runCatching { register(args!![0]!!) }; null }
                    "disconnect" -> { registration.unregister(); null }
                    "toString" -> "DshTreeConnection"
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args?.get(0)
                    else -> throw UnsupportedOperationException("node only")
                }
            }
            val value = UiAutomation::class.java.getConstructor(Context::class.java, connectionType)
                .newInstance(context.createDisplayContext(display), connection) as UiAutomation
            automation = value
            UiAutomation::class.java.getMethod("connectWithTimeout", Int::class.javaPrimitiveType, Long::class.javaPrimitiveType)
                .invoke(value, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES, 3000L)
            return value
        }

        private fun register(value: Any) {
            val info = AccessibilityServiceInfo().apply {
                packageNames = arrayOf(target)
                eventTypes = AccessibilityEvent.TYPES_ALL_MASK
                feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
                flags = AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            }
            AccessibilityServiceInfo::class.java.getMethod("setCapabilities", Int::class.javaPrimitiveType)
                .invoke(info, AccessibilityServiceInfo.CAPABILITY_CAN_RETRIEVE_WINDOW_CONTENT)
            val userId = Class.forName("android.os.UserHandle").getMethod("getUserId", Int::class.javaPrimitiveType)
                .invoke(null, context.applicationInfo.uid)
            val method = managerType.getMethod("registerUiTestAutomationService", IBinder::class.java, clientType,
                AccessibilityServiceInfo::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            registration.register(value) { original ->
                method.invoke(manager, token, original, info, userId, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            }
        }

        fun close(): Boolean {
            val complete = registration.close {
                automation?.let { UiAutomation::class.java.getMethod("disconnect").invoke(it) }
            }
            if (complete) automation = null
            return complete
        }
    }

}
