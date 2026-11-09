package com.skyjjgw.independent.ski

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CloudTaskControlReceiver:BroadcastReceiver(){
    override fun onReceive(context:Context,intent:Intent){
        if(intent.action=="run.stop"){val id=intent.getStringExtra("runId")?:return;val pending=goAsync();Thread{try{TaskScheduleStore(context).stopRun(id);ScheduledTaskWorker.requestStop(context,id)}finally{pending.finish()}}.start();return}
        if(intent.action=="restore"){ExecutionHub.setMode(context,"compact");return}
        val id=intent.getStringExtra("taskId")?:return
        runCatching{ExecutionHub.control(id,intent.action?:"stop")}
    }
}
