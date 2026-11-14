package com.skyjjgw.independent.ski.dshgo.mlkit

import android.content.Context
import com.google.mlkit.common.MlKit

/** Called only when opening the pairing scanner or admitting an enabled OCR job. */
internal object MlKitRuntime {
    private val initialization = MlKitInitialization()

    fun initialize(context: Context) {
        initialization.ensureInitialized { MlKit.initialize(context.applicationContext) }
    }
}
