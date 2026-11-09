package com.skyjjgw.independent.ski

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CloudTaskControlReceiver:BroadcastReceiver(){
    override fun onReceive(context:Context,intent:Intent){
        if(intent.action=="restore"){ExecutionHub.setMode(context,"compact");return}
        val id=intent.getStringExtra("taskId")?:return
        runCatching{ExecutionHub.control(id,intent.action?:"stop")}
    }
}
