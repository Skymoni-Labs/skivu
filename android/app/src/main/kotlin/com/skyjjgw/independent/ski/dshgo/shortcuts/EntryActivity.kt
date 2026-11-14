package com.skyjjgw.independent.ski.dshgo.shortcuts
import android.content.Context
import android.content.Intent
import com.skyjjgw.independent.ski.MainActivity
/** Routes native phone prompts back to Skivu's existing activity/session. */
object EntryActivity {
    fun openApp(context:Context)=Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    fun openChat(context:Context,sessionId:String,host:String?)=openApp(context).putExtra("skivu_phone_session",sessionId)
}
