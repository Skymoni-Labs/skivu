package com.skyjjgw.independent.ski.dshgo.runtime
import android.content.Context
/** Original upstream presentation hook, using Skivu's existing task service. */
object DshService {
    fun updateNotification(context:Context) { com.skyjjgw.independent.ski.DshGoPhoneHost.refreshNotification(context) }
}
