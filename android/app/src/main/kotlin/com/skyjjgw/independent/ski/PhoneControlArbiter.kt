package com.skyjjgw.independent.ski

/** Only the shared visible phone is exclusive. Linux and independent projects
 * continue while another task owns a page observation/action sequence. */
object PhoneControlArbiter {
    private val lock=java.lang.Object()
    private var owner:String?=null
    fun acquire(id:String,check:()->Unit){synchronized(lock){while(owner!=null&&owner!=id){check();lock.wait(200)};check();owner=id}}
    fun release(id:String){synchronized(lock){if(owner==id){owner=null;lock.notifyAll()}}}
}
