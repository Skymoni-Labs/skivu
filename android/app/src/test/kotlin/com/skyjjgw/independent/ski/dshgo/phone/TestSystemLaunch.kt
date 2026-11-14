package com.skyjjgw.independent.ski.dshgo.phone

/** Native Intent-free fake at the SystemApi boundary; used by actual Core/worker tests. */
internal class TestSystemLaunch(
    override val target: SystemTarget,
    val kind: String = "app",
    val spec: IntentSpec? = null,
) : SystemLaunch
