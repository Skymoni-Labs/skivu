package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.content.Context
import android.content.pm.PackageManager
import java.security.MessageDigest

/** One reviewed public navigation relation, not a general App/label matcher or execution grant.
 * Source: Markor v2026.10.0 (04e8b92a), Material NavigationBarItemView 1.13.0.
 * The observed signer binds this installation; it is not a claim of an official signing key. */
internal object MarkorNavigation {
    const val PACKAGE = "net.gsantner.markor"
    private val tabs = listOf("nav_notebook", "nav_todo", "nav_quicknote", "nav_more")
    private val titles = listOf("files", "todo", "quicknote", "more")
    data class App(val uid: Int, val version: Long, val updated: Long, val signers: String)
    data class Observation(val windowId: Int, val selected: String, val moreRef: Int,
        val moreCanClick: Boolean)
    class Before(val app: App, val observation: Observation)

    @Suppress("DEPRECATION")
    internal fun installed(context: Context): Pair<App, Map<String, String>>? {
        return try {
        val pm = context.packageManager
        val info = pm.getPackageInfo(PACKAGE, PackageManager.GET_SIGNATURES)
        val uid = info.applicationInfo?.uid ?: -1
        val signatures = info.signatures
        if (uid < 0 || info.versionCode != 164 || info.versionName != "2026.10.0" || signatures.isNullOrEmpty() || signatures.size > 8) null
        else {
            val resources = pm.getResourcesForApplication(PACKAGE)
            // Require actual resources in this installation, not names supplied by the route.
            for (name in tabs + listOf("bottom_navigation_bar", "main__view_pager_container")) {
                val id = resources.getIdentifier(name, "id", PACKAGE)
                if (id == 0 || resources.getResourceName(id) != "$PACKAGE:id/$name") return null
            }
            val labels = tabs.zip(titles).associate { (tab, title) ->
                val id = resources.getIdentifier(title, "string", PACKAGE)
                if (id == 0) return null
                tab to resources.getString(id)
            }
            val signers = signatures.map { signature ->
                MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                    .joinToString("") { "%02x".format(java.util.Locale.ROOT, it.toInt() and 255) }
            }.sorted().joinToString(":")
            val signingDigest = MessageDigest.getInstance("SHA-256").digest(signers.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(java.util.Locale.ROOT, it.toInt() and 255) }
            App(uid, info.versionCode.toLong(), info.lastUpdateTime, signingDigest) to labels
        }
        } catch (_: Exception) { null }
    }

    /** Current explicit UI selection only. Recording identity is never substituted here. */
    fun selectedApp(context: Context, packageName: String, uid: Int): App? =
        if (packageName != PACKAGE) null else installed(context)?.first?.takeIf { it.uid == uid }

    /** Reads original nodes, including the selected tab which Material makes non-clickable. */
    fun inspect(windows: List<UiWindow>, labels: Map<String, String>): Observation? {
        val window = windows.singleOrNull()?.takeIf { it.kind == WindowKind.APP && it.packageName == PACKAGE } ?: return null
        val root = window.root ?: return null
        val all = ArrayList<UiNode>()
        fun visit(node: UiNode) { all += node; node.children.forEach(::visit) }
        visit(root)
        fun unique(name: String) = all.singleOrNull { it.viewId == "$PACKAGE:id/$name" }
        val bar = unique("bottom_navigation_bar") ?: return null
        if (unique("main__view_pager_container") == null) return null
        val withinBar = ArrayList<UiNode>()
        fun visitBar(node: UiNode) { withinBar += node; node.children.forEach(::visitBar) }
        visitBar(bar)
        val nodes = tabs.map { key ->
            val node = unique(key) ?: return null
            if (node !in withinBar || !node.enabled || node.password || node.editable || node.bounds.isEmpty ||
                node.desc != labels[key] || labels[key].isNullOrBlank()) return null
            node
        }
        val selected = nodes.indices.singleOrNull { nodes[it].selected } ?: return null
        val more = nodes.last()
        return Observation(window.id, tabs[selected], more.ref, more.clickable && more.actionClick)
    }

    private fun readable(cap: Capture): Boolean = cap.typedTransitions != null && cap.typedEvents != null && cap.packageName == PACKAGE && !cap.partial && !cap.truncated && cap.visualComplete &&
        cap.keyboardShown == false && cap.hiddenWindowTitle == null && cap.unreadableWindowTitle == null &&
        !cap.ownAppInFront && !cap.systemInFront

    fun before(context: Context, cap: Capture, actualRef: Int): Before? {
        if (!readable(cap)) return null
        val (app, labels) = installed(context) ?: return null
        val observation = inspect(cap.windows, labels) ?: return null
        // Recording a navigation action needs a real unselected target; replay's already-selected
        // case must verify its postcondition without manufacturing another click.
        if (observation.selected == "nav_more" || !observation.moreCanClick ||
            observation.moreRef != actualRef || actualRef < 0) return null
        return Before(app, observation)
    }

    fun afterObservation(context: Context, before: Before, cap: Capture): Observation? {
        if (!readable(cap)) return null
        val (app, labels) = installed(context) ?: return null
        if (app != before.app) return null
        return inspect(cap.windows, labels)?.takeIf { it.windowId == before.observation.windowId }
    }

    fun selectedObservation(context: Context, cap: Capture,
        selected: com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections.App): Observation? {
        if (selected.packageName != PACKAGE || !readable(cap)) return null
        val (app, labels) = installed(context) ?: return null
        if (app.uid != selected.uid || app.version != selected.version || app.updated != selected.updated ||
            app.signers != selected.signers) return null
        return inspect(cap.windows, labels)
    }


}
