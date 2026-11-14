package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity

/** Real peer owner state, guarded by PrivilegedDisplayCore's existing lock. No resource ownership. */
internal class TargetIdentity {
    class Failure(val code: String) : Exception()
    private var modern: Boolean? = null
    var current: PhoneAppIdentity? = null
        private set

    fun request(pkg: String, hasVersion: Boolean, version: Any?, hasUid: Boolean, uid: Any?, opening: Boolean): PhoneAppIdentity? {
        val target = if (!hasVersion && !hasUid) null else {
            if (version !is Int || version != 1 || uid !is Int || uid < 0)
                throw Failure("targetIdentityUnavailable")
            PhoneAppIdentity(pkg, uid)
        }
        val nextMode = target != null
        if (modern == null) {
            if (!opening) throw Failure("targetIdentityUnavailable")
            modern = nextMode
        } else if (modern != nextMode) throw Failure("targetIdentityChanged")
        if (opening) current = null // Even a failed replacement cannot reuse the old actionable target.
        else if (nextMode) {
            if (current == null) throw Failure("targetIdentityUnavailable")
            if (current != target) throw Failure("targetIdentityChanged")
        }
        return target
    }

    fun opened(target: PhoneAppIdentity?) { current = target }
    fun invalidate() { current = null }
    fun clear() { modern = null; current = null }
    val verified: Boolean get() = modern == true

    companion object {
        fun supported(version: Any?): Boolean = version is Int && version == 1

        /** Actual PM/TaskInfo values only; missing evidence never becomes user zero. */
        fun matches(expected: PhoneAppIdentity, packageName: String?, uid: Int?): Boolean =
            packageName == expected.packageName && uid == expected.uid

        fun matchesTask(expected: PhoneAppIdentity, packageName: String?, uid: Int?, user: Int?, expectedUser: Int): Boolean =
            user == expectedUser && matches(expected, packageName, uid)

        fun receipt(expected: PhoneAppIdentity, version: Any?, pkg: Any?, uid: Any?): Boolean =
            supported(version) && pkg is String && uid is Int && matches(expected, pkg, uid)

        /** Used only after the real open's OwnerScope envelope has matched its pinned resource. */
        fun backgroundOpenConfirmed(expected: PhoneAppIdentity, ok: Any?, evidence: Any?, displayId: Any?,
                                    targetVersion: Any?, pkg: Any?, uid: Any?): Boolean =
            ok is Boolean && ok && evidence is Int && evidence == 1 && displayId is Int && displayId > 0 &&
                receipt(expected, targetVersion, pkg, uid)
    }
}
