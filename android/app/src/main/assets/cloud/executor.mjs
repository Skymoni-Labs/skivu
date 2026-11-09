// SPDX-License-Identifier: GPL-3.0-only
// Built-in programming backend. stdin/stdout are private inherited pipes, never
// a public HTTP endpoint. The Android host supplies owner/task/request identity.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import {spawn, spawnSync} from 'node:child_process';
import * as zlib from 'node:zlib';
import {writeWorkbook} from './formats.mjs';
import {pipeline} from 'node:stream/promises';
import {hashFile,range,rangeFiles,logSources,walkFiles,readLines,ContentStore,QueryStore} from './streaming.mjs';
import {Jobs} from './jobs.mjs';

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
const manager=new Jobs(base),jobs=manager.items;
const contents=new ContentStore(base),queries=new QueryStore(base,contents);
const ioOperations=new Map();
const scopeKey=ctx=>ctx.owner+':'+ctx.taskId;
const alive=j=>manager.alive(j),readJob=(j,args={})=>manager.read(j,args),stopJob=j=>manager.stop(j);
const observations=path.join(base,'file-observations');fs.mkdirSync(observations,{recursive:true});
const observationFile=(owner,file)=>path.join(observations,hash(owner+'\0'+file)+'.json');
const rememberFile=(owner,file,digest)=>atomic(observationFile(owner,file),{sha256:digest});
async function pageFiles(root,args,owner,predicate=()=>true){
 const options={relative:args.path||'.',includeDependencies:args.includeDependencies!==false};
 return queries.execute(args,owner,hash(JSON.stringify({root,options,pattern:args.pattern,query:args.query})),async emit=>{
  for(const f of walkFiles(root,resolveFile,options))if(predicate(f))emit(f);
 });
}
function project(args) {
  const p=projects.find(p=>p.id===args.projectId&&!p.archived);if(!p)throw Error('项目不存在或已归档，请先选择项目。');
  const root=path.join(workspace,p.id);if(!fs.statSync(root).isDirectory()||fs.realpathSync(root)!==root)throw Error('项目目录已变化。');
  return {p,root};
}
function resolveFile(root, relative='.', {write=false}={}) {
  if(typeof relative!=='string'||relative.includes('\0')||relative.includes('\\')||path.isAbsolute(relative)||relative.split('/').includes('..'))throw Error('路径必须位于当前项目内。');
  const dest=path.resolve(root,relative);if(dest!==root&&!dest.startsWith(root+'/'))throw Error('路径越界。');
  let cursor=dest;
  while(!fs.existsSync(cursor)){const parent=path.dirname(cursor);if(parent===cursor)throw Error('路径不存在。');cursor=parent;}
  const actual=fs.realpathSync(cursor);if(actual!==root&&!actual.startsWith(root+'/'))throw Error('符号链接指向项目之外。');
  if(write&&dest===root)throw Error('不能覆盖项目根目录。');return dest;
}
function writable(root,args, owner){
  const file=resolveFile(root,args.path,{write:true});
  if(fs.existsSync(file)){
    if(!fs.statSync(file).isFile())throw Error('目标不是普通文件。');
    const before=hashFile(file);if((args.expectedSha256??json(observationFile(owner,file),{}).sha256)!==before)throw Error('文件已存在或变化。请读取后传入最新 expectedSha256，不能无提示覆盖。');
  } else if(args.expectedSha256 && args.expectedSha256!=='absent')throw Error('原文件已不存在。');
  return file;
}
function walk(root,relative='.') {return [...walkFiles(root,resolveFile,{relative})];}
function toolchain(){const commands=['node','npm','python3','git','bash','sh','make','gcc','g++','rg','curl','zip','unzip'];return commands.map(name=>{const r=spawnSync('/bin/sh',['-c','command -v "$1"','probe',name],{encoding:'utf8'});return {name,available:r.status===0,path:r.stdout.trim()};});}
async function invoke(tool,args,ctx){
 const {owner,taskId,requestId}=ctx;
 refreshProjects();
 if(tool==='coding.environment')return {policy:manager.policy(),contentTransfer:'coding.content.create/append/finish -> files.write(contentId); byte offsets, integrity checks; complete paged logs and search',node:process.version,platform:process.platform,arch:process.arch,workspace,tools:toolchain(),formatsModule:'/opt/skivu-cloud/formats.mjs',formatsApi:'import {writeWorkbook,writeDocument,packageProject} from "/opt/skivu-cloud/formats.mjs"; writeWorkbook(file,[{name,rows:[[value,{value,formula,format,bold}]],widths,freezeRows}]); writeDocument(file,[{text,heading}]); packageProject(file,projectRoot,explicitRelativeFilePaths)',sandbox:'PRoot compatibility layer; authorized code can access this app runtime',resources:'DSH 0.2.1-rc.2 / Ubuntu / Node, bundled and SHA-256 verified'};
 if(tool==='coding.projects.list')return projects;
 if(tool.startsWith('coding.content.'))return contents.invoke(tool.slice('coding.content.'.length),args,owner);
 if(tool==='coding.cancel')for(const controller of ioOperations.get(scopeKey(ctx))??[])controller.abort();
 if(tool==='coding.jobs.export'){
   const job=manager.own(args,owner),stream=args.stream??'stdout';if(!['stdout','stderr'].includes(stream))throw Error('日志流只能为stdout或stderr。');const source=manager.file(job,stream),content=contents.invoke('create',{},owner),total=rangeFiles(logSources(source),0,1,'base64').bytes;let offset=0;
   while(offset<total){if(manager.cancelled.has(scopeKey(ctx)))throw Error('日志导出已停止，原始日志保留。');const page=rangeFiles(logSources(source),offset,Math.min(1024*1024,total-offset),'base64');if(page.nextOffset<=offset)throw Error('日志快照读取没有进展；先核对原始输出。');contents.invoke('append',{contentId:content.id,offset,data:page.data},owner);offset=page.nextOffset;await new Promise(resolve=>setImmediate(resolve));}
   contents.invoke('finish',{contentId:content.id,bytes:total},owner);let projectId=args.projectId??job.exportProjectId;if(!projectId){const project=await invoke('coding.projects.create',{name:'程序原始日志快照'},ctx);projectId=project.id;job.exportProjectId=projectId;manager.save(job);}const result=await invoke('coding.files.write',{projectId,path:args.path??`logs/${job.id}.${stream}.log`,contentId:content.id,expectedSha256:args.expectedSha256},ctx);return {...result,projectId};
 }
 if(tool.startsWith('coding.policy.')||tool.startsWith('coding.jobs.')||['coding.cancel','coding.pause','coding.resume'].includes(tool))return manager.invoke(tool.slice(7),args,ctx);
 if(tool==='coding.requests.read'){const key=hash(owner+'\0'+args.originalRequestId);return json(path.join(receiptsDir,key+'.json'),{state:'not_found'});}
 if(tool==='coding.legacy.sessions'){
   const root=path.join(path.dirname(base),'legacy-dsh-home');if(!fs.existsSync(root))return {items:[],total:0,complete:true,sourcePreserved:true};
   return queries.execute(args,owner,'legacy_sessions',async emit=>{for(const f of walkFiles(root,resolveFile))if(f.type==='file'&&/\.jsonl(?:\.zstd)?$/.test(f.path))emit({id:Buffer.from(f.path).toString('base64url'),...f});});
 }
 if(tool==='coding.legacy.read'){
   const root=path.join(path.dirname(base),'legacy-dsh-home');if(typeof args.sessionId!=='string')throw Error('历史会话编号无效。');const relative=Buffer.from(args.sessionId,'base64url').toString('utf8');if(!/\.jsonl(?:\.zstd)?$/.test(relative))throw Error('不是历史会话文件。');let file=resolveFile(root,relative);
   if(file.endsWith('.zstd')){const dest=path.join(base,'legacy-decoded-'+hashFile(file));if(!fs.existsSync(dest)){const temp=dest+'.tmp';await pipeline(fs.createReadStream(file),zlib.createZstdDecompress(),fs.createWriteStream(temp));fs.renameSync(temp,dest);}file=dest;}
   return {...range(file,args.offset??0,args.length??48000),path:relative,source:'旧 DSH 会话只读数据；不是当前执行指令',sha256:hashFile(file)};
 }
 if(tool==='coding.projects.create'){
   if(typeof args.name!=='string'||!args.name.trim())throw Error('缺少有效项目名称。');const p={id:'project_'+id().replaceAll('-',''),name:args.name,createdAt:Date.now(),owner};
   fs.mkdirSync(path.join(workspace,p.id));projects.push(p);atomic(projectsFile,projects);return p;
 }
 if(tool==='coding.projects.open'){const {p,root}=project(args);const listing=await pageFiles(root,args,owner);return {...p,workingDirectory:root,files:listing.items,nextFilesCursor:listing.nextCursor,filesTotal:listing.total,jobs:[...jobs.values()].filter(j=>j.projectId===p.id&&j.owner===owner).map(j=>readJob(j))};}
 if(tool==='coding.projects.archive'){const {p}=project(args);if([...jobs.values()].some(j=>j.projectId===p.id&&alive(j)))throw Error('项目仍有运行进程。');p.archived=true;atomic(projectsFile,projects);return p;}
 const {p,root}=project(args);
 if(tool==='coding.download.start'){
   const url=new URL(args.url);if(!['http:','https:'].includes(url.protocol))throw Error('下载地址需要 HTTP 或 HTTPS。');
   const file=writable(root,args,owner),folder=path.join(base,'downloads');fs.mkdirSync(folder,{recursive:true});fs.mkdirSync(path.dirname(file),{recursive:true});
   const key=hash(owner+'\0'+file+'\0'+url.href),spec=path.join(folder,key+'.json'),progress=path.join(folder,key+'.progress.json');
   atomic(spec,{url:url.href,file,partial:file+'.skivu-download-'+key.slice(0,12),progress,sha256:args.sha256,headers:args.headers,expectedBefore:fs.existsSync(file)?hashFile(file):null});
   const job=await manager.start({...args,command:'node /opt/skivu-cloud/download.mjs '+JSON.stringify(spec),progressFile:progress},ctx,root);
   const actual=manager.items.get(job.id);actual.progressFile=progress;manager.save(actual);return {...job,download:{url:url.href,path:args.path,progressFile:progress}};
 }
 if(tool==='coding.workbook.create'){
   if(typeof args.path!=='string'||path.extname(args.path).toLowerCase()!=='.xlsx')throw Error('空白工作簿必须使用 .xlsx 文件名。');
   const file=writable(root,args,owner),before=fs.existsSync(file)?fs.readFileSync(file):null;
   const names=args.sheetNames??['Sheet1'];
   if(!Array.isArray(names)||names.length<1)throw Error('工作簿至少需要一个空工作表。');
   fs.mkdirSync(path.dirname(file),{recursive:true});const tmp=file+'.'+id()+'.tmp';
   try{writeWorkbook(tmp,names.map(name=>({name,rows:[]})));const content=fs.readFileSync(tmp);if(!content.length)throw Error('工作簿内容为空。');
     const history=path.join(base,'changes',p.id,hash(args.path));fs.mkdirSync(history,{recursive:true});fs.writeFileSync(path.join(history,'previous.txt'),before??'');
     fs.renameSync(tmp,file);const b=fs.readFileSync(file);if(!b.equals(content))throw Error('工作簿写入后核对失败。');
     atomic(path.join(history,'change.json'),{path:args.path,previousSha256:before?hash(before):null,sha256:hash(b),owner,taskId,requestId});
     return {path:args.path,bytes:b.length,sha256:hash(b),sheets:names.length,blank:true,verified:true};
   }finally{if(fs.existsSync(tmp))fs.unlinkSync(tmp);}
 }
 if(tool==='coding.files.list')return pageFiles(root,args,owner);
 if(tool==='coding.files.glob'){
   if(typeof args.pattern!=='string')throw Error('文件匹配模式无效。');const escaped=args.pattern.replace(/[.+^${}()|[\]\\]/g,'\\$&').replaceAll('**/','\u0002').replaceAll('**','\u0001').replaceAll('*','[^/]*').replaceAll('?','[^/]').replaceAll('\u0001','.*').replaceAll('\u0002','(?:.*/)?');const re=new RegExp('^'+escaped+'$');return pageFiles(root,args,owner,f=>re.test(f.path));
 }
 if(tool==='coding.files.image'){
   const file=resolveFile(root,args.path),b=fs.readFileSync(file);if(!b.length)throw Error('图像内容为空。');let mime;
   if(b.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))mime='image/png';else if(b[0]===255&&b[1]===216)mime='image/jpeg';else if(b.toString('ascii',0,4)==='RIFF'&&b.toString('ascii',8,12)==='WEBP')mime='image/webp';else throw Error('不是支持的真实图像文件。');return {path:args.path,image:`data:${mime};base64,${b.toString('base64')}`,sha256:hash(b),requiresVisionModel:true};
 }
 if(tool==='coding.files.read'){
   const file=resolveFile(root,args.path),sha256=hashFile(file);rememberFile(owner,file,sha256);
   return {path:args.path,sha256,...range(file,args.offset??0,args.length??48000,args.encoding??'utf8')};
 }
 if(tool==='coding.files.search'){
   if(typeof args.query!=='string'||!args.query)throw Error('缺少搜索内容。');
   const options={relative:args.path||'.',includeDependencies:args.includeDependencies!==false};
   return queries.execute(args,owner,hash(JSON.stringify({root,options,query:args.query})),async emit=>{
     let processed=0;for(const f of walkFiles(root,resolveFile,options)){if(manager.cancelled.has(scopeKey(ctx)))throw Error('搜索已停止，已有文件保持。');if(++processed%32===0)await new Promise(resolve=>setImmediate(resolve));if(f.type!=='file')continue;const file=resolveFile(root,f.path);
       const first=range(file,0,8192,'base64');if(Buffer.from(first.data,'base64').includes(0)&&args.includeBinary!==true)continue;
       let line=0;for await(const text of readLines(file)){line++;if(text.includes(args.query))emit({path:f.path,line,text});}
     }
   });
 }
 if(tool==='coding.files.write'||tool==='coding.files.edit'){
   const file=writable(root,args,owner),before=fs.existsSync(file)?hashFile(file):null;let content=args.content;
   if(tool==='coding.files.edit'){
     if(!before||typeof args.oldText!=='string'||!args.oldText||typeof args.newText!=='string')throw Error('编辑需要原文件和明确替换内容。');
     const text=fs.readFileSync(file,'utf8');if(text.split(args.oldText).length!==2)throw Error('替换片段不存在或不唯一。');content=text.replace(args.oldText,args.newText);
   }
   if(typeof content!=='string'&&typeof args.contentId!=='string')throw Error('缺少文本或封存内容引用。');
   const history=path.join(base,'changes',p.id,hash(args.path));fs.mkdirSync(history,{recursive:true});if(before)fs.copyFileSync(file,path.join(history,'previous.txt'));else fs.writeFileSync(path.join(history,'previous.txt'),'');
   fs.mkdirSync(path.dirname(file),{recursive:true});const tmp=file+'.'+id()+'.tmp';
   const controller=new AbortController(),scoped=ioOperations.get(scopeKey(ctx))??new Set();ioOperations.set(scopeKey(ctx),scoped);scoped.add(controller);
   try{if(args.contentId)await pipeline(fs.createReadStream(contents.file(args.contentId,owner)),fs.createWriteStream(tmp),{signal:controller.signal});else fs.writeFileSync(tmp,content);
     if(manager.cancelled.has(scopeKey(ctx)))throw Error('本次写入已停止。');
     const sha256=hashFile(tmp);if(before){if(!fs.existsSync(file)||hashFile(file)!==before)throw Error('写入前外部文件发生变化，原文件保持。');fs.renameSync(tmp,file);}else{fs.copyFileSync(tmp,file,fs.constants.COPYFILE_EXCL);fs.unlinkSync(tmp);}
     if(hashFile(file)!==sha256)throw Error('写入后内容核对失败。');rememberFile(owner,file,sha256);
     atomic(path.join(history,'change.json'),{path:args.path,previousSha256:before,sha256,owner,taskId,requestId});
     return {path:args.path,bytes:fs.statSync(file).size,sha256,previousSha256:before,verified:true};
   }finally{scoped.delete(controller);if(fs.existsSync(tmp))fs.unlinkSync(tmp);}
 }
 if(tool==='coding.files.patch'){
   // Deliberately narrow, hash-guarded unified patch. No shell interpolation.
   const file=writable(root,args,owner);if(args.contentId)args.patch=fs.readFileSync(contents.file(args.contentId,owner),'utf8');if(typeof args.patch!=='string')throw Error('补丁无效。');
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
   const output=path.join(history,'diff.txt');fs.writeFileSync(output,diff);const page=range(output,args.offset??0,args.length??48000);return {available:true,path:args.path,previousSha256:change.previousSha256,currentSha256:hashFile(file),...page,diff:page.text};
 }
 if(tool==='coding.exec.start'){
   const cwd=resolveFile(root,args.cwd||'.');if(!fs.statSync(cwd).isDirectory())throw Error('工作目录无效。');return manager.start(args,ctx,cwd);
 }
 if(tool==='coding.deliver.prepare'){
   let requested=args.files;
   if(args.filesContentId){requested=(async function*(){const input=fs.createReadStream(contents.file(args.filesContentId,owner)),lines=readline.createInterface({input,crlfDelay:Infinity});try{for await(const line of lines){if(line.trim())yield JSON.parse(line);}}finally{lines.close();input.destroy();}})();}
   else if(!Array.isArray(requested)||!requested.length)throw Error('必须提供明确的非空最终成果清单；不能自动扫描目录交付。');
   const seen=new Set(),files=[],failed=[],reference=contents.invoke('create',{},owner);let offset=0,total=0;
   for await(const item of requested){try{if(!item||typeof item.path!=='string'||typeof item.purpose!=='string'||!item.purpose.trim())throw Error('每个成果必须有路径和交付用途。');const file=resolveFile(root,item.path);const s=fs.statSync(file);if(!s.isFile())throw Error('成果不是普通文件。');if(seen.has(file))continue;seen.add(file);const row={projectId:p.id,path:item.path,absolutePath:file,name:path.basename(file),bytes:s.size,sha256:hashFile(file),purpose:item.purpose};const text=JSON.stringify(row)+'\n';const result=contents.invoke('append',{contentId:reference.id,offset,text},owner);offset=result.nextOffset;total++;if(files.length<100)files.push(row);}catch(e){failed.push({path:item?.path,error:e.message});}}
   contents.invoke('finish',{contentId:reference.id},owner);
   return {files,failed,manifestContentId:reference.id,total,taskId,owner,explicitManifest:true,filesIsPage:total>files.length};
 }
 throw Error('未知编程工具。');
}

export async function dispatch(frame){
 const {tool,args={},owner,taskId,requestId}=frame;
 if(typeof owner!=='string'||owner.length>180||typeof taskId!=='string'||taskId.length>160||!safeId(requestId))throw Error('缺少宿主执行身份。');
 const key=hash(owner+'\0'+requestId),receipt=path.join(receiptsDir,key+'.json'),fingerprint=hash(JSON.stringify({tool,args,taskId}));
 const prior=json(receipt,null);if(prior){if(prior.fingerprint!==fingerprint)throw Error('请求标识被用于不同操作。');if(prior.state==='prepared')return {outcome:'unknown',message:'上次操作中断，先检查项目和进程，不自动重放。'};return prior.result;}
 const readOnly=/^coding\.(environment|requests\.read|policy\.read|content\.read|legacy\.(sessions|read)|projects\.(list|open)|files\.(list|read|search|glob|image|diff)|jobs\.(list|read|wait|search))$/.test(tool);
 if(!readOnly)atomic(receipt,{fingerprint,state:'prepared',taskId,tool});
 const ctx={owner,taskId,requestId};let locked=false;
 try{
   if(args.projectId&&/^coding\.(files\.(write|edit|patch)|workbook\.create|deliver\.prepare)$/.test(tool)){
     const affected=tool==='coding.deliver.prepare'?(Array.isArray(args.files)?args.files.map(f=>f.path):['.']):[args.path];
     while(manager.lockedProjects.has(args.projectId)||[...jobs.values()].some(j=>j.projectId===args.projectId&&manager.alive(j)&&affected.some(target=>manager.conflicts(target,j)))){if(manager.cancelled.has(scopeKey(ctx)))throw Error('本次等待已停止。');await new Promise(resolve=>setTimeout(resolve,100));}
     if(manager.cancelled.has(scopeKey(ctx)))throw Error('本次写入已停止。');manager.lockedProjects.add(args.projectId);locked=true;
   }
   const value=await invoke(tool,args,ctx);const result={outcome:'verified',value};if(!readOnly)atomic(receipt,{fingerprint,state:'done',result});return result;
 }catch(e){const result={outcome:manager.cancelled.has(scopeKey(ctx))?'cancelled':'failed',message:String(e.message)};if(!readOnly)atomic(receipt,{fingerprint,state:'done',result});return result;}
 finally{if(locked){manager.lockedProjects.delete(args.projectId);manager.pump();}}
}
if(process.env.SKIVU_EXECUTOR_TEST!=='1'){
 const lines=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
 lines.on('line',line=>{let frame;try{frame=JSON.parse(line);if(frame.frameRef){const ref=resolveFile(path.dirname(base),frame.frameRef);frame=JSON.parse(fs.readFileSync(ref,'utf8'));}}catch{return;}
   const reply=result=>{const raw=JSON.stringify({id:frame.id,...result});if(Buffer.byteLength(raw)<=65536)process.stdout.write(raw+'\n');else{const directory=path.join(path.dirname(base),'cloud-rpc');fs.mkdirSync(directory,{recursive:true});const name='reply-'+frame.id+'.json';fs.writeFileSync(path.join(directory,name),raw);process.stdout.write(JSON.stringify({id:frame.id,replyRef:'cloud-rpc/'+name})+'\n');}};void dispatch(frame).then(reply,e=>reply({outcome:'failed',message:e.message}));
 });
 process.stdout.write(JSON.stringify({ready:true,node:process.version,pid:process.pid})+'\n');
}
