// SPDX-License-Identifier: GPL-3.0-only
const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');
function runtime(){const sent=[],timers=new Map();let now=1000;const w={dispatchEvent(){}};w.RTCPeerConnection=function(){};const sandbox={Date:{now:()=>now},window:w,SkivuNative:{postMessage(s){sent.push(JSON.parse(s));}},setTimeout(fn){const id=timers.size+1;timers.set(id,fn);return id;},clearTimeout(id){timers.delete(id);},Event:function Event(name){this.type=name;},console};vm.runInNewContext(fs.readFileSync('assets/plugin_sdk/skivu-sdk.js','utf8'),sandbox);return {w,sent,timers,advance(ms){now+=ms;}};}
test('SDK exposes only frozen, async public API and disables raw socket transport',()=>{const {w}=runtime();assert.deepEqual(Object.keys(w.Skivu).sort(),['apiVersion','call','on']);assert.equal(Object.isFrozen(w.Skivu),true);assert.equal(w.RTCPeerConnection,undefined);assert.equal(w.WebTransport,undefined);});
test('call response resolves only its request and removes timer',async()=>{const {w,sent,timers}=runtime();const promise=w.Skivu.call('storage.get',{key:'x'});assert.equal(sent[0].method,'storage.get');w.__skivuResolve(sent[0].id,{ok:true,result:42});assert.equal(await promise,42);assert.equal(timers.size,0);});
test('host error preserves public code only',async()=>{const {w,sent}=runtime();const p=w.Skivu.call('admin.login');w.__skivuResolve(sent[0].id,{ok:false,error:{code:'METHOD_NOT_FOUND',message:'Not available'}});await assert.rejects(p,e=>e.code==='METHOD_NOT_FOUND');});
test('pause leaves storage available; suspend rejects pending and future calls',async()=>{const {w,sent}=runtime();let calls=0;const off=w.Skivu.on('host.pause',()=>calls++);w.__skivuEvent('host.pause',{});off();assert.equal(calls,1);const p=w.Skivu.call('storage.get');assert.equal(sent.length,1);w.__skivuEvent('host.suspend',null);await assert.rejects(p,e=>e.code==='CLOSED');await assert.rejects(w.Skivu.call('storage.get'),e=>e.code==='CLOSED');});
test('SDK has no hidden eight-call quota or default completion deadline',async()=>{
  const {w,sent,timers}=runtime();const pending=Array.from({length:72},()=>w.Skivu.call('host.info'));
  assert.equal(sent.length,72);assert.equal(timers.size,0);
  const stop=w.Skivu.call('device.engine.cancel',{requestId:'owned_request'});
  assert.equal(sent.at(-1).method,'device.engine.cancel');
  for(const frame of sent)w.__skivuResolve(frame.id,{ok:true,result:true});
  await Promise.all([...pending,stop]);
});
test('only an explicitly configured wait deadline rejects, without replaying',async()=>{
  const {w,sent,timers,advance}=runtime();const pending=w.Skivu.call('host.info',{}, {timeoutMs:15});
  const checked=assert.rejects(pending,e=>e.code==='TIMEOUT');advance(16);for(const fn of [...timers.values()])fn();await checked;
  w.__skivuResolve(sent[0].id,{ok:true,result:true});assert.equal(sent.length,1);
});
test('large valid content reaches the bridge without a universal JSON frame cap',async()=>{
  const {w,sent}=runtime();const content='x'.repeat(19*1024*1024);const pending=w.Skivu.call('fs.write',{path:'large.txt',base64:content});
  assert.equal(sent[0].params.base64,content);w.__skivuResolve(sent[0].id,{ok:true,result:true});assert.equal(await pending,true);
});
