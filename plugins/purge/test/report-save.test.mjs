import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {saveReport} from '../report-save.mjs';
test('report export waits for the actual host save and preserves Unicode',async()=>{
 let resolve;let finished=false;let params;
 const task=saveReport({call:async(method,p)=>{assert.equal(method,'files.save');params=p;return new Promise(r=>resolve=r);}},'# 演练报告\n真实记录','中文/fixture').then(()=>{finished=true;});
 await Promise.resolve();assert.equal(finished,false);assert.equal(Buffer.from(params.base64,'base64').toString('utf8'),'# 演练报告\n真实记录');assert.equal(params.name,'report-中文_fixture.md');resolve(true);await task;assert.equal(finished,true);
});
test('cancelling the Android picker cannot report a successful download',async()=>{
 await assert.rejects(saveReport({call:async()=>false},'fixture','fixture'),/取消/);
});
test('ported drill exports through the SDK instead of an unsupported download anchor',()=>{
 const source=fs.readFileSync('dist/drill.js','utf8');assert.match(source,/await window\.__skivuSaveReport/);assert.doesNotMatch(source,/a\.click\(\)/);
});
