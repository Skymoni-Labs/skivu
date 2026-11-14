package com.skyjjgw.independent.ski.dshgo.phone

/** Per bridge call, never reused. Contains no text, pixels, node or executable callback. */
class PhoneReplyCommit internal constructor() {
    private var encoded = false
    @Volatile internal var committed = false
        private set

    // Called on the invoking thread only after its exact ToolOutput encoded successfully.
    internal fun encoded() { encoded = true }

    // Same invoking thread, inside PhoneCallWork's normal-reply commit lock. No external calls.
    internal fun commitIfEncoded() { if (encoded) committed = true }
}
