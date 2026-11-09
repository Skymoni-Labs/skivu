import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
test('an interrupted host receipt stays unknown and is never retried',async()=>{
 let handler;const calls=[];
 vm.runInNewContext(fs.readFileSync('tools.js','utf8'),{Skivu:{on:(event,f)=>{handler=f;},call:async(method,params)=>{calls.push({method,params});if(method==='lab.call'){const e=Error('Original receipt interrupted');e.code='UNKNOWN';throw e;}}}});
 await handler({tool:'record',arguments:{request:'{"op":"import","engagement":"fixture","assets":[]}'}});
 assert.equal(calls.filter(c=>c.method==='lab.call').length,1);
 const result=calls.find(c=>c.method==='runtime.complete').params.result;
 assert.equal(result.outcome,'unknown');assert.equal(result.code,'UNKNOWN');assert.equal(result.ok,false);
});
