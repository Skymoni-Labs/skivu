// SPDX-License-Identifier: GPL-3.0-only
// Built-in programming backend. stdin/stdout are private inherited pipes, never
// a public HTTP endpoint. The Android host supplies owner/task/request identity.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import {spawn, spawnSync} from 'node:child_process';
import * as zlib from 'node:zlib';

const base = process.env.SKIVU_CLOUD_ROOT || '/root/skivu-home/cloud';
const workspace = process.env.SKIVU_CLOUD_WORKSPACE || '/workspace';
fs.mkdirSync(base, {recursive:true}); fs.mkdirSync(workspace,{recursive:true});
const jobsDir = path.join(base,'jobs'), receiptsDir=path.join(base,'receipts');
fs.mkdirSync(jobsDir,{recursive:true}); fs.mkdirSync(receiptsDir,{recursive:true});
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
const id = () => crypto.randomUUID();
const safeId = v => typeof v==='string' && /^[a-zA-Z0-9_-]{1,120}$/.test(v);
const atomic = (file, value) => { const tmp=file+'.'+id()+'.tmp';fs.writeFileSync(tmp,JSON.stringify(value));fs.renameSync(tmp,file); };
const json = (file,fallback) => {try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch(e){if(e.code==='ENOENT')return fallback;throw e;}};
const projectsFile=path.join(base,'projects.json');
let projects=json(projectsFile,[]);
function refreshProjects(){const all=[...json(projectsFile,[]),...json(path.join(base,'migrated-projects.json'),[])];projects=[...new Map(all.map(p=>[p.id,p])).values()];}
const jobs=new Map();
const boot=(()=>{try{return fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim();}catch{return id();}})();
function startTicks(pid) { try {const s=fs.readFileSync(`/proc/${pid}/stat`,'utf8');return s.slice(s.lastIndexOf(')')+2).split(' ')[19];}catch{return null;} }
function parentAlive(j){return j.boot===boot&&j.startTicks&&startTicks(j.pid)===j.startTicks;}
function members(j){
 if(j.boot!==boot||!j.killToken)return [];
 const found=[];for(const name of fs.readdirSync('/proc')){if(!/^\d+$/.test(name))continue;try{
   const environment=fs.readFileSync(`/proc/${name}/environ`);if(environment.includes(Buffer.from('SKIVU_CLOUD_JOB='+j.killToken+'\0'))){const ticks=startTicks(name);if(ticks)found.push({pid:Number(name),ticks});}
 }catch{}}
 return found;
}
function alive(j) {return parentAlive(j)||members(j).length>0;}
function persistJob(j){const {child,...record}=j;atomic(path.join(jobsDir,j.id+'.json'),record);}
for(const name of fs.readdirSync(jobsDir).filter(n=>n.endsWith('.json'))){
  const j=json(path.join(jobsDir,name),null);if(!j)continue;
  if(['running','stopping'].includes(j.state)){j.state=alive(j)?'running':'unknown';j.recovered=true;persistJob(j);}jobs.set(j.id,j);
}
function project(args) {
  const p=projects.find(p=>p.id===args.projectId&&!p.archived);if(!p)throw Error('项目不存在或已归档，请先选择项目。');
  const root=path.join(workspace,p.id);if(!fs.statSync(root).isDirectory()||fs.realpathSync(root)!==root)throw Error('项目目录已变化。');
  return {p,root};
}
function resolveFile(root, relative='.', {write=false}={}) {
  if(typeof relative!=='string'||relative.length>1800||relative.includes('\0')||relative.includes('\\')||path.isAbsolute(relative)||relative.split('/').includes('..'))throw Error('路径必须位于当前项目内。');
  const dest=path.resolve(root,relative);if(dest!==root&&!dest.startsWith(root+'/'))throw Error('路径越界。');
  let cursor=dest;
  while(!fs.existsSync(cursor)){const parent=path.dirname(cursor);if(parent===cursor)throw Error('路径不存在。');cursor=parent;}
  const actual=fs.realpathSync(cursor);if(actual!==root&&!actual.startsWith(root+'/'))throw Error('符号链接指向项目之外。');
  if(write&&dest===root)throw Error('不能覆盖项目根目录。');return dest;
}
function writable(root,args, owner){
  const active=[...jobs.values()].filter(j=>j.projectId===args.projectId&&j.owner!==owner&&alive(j));
  if(active.length)throw Error('此项目正由其他任务运行，未修改文件。');
  const file=resolveFile(root,args.path,{write:true});
  if(fs.existsSync(file)){
    if(!fs.statSync(file).isFile())throw Error('目标不是普通文件。');
    const before=hash(fs.readFileSync(file));if(args.expectedSha256!==before)throw Error('文件已存在或变化。请读取后传入最新 expectedSha256，不能无提示覆盖。');
  } else if(args.expectedSha256 && args.expectedSha256!=='absent')throw Error('原文件已不存在。');
  return file;
}
function walk(root,relative='.',max=2000){
  const result=[];const visit=r=>{if(result.length>=max)return;const d=resolveFile(root,r);for(const entry of fs.readdirSync(d,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name))){
    const n=r==='.'?entry.name:r+'/'+entry.name;if(entry.isSymbolicLink()){result.push({path:n,type:'symlink'});continue;}
    if(entry.isDirectory()){if(['node_modules','.git','.cache','build','dist'].includes(entry.name))continue;result.push({path:n,type:'directory'});visit(n);}else if(entry.isFile())result.push({path:n,type:'file',bytes:fs.statSync(path.join(root,n)).size});if(result.length>=max)break;
  }};visit(relative);return result;
}
const outputLimit=1024*1024*16;
function output(j,stream,chunk){const file=path.join(jobsDir,j.id+'.'+stream);let count=j[stream+'Bytes']||0;const slice=chunk.subarray(0,Math.max(0,outputLimit-count));if(slice.length)fs.appendFileSync(file,slice);j[stream+'Bytes']=count+chunk.length;j.outputTruncated=j.outputTruncated||count+chunk.length>outputLimit;}
function readJob(j,args={}){
 const read=s=>{const file=path.join(jobsDir,j.id+'.'+s), offset=Math.max(0,Number(args[s+'Offset'])||0);if(!fs.existsSync(file))return {text:'',offset};const fd=fs.openSync(file,'r');try{const size=fs.fstatSync(fd).size, b=Buffer.alloc(Math.min(48000,Math.max(0,size-offset)));const n=fs.readSync(fd,b,0,b.length,offset);return {text:b.subarray(0,n).toString('utf8'),offset:offset+n};}finally{fs.closeSync(fd);}};
 if(j.state==='running'&&!j.child&&!alive(j)){j.state='unknown';persistJob(j);}
 const {child,killToken,...record}=j;return {...record,inputAvailable:!!child?.stdin&&!child.stdin.destroyed,stdout:read('stdout'),stderr:read('stderr')};
}
async function stopJob(j){
 if(!['running','stopping'].includes(j.state))return readJob(j);
 j.state='stopping';persistJob(j);
 if(!alive(j)){j.state='unknown';persistJob(j);return readJob(j);}
 const signal=name=>{if(parentAlive(j)){try{process.kill(-j.pid,name);}catch(e){if(e.code!=='ESRCH')throw e;}}for(const member of members(j)){if(startTicks(member.pid)===member.ticks){try{process.kill(member.pid,name);}catch(e){if(e.code!=='ESRCH')throw e;}}}};
 signal('SIGTERM');
 for(let i=0;i<15&&alive(j);i++)await new Promise(r=>setTimeout(r,100));
 if(alive(j))signal('SIGKILL');
 for(let i=0;i<20&&alive(j);i++){signal('SIGKILL');await new Promise(r=>setTimeout(r,100));}
 if(alive(j))j.state='unknown';else if(j.state==='stopping')j.state='stopped';persistJob(j);return readJob(j);
}
function ownJob(args,owner){const j=jobs.get(args.jobId);if(!j||j.owner!==owner)throw Error('任务进程不存在或不属于本会话。');return j;}
function toolchain(){const commands=['node','npm','python3','git','bash','sh','make','gcc','g++','rg','curl','zip','unzip'];return commands.map(name=>{const r=spawnSync('/bin/sh',['-c','command -v "$1"','probe',name],{encoding:'utf8'});return {name,available:r.status===0,path:r.stdout.trim()};});}
async function invoke(tool,args,ctx){
 const {owner,taskId,requestId}=ctx;
 refreshProjects();
 if(tool==='coding.environment')return {node:process.version,platform:process.platform,arch:process.arch,workspace,tools:toolchain(),formatsModule:'/opt/skivu-cloud/formats.mjs',formatsApi:'import {writeWorkbook,writeDocument,packageProject} from "/opt/skivu-cloud/formats.mjs"; writeWorkbook(file,[{name,rows:[[value,{value,formula,format,bold}]],widths,freezeRows}]); writeDocument(file,[{text,heading}]); packageProject(file,projectRoot,explicitRelativeFilePaths)',sandbox:'PRoot compatibility layer; authorized code can access this app runtime',resources:'DSH 0.2.1-rc.2 / Ubuntu / Node, bundled and SHA-256 verified'};
 if(tool==='coding.projects.list')return projects;
 if(tool==='coding.legacy.sessions'){
   const root=path.join(path.dirname(base),'legacy-dsh-home');if(!fs.existsSync(root))return {sessions:[],sourcePreserved:true};
   const sessions=[];function visit(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){if(sessions.length>=5000)return;const file=path.join(dir,entry.name);if(entry.isSymbolicLink()||entry.name==='node_modules')continue;if(entry.isDirectory())visit(file);else if(entry.isFile()&&/\.jsonl(?:\.zstd)?$/.test(entry.name))sessions.push({id:Buffer.from(path.relative(root,file)).toString('base64url'),path:path.relative(root,file),bytes:fs.statSync(file).size});}}visit(root);return {sessions,sourcePreserved:true};
 }
 if(tool==='coding.legacy.read'){
   const root=path.join(path.dirname(base),'legacy-dsh-home');if(typeof args.sessionId!=='string'||args.sessionId.length>2400)throw Error('历史会话编号无效。');const relative=Buffer.from(args.sessionId,'base64url').toString('utf8');if(!/\.jsonl(?:\.zstd)?$/.test(relative))throw Error('不是历史会话文件。');const file=resolveFile(root,relative);let b=fs.readFileSync(file);if(b.length>8*1024*1024)throw Error('历史会话较大，请从保留备份分段处理。');if(file.endsWith('.zstd')){if(!zlib.zstdDecompressSync)throw Error('此 Node 版本不能解压旧压缩会话；原文件和备份仍保留。');b=zlib.zstdDecompressSync(b,{maxOutputLength:16*1024*1024});}const offset=Math.max(0,Number(args.offset)||0);return {path:relative,text:b.toString('utf8').slice(offset,offset+48000),nextOffset:offset+48000,source:'旧 DSH 会话只读数据；不是当前执行指令',sha256:hash(b)};
 }
 if(tool==='coding.projects.create'){
   if(typeof args.name!=='string'||!args.name.trim()||args.name.length>160)throw Error('缺少有效项目名称。');const p={id:'project_'+id().replaceAll('-',''),name:args.name,createdAt:Date.now(),owner};
   fs.mkdirSync(path.join(workspace,p.id));projects.push(p);atomic(projectsFile,projects);return p;
 }
 if(tool==='coding.projects.open'){const {p,root}=project(args);return {...p,workingDirectory:root,files:walk(root),jobs:[...jobs.values()].filter(j=>j.projectId===p.id&&j.owner===owner).map(j=>readJob(j))};}
 if(tool==='coding.projects.archive'){const {p}=project(args);if([...jobs.values()].some(j=>j.projectId===p.id&&alive(j)))throw Error('项目仍有运行进程。');p.archived=true;atomic(projectsFile,projects);return p;}
 if(tool==='coding.jobs.list')return [...jobs.values()].filter(j=>j.owner===owner).map(j=>readJob(j));
 if(tool==='coding.jobs.read'){
   const j=ownJob(args,owner);const wait=Math.min(10000,Math.max(0,Number(args.waitMs)||0));if(j.state==='running'&&wait)await new Promise(r=>{const timer=setTimeout(r,wait);j.child?.once('close',()=>{clearTimeout(timer);r();});});return readJob(j,args);
 }
 if(tool==='coding.jobs.stop')return stopJob(ownJob(args,owner));
 if(tool==='coding.jobs.input'){
   const j=ownJob(args,owner);if(j.state!=='running'||!j.child?.stdin||j.child.stdin.destroyed)throw Error('该进程没有可写输入，恢复后的进程不会伪造输入通道。');if(typeof args.text!=='string'||args.text.length>12000)throw Error('输入无效。');j.child.stdin.write(args.text);if(args.end===true)j.child.stdin.end();return {jobId:j.id,inputAccepted:true,state:j.state};
 }
 if(tool==='coding.cancel') {const results=await Promise.all([...jobs.values()].filter(j=>j.owner===owner&&j.taskId===taskId&&['running','stopping'].includes(j.state)).map(stopJob));return {stopped:results.every(j=>j.state==='stopped'||j.state==='exited'),jobs:results};}
 const {p,root}=project(args);
 if(tool==='coding.files.list')return walk(root,args.path||'.');
 if(tool==='coding.files.glob'){
   if(typeof args.pattern!=='string'||args.pattern.length>500)throw Error('文件匹配模式无效。');const escaped=args.pattern.replace(/[.+^${}()|[\]\\]/g,'\\$&').replaceAll('**/','\u0002').replaceAll('**','\u0001').replaceAll('*','[^/]*').replaceAll('?','[^/]').replaceAll('\u0001','.*').replaceAll('\u0002','(?:.*/)?');const re=new RegExp('^'+escaped+'$');return walk(root).filter(f=>re.test(f.path));
 }
 if(tool==='coding.files.image'){
   const file=resolveFile(root,args.path),b=fs.readFileSync(file);if(!b.length||b.length>600000)throw Error('图像需要先用实际可用工具缩小至 600 KB 内。');let mime;
   if(b.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))mime='image/png';else if(b[0]===255&&b[1]===216)mime='image/jpeg';else if(b.toString('ascii',0,4)==='RIFF'&&b.toString('ascii',8,12)==='WEBP')mime='image/webp';else throw Error('不是支持的真实图像文件。');return {path:args.path,image:`data:${mime};base64,${b.toString('base64')}`,sha256:hash(b),requiresVisionModel:true};
 }
 if(tool==='coding.files.read'){
   const file=resolveFile(root,args.path);const b=fs.readFileSync(file);if(b.length>2*1024*1024)throw Error('文件过大，请使用命令分段检查。');
   const text=b.toString('utf8'),offset=Math.max(0,Number(args.offset)||0);return {path:args.path,sha256:hash(b),bytes:b.length,text:text.slice(offset,offset+48000),nextOffset:Math.min(text.length,offset+48000),complete:offset+48000>=text.length};
 }
 if(tool==='coding.files.search'){
   if(typeof args.query!=='string'||!args.query||args.query.length>500)throw Error('缺少搜索内容。');const matches=[];
   for(const f of walk(root)){if(f.type!=='file'||f.bytes>1024*1024)continue;const file=resolveFile(root,f.path);const b=fs.readFileSync(file);if(b.includes(0))continue;const lines=b.toString('utf8').split('\n');for(let i=0;i<lines.length;i++)if(lines[i].includes(args.query))matches.push({path:f.path,line:i+1,text:lines[i].slice(0,700)});if(matches.length>=100)break;}return matches.slice(0,100);
 }
 if(tool==='coding.files.write'||tool==='coding.files.edit'){
   const file=writable(root,args,owner);let content=args.content;
   const before=fs.existsSync(file)?fs.readFileSync(file):null;
   if(tool==='coding.files.edit'){
     if(!before||typeof args.oldText!=='string'||!args.oldText||typeof args.newText!=='string')throw Error('编辑需要原文件和明确替换内容。');
     const text=before.toString('utf8');if(text.split(args.oldText).length!==2)throw Error('替换片段不存在或不唯一。');content=text.replace(args.oldText,args.newText);
   }
   if(typeof content!=='string'||Buffer.byteLength(content)>2*1024*1024)throw Error('文件内容无效或过大。');
   const history=path.join(base,'changes',p.id,hash(args.path));fs.mkdirSync(history,{recursive:true});if(before)fs.writeFileSync(path.join(history,'previous.txt'),before);else fs.writeFileSync(path.join(history,'previous.txt'),'');
   fs.mkdirSync(path.dirname(file),{recursive:true});const tmp=file+'.'+id()+'.tmp';fs.writeFileSync(tmp,content);fs.renameSync(tmp,file);
   const b=fs.readFileSync(file);if(!b.equals(Buffer.from(content)))throw Error('写入后内容核对失败。');
   atomic(path.join(history,'change.json'),{path:args.path,previousSha256:before?hash(before):null,sha256:hash(b),owner,taskId,requestId});
   return {path:args.path,bytes:b.length,sha256:hash(b),previousSha256:before?hash(before):null,verified:true};
 }
 if(tool==='coding.files.patch'){
   // Deliberately narrow, hash-guarded unified patch. No shell interpolation.
   const file=writable(root,args,owner);if(typeof args.patch!=='string'||args.patch.length>200000)throw Error('补丁无效。');
   const before=fs.readFileSync(file,'utf8'), source=before.split('\n');let cursor=0,out=[],count=0;
   const lines=args.patch.split('\n');for(let i=0;i<lines.length;i++){
     const m=/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(lines[i]);if(!m)continue;count++;
     const at=Math.max(0,Number(m[1])-1);if(at<cursor)throw Error('补丁顺序冲突。');out.push(...source.slice(cursor,at));cursor=at;let oldCount=0,newCount=0;
     while(i+1<lines.length&&!lines[i+1].startsWith('@@')){const l=lines[++i];if(l==='\\ No newline at end of file'||l===''&&i===lines.length-1)continue;const k=l[0],v=l.slice(1);if(![' ','-','+'].includes(k))throw Error('补丁行无效。');if(k!=='+'&&source[cursor++]!==v)throw Error('补丁与当前文件不匹配。');if(k!=='+')oldCount++;if(k!=='-'){out.push(v);newCount++;}}
     if(oldCount!==Number(m[2]??1)||newCount!==Number(m[4]??1))throw Error('补丁行数无效。');
   }if(!count)throw Error('没有有效补丁段。');out.push(...source.slice(cursor));return invoke('coding.files.write',{...args,content:out.join('\n')},ctx);
 }
 if(tool==='coding.files.diff'){
   const file=resolveFile(root,args.path);const history=path.join(base,'changes',p.id,hash(args.path));
   if(!fs.existsSync(path.join(history,'change.json')))return {available:false,message:'此文件没有经内置编辑器保存的前一版本；原有 Git 若未安装不能伪造仓库差异。'};
   const before=fs.readFileSync(path.join(history,'previous.txt'),'utf8').split('\n'),after=fs.readFileSync(file,'utf8').split('\n');let start=0,end=0;while(start<before.length&&start<after.length&&before[start]===after[start])start++;while(end<before.length-start&&end<after.length-start&&before[before.length-1-end]===after[after.length-1-end])end++;
   const change=json(path.join(history,'change.json'),{});const from=Math.max(0,start-3),toBefore=Math.min(before.length,before.length-end+3),toAfter=Math.min(after.length,after.length-end+3);
   const diff=start===before.length&&start===after.length?'':`--- a/${args.path}\n+++ b/${args.path}\n@@ -${from+1},${toBefore-from} +${from+1},${toAfter-from} @@\n`+before.slice(from,start).map(l=>' '+l).join('\n')+'\n'+before.slice(start,before.length-end).map(l=>'-'+l).join('\n')+'\n'+after.slice(start,after.length-end).map(l=>'+'+l).join('\n')+'\n'+after.slice(after.length-end,toAfter).map(l=>' '+l).join('\n');
   return {available:true,path:args.path,previousSha256:change.previousSha256,currentSha256:hash(fs.readFileSync(file)),diff:diff.slice(0,48000),truncated:diff.length>48000};
 }
 if(tool==='coding.exec.start'){
   if(typeof args.command!=='string'||!args.command.trim()||args.command.length>24000)throw Error('命令无效。');
   if([...jobs.values()].filter(j=>j.state==='running'&&alive(j)).length>=8)throw Error('已有 8 个运行任务，请先完成或停止。');
   if([...jobs.values()].some(j=>j.projectId===p.id&&j.owner!==owner&&alive(j)))throw Error('其他会话正在此项目运行。');
   const cwd=resolveFile(root,args.cwd||'.');if(!fs.statSync(cwd).isDirectory())throw Error('工作目录无效。');
   const timeoutMs=Math.min(3600000,Math.max(1000,Number(args.timeoutMs)||600000));
   const job={id:'job_'+id().replaceAll('-',''),killToken:id(),owner,taskId,requestId,projectId:p.id,cwd,command:args.command,state:'starting',createdAt:Date.now(),boot,stdoutBytes:0,stderrBytes:0};
   jobs.set(job.id,job);persistJob(job);
   const child=spawn('/bin/bash',['-lc',args.command],{cwd,detached:true,env:{...process.env,HOME:'/root/skivu-home',PWD:cwd,SKIVU_TASK_ID:taskId,SKIVU_CLOUD_JOB:job.killToken},stdio:['pipe','pipe','pipe']});job.child=child;job.pid=child.pid;job.startTicks=startTicks(child.pid);job.state='running';persistJob(job);
   child.stdout.on('data',b=>output(job,'stdout',b));child.stderr.on('data',b=>output(job,'stderr',b));
   child.on('error',e=>{output(job,'stderr',Buffer.from(e.message));job.state='failed';job.error=e.code;persistJob(job);});
   child.on('close',(exitCode,signal)=>{
     job.exitCode=exitCode;job.signal=signal;job.parentExited=true;
     if(members(job).length>0){job.detachedChildrenObserved=true;persistJob(job);const monitor=setInterval(()=>{if(!members(job).length){clearInterval(monitor);if(job.state==='running')job.state='unknown';persistJob(job);}},500);monitor.unref();return;}
     clearTimeout(job.timer);delete job.timer;job.finishedAt=Date.now();job.state=job.state==='stopping'?'stopped':job.state==='failed'?'failed':'exited';persistJob(job);
   });
   const timer=setTimeout(()=>{job.timedOut=true;void stopJob(job);},timeoutMs);timer.unref();Object.defineProperty(job,'timer',{value:timer,writable:true,configurable:true,enumerable:false});
   await new Promise(r=>setTimeout(r,Math.min(500,Math.max(0,Number(args.waitMs)||150))));return readJob(job);
 }
 if(tool==='coding.deliver.prepare'){
   if(!Array.isArray(args.files)||!args.files.length||args.files.length>40)throw Error('必须提供明确的最终成果清单（1–40 项）；不能自动扫描目录交付。');
   const seen=new Set(), files=[],failed=[];
   for(const item of args.files){try{if(!item||typeof item.path!=='string'||typeof item.purpose!=='string'||!item.purpose.trim())throw Error('每个成果必须有路径和交付用途。');const file=resolveFile(root,item.path);const s=fs.statSync(file);if(!s.isFile()||s.size===0||s.size>200*1024*1024)throw Error('成果不是可读取的非空文件，或超过 200 MB。');if(seen.has(file))continue;seen.add(file);const b=fs.readFileSync(file);files.push({projectId:p.id,path:item.path,absolutePath:file,name:path.basename(file),bytes:b.length,sha256:hash(b),purpose:item.purpose.slice(0,1000)});}catch(e){failed.push({path:item?.path,error:e.message});}}
   return {files,failed,taskId,owner,explicitManifest:true};
 }
 throw Error('未知编程工具。');
}

export async function dispatch(frame){
 const {tool,args={},owner,taskId,requestId}=frame;
 if(typeof owner!=='string'||owner.length>180||typeof taskId!=='string'||taskId.length>160||!safeId(requestId))throw Error('缺少宿主执行身份。');
 const key=hash(owner+'\0'+requestId),receipt=path.join(receiptsDir,key+'.json'),fingerprint=hash(JSON.stringify({tool,args,taskId}));
 const prior=json(receipt,null);if(prior){if(prior.fingerprint!==fingerprint)throw Error('请求标识被用于不同操作。');if(prior.state==='prepared')return {outcome:'unknown',message:'上次操作中断，先检查项目和进程，不自动重放。'};return prior.result;}
 const readOnly=/^coding\.(environment|legacy\.(sessions|read)|projects\.(list|open)|files\.(list|read|search|glob|image|diff)|jobs\.(list|read))$/.test(tool);
 if(!readOnly)atomic(receipt,{fingerprint,state:'prepared',taskId,tool});
 try{const value=await invoke(tool,args,{owner,taskId,requestId});const result={outcome:'verified',value};if(!readOnly)atomic(receipt,{fingerprint,state:'done',result});return result;}
 catch(e){const result={outcome:'failed',message:String(e.message).slice(0,4000)};if(!readOnly)atomic(receipt,{fingerprint,state:'done',result});return result;}
}
if(process.env.SKIVU_EXECUTOR_TEST!=='1'){
 const lines=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
 lines.on('line',line=>{if(line.length>4*1024*1024)return;let frame;try{frame=JSON.parse(line);}catch{return;}
   void dispatch(frame).then(result=>process.stdout.write(JSON.stringify({id:frame.id,...result})+'\n'),e=>process.stdout.write(JSON.stringify({id:frame.id,outcome:'failed',message:e.message})+'\n'));
 });
 process.stdout.write(JSON.stringify({ready:true,node:process.version,pid:process.pid})+'\n');
}
