package com.skyjjgw.independent.ski

/** Map a producer timestamp once, before bitmap copying or recognition can consume time. */
internal object PhoneFrameClock {
    fun capturedAt(timestampNs:Long,afterNs:Long,nowNs:Long,nowMs:Long):Long? {
        if(timestampNs<afterNs || timestampNs>nowNs)return null
        val age=nowNs-timestampNs
        if(age>500_000_000L)return null
        return nowMs-age/1_000_000L
    }
}
