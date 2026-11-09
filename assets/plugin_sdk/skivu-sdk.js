/* SPDX-License-Identifier: GPL-3.0-only */
(()=>{'use strict';
  if(window.Skivu?.apiVersion==='1.0')return;
  // WebRTC can open sockets outside fetch/CSP. External traffic belongs to the
  // permissioned host proxy, never an unmediated browser transport.
  for(const name of ['RTCPeerConnection','webkitRTCPeerConnection','WebTransport'])try{Object.defineProperty(window,name,{value:undefined,writable:false,configurable:false});}catch(_){}
  const pending=new Map(),listeners=new Map();let serial=0,closed=false;
  function error(code,message){const e=new Error(message);e.code=code;return e;}
  function call(method,params={},options={}){
    if(closed)return Promise.reject(error('CLOSED','插件已关闭。'));
    const timeout=options.timeoutMs??0;
    if(!Number.isSafeInteger(timeout)||timeout<0)return Promise.reject(error('INVALID_ARGUMENT','超时无效；0不设置应用时限。'));
    return new Promise((resolve,reject)=>{const id=String(++serial);let timer=null;
      if(timeout>0){const end=Date.now()+timeout;const arm=()=>{const left=end-Date.now();if(left>0){timer=setTimeout(arm,Math.min(left,2147483647));const saved=pending.get(id);if(saved)saved.timer=timer;return;}pending.delete(id);reject(error('TIMEOUT','用户设置的等待时限已到；执行结果需核对，不能盲目重发。'));};timer=setTimeout(arm,Math.min(timeout,2147483647));}
      pending.set(id,{resolve,reject,timer});
      try{SkivuNative.postMessage(JSON.stringify({id,method,params}));}catch(e){if(timer!==null)clearTimeout(timer);pending.delete(id);reject(error('BRIDGE_FAILED','宿主请求无法发送：'+String(e?.message||e)));}
    });
  }
  function on(name,handler){if(typeof handler!=='function')throw new TypeError('handler must be a function');if(!listeners.has(name))listeners.set(name,new Set());listeners.get(name).add(handler);return()=>listeners.get(name)?.delete(handler);}
  Object.defineProperty(window,'__skivuResolve',{value:(id,message)=>{const p=pending.get(id);if(!p)return;if(p.timer!==null)clearTimeout(p.timer);pending.delete(id);message.ok?p.resolve(message.result):p.reject(error(message.error?.code||'FAILED',message.error?.message||'宿主调用未完成。'));}});
  Object.defineProperty(window,'__skivuEvent',{value:(name,detail)=>{for(const fn of listeners.get(name)||[])try{fn(detail);}catch(_){}if(name==='host.suspend'){closed=true;for(const p of pending.values()){if(p.timer!==null)clearTimeout(p.timer);p.reject(error('CLOSED','插件已关闭。'));}pending.clear();}}});
  Object.defineProperty(window,'Skivu',{value:Object.freeze({apiVersion:'1.0',call,on}),writable:false,configurable:false});
  window.dispatchEvent(new Event('skivu.ready'));
})();
