package com.skyjjgw.independent.ski.dshgo.notify
import android.content.Context
/** Original upstream presentation hook, using Skivu's existing task service. */
object LiveActivity {
    fun refresh(context:Context) { com.skyjjgw.independent.ski.DshGoPhoneHost.refreshNotification(context) }
}
