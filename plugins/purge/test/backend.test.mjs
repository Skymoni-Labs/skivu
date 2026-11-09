import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {labCall} from '../../../android/app/src/main/assets/cloud/lab.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'skivu-purge-'));
const owner='plugin:test.purge';
const raw=(request,flags={})=>labCall(root,owner,{request,...flags});
const call=(request,flags={})=>{const r=raw(request,flags);assert.notEqual(r.ok,false,r.error);return r;};
let engagement,backup;
test('upstream SQLite creates library and normalizes scope',()=>{
 engagement=call({op:'openEngagement',name:'Offline fixture',scope:'127.0.0.1/32'}).engagement.id;
 assert.equal(call({op:'bootstrap'}).current,engagement);
 assert.ok(call({op:'report',engagement}).markdown.includes('127.0.0.1/32'));
});
test('imports assets and service data and updates existing records',()=>{
 const request={op:'import',engagement,assets:[{ip:'127.0.0.1',primary_name:'fixture.local',ports:[{port:8080,service:'http'}]}]};
 call(request);call(request);
 const r=call({op:'assets',engagement});assert.equal(r.total,1);assert.equal(r.items[0].ports[0].port,8080);
});
test('confirmed finding is included in actual upstream report, candidate excluded',()=>{
 call({op:'addVuln',engagement,vuln:{title:'Fixture confirmed',target:'127.0.0.1',severity:'medium',status:'confirmed',evidence:'Offline fixture'}});
 call({op:'addVuln',engagement,vuln:{title:'Fixture unconfirmed',target:'127.0.0.1',severity:'high',status:'candidate'}});
 const report=call({op:'report',engagement});assert.match(report.markdown,/Fixture confirmed/);assert.doesNotMatch(report.markdown,/Fixture unconfirmed/);
});
test('original score rules, evidence and saved role prompts remain usable',()=>{
 assert.ok(call({op:'scores',engagement}).items.length>10);
 call({op:'savePrompt',engagement,role:call({op:'prompts',engagement}).roles[0].role,content:'Use explicit offline fixture.'});
 assert.ok(call({op:'prompts',engagement}).roles.some(r=>r.content==='Use explicit offline fixture.'));
 call({op:'addHttpEvidence',engagement,evidence:{target:'127.0.0.1',request_raw:'GET / HTTP/1.1\r\nHost: fixture.local\r\n\r\n',response_raw:'HTTP/1.1 200 OK\r\n\r\nfixture'}});
 assert.equal(call({op:'httpEvidence',engagement}).items.length,1);
});
test('model reads cannot write, and model writes cannot reuse old target',()=>{
 assert.throws(()=>raw({op:'openEngagement',name:'Denied'},{readOnly:true}),/只读/);
 assert.throws(()=>raw({op:'import',assets:[{ip:'127.0.0.2'}]},{assistant:true}),/明确指定/);
 const next=call({op:'openEngagement',name:'Second fixture'},{assistant:true});
 assert.notEqual(next.engagement.id,engagement);assert.equal(call({op:'bootstrap'}).current,engagement);
});
test('plugin library isolation and source-path confinement',()=>{
 assert.equal(labCall(root,'plugin:other.plugin',{request:{op:'bootstrap'}}).engagements.length,0);
 const source=path.join(root,'private-sentinel.txt');fs.writeFileSync(source,'PRIVATE');
 const r=raw({op:'addAttackFile',engagement,file:{target:'fixture',name:'copy.txt',evidence:'fixture',path:source}});
 assert.equal(r.ok,false);assert.doesNotMatch(JSON.stringify(r),/PRIVATE/);
});
test('22 skill bodies and one quarantined placeholder are truthful',()=>{
 const skills=call({op:'skillCatalog'});assert.equal(skills.items.length,23);assert.equal(skills.items.filter(s=>s.availability==='available').length,22);assert.equal(raw({op:'skillRead',name:'redteam/unauth-exploit.md'}).ok,false);
 assert.ok(call({op:'skillRead',name:skills.items[0].name}).content.length>100);
 assert.equal(call({op:'agentsStatus'}).available,false);
 assert.throws(()=>raw({op:'probeSessions',engagement}),/未启用网络探测/);
});
test('settings persist, export closes and reloads SQLite without data loss',()=>{
 call({op:'addAttackFile',engagement,file:{target:'fixture',name:'fixture.txt',evidence:'Offline test record',content:'fixture file content'}});
 call({op:'settingsSave',settings:{prompt:'小云测试规则',rules:[{name:'fixture',content:'keep receipts',enabled:true}],ownServers:['127.0.0.1'],enabled:true}});
 backup=call({op:'backupExport'}).backup;
 assert.ok(Object.keys(backup.files).some(f=>f.endsWith('assets.db')));
 assert.equal(call({op:'assets',engagement}).total,1);
 const groups=call({op:'attackFiles',engagement}).items;
 assert.equal(call({op:'readAttackFile',engagement,id:groups[0].files[0].id}).content,'fixture file content');
 assert.equal(call({op:'settingsGet'}).settings.prompt,'小云测试规则');
});
test('restore uses a new checked revision and preserves original data',()=>{
 call({op:'import',engagement,assets:[{ip:'127.0.0.2'}]});assert.equal(call({op:'assets',engagement}).total,2);
 const result=call({op:'backupRestore',backup});assert.equal(result.previousPreserved,true);
 assert.equal(call({op:'assets',engagement}).total,1);
 const files=call({op:'attackFiles',engagement}).items;
 assert.equal(call({op:'readAttackFile',engagement,id:files[0].files[0].id}).content,'fixture file content');
 assert.ok(fs.existsSync(path.join(root,'lab',path.basename(path.dirname(path.dirname(call({op:'bootstrap'}).root))),'revisions','initial')));
});
test('invalid backup cannot activate arbitrary paths or damaged contents',()=>{
 const before=call({op:'bootstrap'}).root;
 assert.throws(()=>call({op:'backupRestore',backup:{...backup,files:{'../../escape':{data:'',sha256:''}}}}),/路径/);
 assert.throws(()=>call({op:'backupRestore',backup:{...backup,files:{'bad.txt':{data:'eA==',sha256:'not-a-hash'}}}}),/校验/);
 assert.equal(call({op:'bootstrap'}).root,before);
 const versions=call({op:'backupVersions'});assert.equal(versions.items.length,2);
 call({op:'backupActivate',revision:'initial'});assert.equal(call({op:'assets',engagement}).total,2);
});
test('upstream source provenance and license preserved byte for byte',()=>{
 const provenance=JSON.parse(fs.readFileSync('PROVENANCE.json','utf8'));
 const crypto=process.getBuiltinModule('crypto');
 for(const [file,expected]of Object.entries(provenance.files)){if(provenance.quarantinedFiles?.[file]){assert.equal(fs.existsSync(path.join('upstream',file)),false);continue;}assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join('upstream',file))).digest('hex'),expected,file);}
});
test('a linked library root is rejected before creating files outside its namespace',()=>{
 const linkedBase=fs.mkdtempSync(path.join(os.tmpdir(),'skivu-purge-link-')),privateDir=fs.mkdtempSync(path.join(os.tmpdir(),'skivu-purge-private-'));
 fs.mkdirSync(path.join(linkedBase,'lab'));
 const digest=process.getBuiltinModule('crypto').createHash('sha256').update(owner).digest('hex');
 fs.symlinkSync(privateDir,path.join(linkedBase,'lab',digest),'junction');
 assert.throws(()=>labCall(linkedBase,owner,{request:{op:'bootstrap'}}),/指向外部/);
 assert.deepEqual(fs.readdirSync(privateDir),[]);
});
test('a new Node process reopens the persisted SQLite data and current revision',()=>{
 const module=new URL('../../../android/app/src/main/assets/cloud/lab.mjs',import.meta.url).href;
 const code=`import {labCall} from ${JSON.stringify(module)}; console.log(JSON.stringify(labCall(${JSON.stringify(root)},${JSON.stringify(owner)},{request:{op:'assets',engagement:${JSON.stringify(engagement)}}})));`;
 const output=process.getBuiltinModule('child_process').execFileSync(process.execPath,['--input-type=module','-e',code],{encoding:'utf8'});
 assert.equal(JSON.parse(output).total,2);
});
