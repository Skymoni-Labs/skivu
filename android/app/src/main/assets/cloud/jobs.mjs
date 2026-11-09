// SPDX-License-Identifier: GPL-3.0-only
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import {spawn} from 'node:child_process';
import {range,rangeFiles,logSources,readLogLines,ContentStore,QueryStore} from './streaming.mjs';
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
export class Jobs {
  constructor(base){this.base=path.join(base,'jobs');fs.mkdirSync(this.base,{recursive:true});this.items=new Map();this.cancelled=new Set();this.lockedProjects=new Set();this.policyFile=path.join(base,'execution-policy.json');try{this.boot=fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim();}catch{this.boot=null;}this.queries=new QueryStore(base,new ContentStore(base));
    this.controlDirectory=path.join(base,'task-controls');fs.mkdirSync(this.controlDirectory,{recursive:true});for(const name of fs.readdirSync(this.controlDirectory).filter(name=>name.endsWith('.json'))){try{const record=JSON.parse(fs.readFileSync(path.join(this.controlDirectory,name),'utf8'));if(record.state==='stopped')this.cancelled.add(record.owner+':'+record.taskId);}catch{}}
    for(const name of fs.readdirSync(this.base).filter(name=>name.endsWith('.json')&&!name.endsWith('.status.json')&&!name.endsWith('.spec.json'))){try{const job=JSON.parse(fs.readFileSync(path.join(this.base,name),'utf8'));if(job.id)this.items.set(job.id,job);}catch{}}
    this.timer=setInterval(()=>this.pump(),300);this.timer.unref();this.pump();
  }
  file(j,suffix='json'){return path.join(this.base,j.id+'.'+suffix);}
  save(j){const tmp=this.file(j,'tmp');fs.writeFileSync(tmp,JSON.stringify(j));fs.renameSync(tmp,this.file(j));}
  ticks(pid){try{const s=fs.readFileSync(`/proc/${pid}/stat`,'utf8');const fields=s.slice(s.lastIndexOf(')')+2).split(' ');return fields[0]==='Z'?null:fields[19];}catch{return null;}}
  members(j){if(j.boot!==this.boot||!j.killToken)return [];const result=[];for(const name of fs.readdirSync('/proc')){if(!/^\d+$/.test(name))continue;try{if(fs.readFileSync(`/proc/${name}/environ`).includes(Buffer.from('SKIVU_CLOUD_JOB='+j.killToken+'\0'))){const ticks=this.ticks(name);if(ticks)result.push({pid:Number(name),ticks});};}catch{}}return result;}
  alive(j){return j.boot===this.boot&&(this.boot&&j.startTicks&&j.startTicks===this.ticks(j.pid)||this.members(j).length>0);}
  refresh(j){if(fs.existsSync(this.file(j,'status.json'))){const status=JSON.parse(fs.readFileSync(this.file(j,'status.json'),'utf8'));if(status.state==='exited'&&this.members(j).some(m=>m.pid!==j.pid)){j.detachedChildrenObserved=true;}else if(j.state!=='stopped'&&!(j.state==='paused'&&status.state==='running')&&!(j.state==='stopping_output'&&['paused_storage','running'].includes(status.state)))Object.assign(j,status);}
    if(['running','starting','stopping','paused','paused_storage'].includes(j.state)&&!this.alive(j)){if(!fs.existsSync(this.file(j,'status.json'))||!['exited','failed'].includes(JSON.parse(fs.readFileSync(this.file(j,'status.json'),'utf8')).state)){j.state='unknown';j.reason='原进程不在，保留输出、文件及检查点；先核对，不自动重放。';this.save(j);}}
    return j;
  }
  policy(){let value={};try{value=JSON.parse(fs.readFileSync(this.policyFile,'utf8'));}catch{}const parallel=Number(value.maxParallelJobs??0);return {mode:'unrestricted',maxParallelJobs:parallel,automaticParallelJobs:Math.max(1,Math.min(os.availableParallelism?.()??os.cpus().length,Math.floor(os.freemem()/(64*1024*1024))||1)),timeoutMs:0,outputRetention:'complete',source:parallel>0?'user':'device_resources'};}
  conflicts(target,j){if(j.readOnly)return false;const paths=j.writePaths??['.'];return paths.some(source=>source==='.'||target==='.'||source===target||target.startsWith(source.replace(/\/$/,'')+'/')||source.startsWith(target.replace(/\/$/,'')+'/'));}
  configure(args){if(args.maxParallelJobs!==undefined&&(!Number.isSafeInteger(args.maxParallelJobs)||args.maxParallelJobs<0))throw Error('并发配置无效，0跟随设备资源。');fs.writeFileSync(this.policyFile,JSON.stringify({maxParallelJobs:args.maxParallelJobs??0}));this.pump();return this.policy();}
  pump(){if(this.pumping)return;this.pumping=true;try{for(const job of this.items.values())this.refresh(job);const policy=this.policy();let active=[...this.items.values()].filter(j=>this.alive(j));
    for(const job of this.items.values()){if(job.state!=='queued')continue;if(this.cancelled.has(job.owner+':'+job.taskId)){job.state='stopped';this.save(job);continue;}if(this.lockedProjects.has(job.projectId))continue;
      if(active.length>=(policy.maxParallelJobs||policy.automaticParallelJobs))break;
      if(active.some(other=>other.projectId===job.projectId&&(job.writePaths??(job.readOnly?[]:['.'])).some(target=>this.conflicts(target,other))))continue;
      try{const spec=this.file(job,'spec.json');fs.writeFileSync(spec,JSON.stringify(job));const runner=spawn(process.execPath,[new URL('./job-runner.mjs',import.meta.url).pathname,spec],{cwd:job.cwd,detached:true,env:{...process.env,SKIVU_TASK_ID:job.taskId,SKIVU_CLOUD_JOB:job.killToken},stdio:'ignore'});runner.unref();job.pid=runner.pid;job.startTicks=this.ticks(runner.pid);job.state='running';this.save(job);active.push(job);runner.on('error',error=>{job.state=['EAGAIN','ENOMEM'].includes(error.code)?'queued':'failed';job.error=String(error.message);this.save(job);});}
      catch(error){job.error=String(error.message);if(!['EAGAIN','ENOMEM','ENOSPC','EDQUOT'].includes(error.code))job.state='failed';this.save(job);}
    }
  }finally{this.pumping=false;}}
  own(args,owner){const j=this.items.get(args.jobId);if(!j||j.owner!==owner)throw Error('进程不存在或不属于本会话。');return this.refresh(j);}
  read(j,args={}){this.refresh(j);const streams={};for(const stream of ['stdout','stderr']){const file=this.file(j,stream);streams[stream]=rangeFiles(logSources(file),args[stream+'Offset']??0,args.length??48000);streams[stream].offset=streams[stream].nextOffset;streams[stream].hasMore=!streams[stream].complete;}
    const {killToken,...record}=j;let progress;try{if(j.progressFile)progress=JSON.parse(fs.readFileSync(j.progressFile,'utf8'));}catch{}return {...record,...streams,progress,stdoutBytes:streams.stdout.bytes,stderrBytes:streams.stderr.bytes,inputAvailable:!!j.runnerInput&&['running','paused_storage','paused'].includes(j.state)&&!!this.ticks(j.pid),outputTruncated:j.outputTruncated===true,outputComplete:j.outputComplete!==false&&j.outputTruncated!==true&&!['running','queued','starting','stopping','stopping_output','paused_queue','paused','paused_storage','unknown'].includes(j.state)};
  }
  async start(args,ctx,cwd){if(typeof args.command!=='string'||!args.command.trim())throw Error('缺少命令。');const timeoutMs=args.timeoutMs??0;if(!Number.isSafeInteger(timeoutMs)||timeoutMs<0)throw Error('运行时长无效，0表示不设置超时。');
    if(args.writePaths!==undefined&&(!Array.isArray(args.writePaths)||args.writePaths.some(p=>typeof p!=='string'||path.isAbsolute(p)||p.split('/').includes('..'))))throw Error('写入范围需要项目内相对路径。');
    const job={id:'job_'+crypto.randomUUID().replaceAll('-',''),...ctx,projectId:args.projectId,cwd,command:args.command,readOnly:args.readOnly===true,writePaths:args.writePaths,timeoutMs,killToken:crypto.randomUUID(),state:'queued',createdAt:Date.now(),boot:this.boot,runnerInput:true};this.items.set(job.id,job);this.save(job);this.pump();await sleep(Math.min(500,Math.max(0,args.waitMs??150)));return this.read(job);
  }
  signal(j,name){for(const member of this.members(j)){if(member.ticks&&this.ticks(member.pid)===member.ticks)try{process.kill(member.pid,name);}catch(error){if(error.code!=='ESRCH')throw error;}}}
  async stop(j){this.refresh(j);if(['queued','paused_queue'].includes(j.state)){j.state='stopped';this.save(j);return this.read(j);}if(!this.alive(j))return this.read(j);j.state='stopping';j.stopRequested=true;this.save(j);
    // Keep the pipe-owning runner alive while descendants terminate and its
    // readers drain. Killing it first can lose already-produced output.
    const children=name=>{for(const member of this.members(j)){if(member.pid!==j.pid&&member.ticks===this.ticks(member.pid))try{process.kill(member.pid,name);}catch(error){if(error.code!=='ESRCH')throw error;}}};
    children('SIGCONT');children('SIGTERM');
    for(let i=0;i<15&&this.members(j).some(m=>m.pid!==j.pid);i++)await sleep(100);
    children('SIGKILL');for(let i=0;i<20&&this.alive(j);i++)await sleep(100);
    if(this.alive(j)&&fs.existsSync(this.file(j,'status.json'))&&JSON.parse(fs.readFileSync(this.file(j,'status.json'),'utf8')).state==='paused_storage'){j.state='stopping_output';j.reason='业务进程已停止，原始输出等待可用存储空间后继续落盘。';this.save(j);return this.read(j);}
    if(this.alive(j)){this.signal(j,'SIGCONT');this.signal(j,'SIGTERM');for(let i=0;i<10&&this.alive(j);i++)await sleep(100);}
    if(this.alive(j))this.signal(j,'SIGKILL');
    j.state=this.alive(j)?'unknown':'stopped';this.save(j);this.pump();return this.read(j);
  }
  async control(j,pause){this.refresh(j);if(pause&&j.state==='queued'){j.state='paused_queue';this.save(j);return;}if(!pause&&j.state==='paused_queue'){j.state='queued';this.save(j);return;}if(!this.alive(j))return;
    this.signal(j,pause?'SIGSTOP':'SIGCONT');let confirmed=false;
    for(let i=0;i<20;i++){const members=this.members(j);confirmed=members.length>0&&members.every(m=>{try{const state=fs.readFileSync(`/proc/${m.pid}/stat`,'utf8').split(') ').at(-1)[0];return pause?state==='T'||state==='t':state!=='T'&&state!=='t';}catch{return true;}});if(confirmed)break;await sleep(50);}
    j.state=confirmed?(pause?'paused':'running'):'unknown';if(!confirmed)j.reason='尚未确认原进程的暂停/继续状态。';this.save(j);
  }
  async input(j,args,requestId){if(!j.runnerInput||!this.alive(j)||typeof args.text!=='string')throw Error('该任务没有可用的持久输入通道。');const directory=this.file(j,'input');fs.mkdirSync(directory,{recursive:true});let sequence=j.inputSequence??0;const key=crypto.createHash('sha256').update(requestId).digest('hex'),previous=fs.readdirSync(directory).find(name=>name.endsWith(key+'.json'));const request=path.join(directory,previous??String(++sequence).padStart(20,'0')+'-'+key+'.json');if(!previous){j.inputSequence=sequence;this.save(j);}if(!fs.existsSync(request)){const tmp=request+'.tmp';fs.writeFileSync(tmp,JSON.stringify({text:args.text,end:args.end===true}));fs.renameSync(tmp,request);}
    while(this.alive(j)){if(fs.existsSync(request+'.ack')){const ack=JSON.parse(fs.readFileSync(request+'.ack','utf8'));if(ack.state==='accepted')return {jobId:j.id,inputAccepted:true,state:j.state};if(ack.state==='failed')throw Error('输入未能确认，先核对程序输出。');}await sleep(100);}if(fs.existsSync(request+'.ack')&&JSON.parse(fs.readFileSync(request+'.ack','utf8')).state==='accepted')return {jobId:j.id,inputAccepted:true,state:this.refresh(j).state};throw Error('输入回执中断，先读取原任务，不重复输入。');
  }
  async invoke(tool,args,ctx){if(tool==='policy.read')return this.policy();if(tool==='policy.configure')return this.configure(args);if(tool==='jobs.list')return [...this.items.values()].filter(j=>j.owner===ctx.owner).map(j=>this.read(j));
    if(tool==='pause'||tool==='resume'){const selected=[...this.items.values()].filter(j=>j.owner===ctx.owner&&j.taskId===ctx.taskId);for(const j of selected)await this.control(j,tool==='pause');this.pump();return {state:selected.some(j=>j.state==='unknown')?'unknown':tool==='pause'?'paused':'running',jobs:selected.map(j=>this.read(j))};}
    if(tool==='cancel'){this.cancelled.add(ctx.owner+':'+ctx.taskId);const file=path.join(this.controlDirectory,crypto.createHash('sha256').update(ctx.owner+':'+ctx.taskId).digest('hex')+'.json');let durable=fs.existsSync(file)&&JSON.parse(fs.readFileSync(file,'utf8')).state==='stopped';if(!durable){const temp=file+'.'+crypto.randomUUID()+'.tmp',write=()=>{fs.writeFileSync(temp,JSON.stringify({owner:ctx.owner,taskId:ctx.taskId,state:'stopped'}));fs.renameSync(temp,file);};try{write();durable=true;}catch{try{fs.unlinkSync(path.join(path.dirname(this.base),'emergency.reserve'));}catch{}try{write();durable=true;}catch{}}}
    const jobs=await Promise.all([...this.items.values()].filter(j=>j.owner===ctx.owner&&j.taskId===ctx.taskId&&['queued','paused_queue','running','stopping','stopping_output','paused','paused_storage'].includes(this.refresh(j).state)).map(j=>this.stop(j)));return {stopped:durable&&jobs.every(j=>j.state==='stopped'||j.state==='exited'),durableStop:durable,jobs};}
    const j=this.own(args,ctx.owner);if(tool==='jobs.stop')return this.stop(j);if(tool==='jobs.input')return this.input(j,args,ctx.requestId);
    if(tool==='jobs.pause'||tool==='jobs.resume'){await this.control(j,tool==='jobs.pause');this.pump();return this.read(j);}
    if(tool==='jobs.wait'){while(['running','queued','starting'].includes(this.refresh(j).state))await sleep(300);return this.read(j,args);}
    if(tool==='jobs.read'){const end=Date.now()+Math.min(10000,Math.max(0,args.waitMs??0));while(Date.now()<end&&['running','queued','starting'].includes(this.refresh(j).state))await sleep(100);return this.read(j,args);}
    if(tool==='jobs.search'){if(typeof args.query!=='string'||!args.query)throw Error('缺少日志检索内容。');return this.queries.execute(args,ctx.owner,'job:'+j.id+':'+args.query,async emit=>{for(const stream of ['stdout','stderr']){const file=this.file(j,stream);let line=0;for await(const text of readLogLines(logSources(file))){line++;if(text.includes(args.query))emit({stream,line,text});}}});}
    throw Error('进程操作不存在。');
  }
}
