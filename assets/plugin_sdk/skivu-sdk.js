/* SPDX-License-Identifier: GPL-3.0-only */
(()=>{'use strict';
  if(window.Skivu?.apiVersion==='1.0')return;
  // WebRTC can open sockets outside fetch/CSP. External traffic belongs to the
  // permissioned host proxy, never an unmediated browser transport.
  for(const name of ['RTCPeerConnection','webkitRTCPeerConnection','WebTransport'])try{Object.defineProperty(window,name,{value:undefined,writable:false,configurable:false});}catch(_){}
  const pending=new Map(),listeners=new Map();let serial=0,closed=false;
  function error(code,message){const e=new Error(message);e.code=code;return e;}
  function call(method,params={}){
    if(closed)return Promise.reject(error('CLOSED','插件已关闭。'));
    if(pending.size>=8)return Promise.reject(error('BUSY','同时运行的请求过多。'));
    return new Promise((resolve,reject)=>{const id=String(++serial),timer=setTimeout(()=>{pending.delete(id);reject(error('TIMEOUT','宿主调用超时。'));},180000);
      pending.set(id,{resolve,reject,timer});
      try{const raw=JSON.stringify({id,method,params});if(raw.length>18*1024*1024)throw new Error('too large');SkivuNative.postMessage(raw);}catch(_){clearTimeout(timer);pending.delete(id);reject(error('BRIDGE_FAILED','宿主请求无法发送或超过大小上限。'));}
    });
  }
  function on(name,handler){if(typeof handler!=='function')throw new TypeError('handler must be a function');if(!listeners.has(name))listeners.set(name,new Set());listeners.get(name).add(handler);return()=>listeners.get(name)?.delete(handler);}
  Object.defineProperty(window,'__skivuResolve',{value:(id,message)=>{const p=pending.get(id);if(!p)return;clearTimeout(p.timer);pending.delete(id);message.ok?p.resolve(message.result):p.reject(error(message.error?.code||'FAILED',message.error?.message||'宿主调用未完成。'));}});
  Object.defineProperty(window,'__skivuEvent',{value:(name,detail)=>{for(const fn of listeners.get(name)||[])try{fn(detail);}catch(_){}if(name==='host.suspend'){closed=true;for(const p of pending.values()){clearTimeout(p.timer);p.reject(error('CLOSED','插件已关闭。'));}pending.clear();}}});
  Object.defineProperty(window,'Skivu',{value:Object.freeze({apiVersion:'1.0',call,on}),writable:false,configurable:false});
  window.dispatchEvent(new Event('skivu.ready'));
})();
