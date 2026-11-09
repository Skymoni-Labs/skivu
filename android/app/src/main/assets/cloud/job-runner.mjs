// SPDX-License-Identifier: GPL-3.0-only
// A job owns its durable pipes and exit receipt independently of the RPC host.
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
const specFile=process.argv[2],spec=JSON.parse(fs.readFileSync(specFile,'utf8'));
const prefix=specFile.replace(/\.spec\.json$/,''),statusFile=prefix+'.status.json',inputDir=prefix+'.input';
fs.mkdirSync(inputDir,{recursive:true});
let storagePaused=false,ending=false;
const atomic=(file,value)=>{const tmp=file+'.tmp';fs.writeFileSync(tmp,JSON.stringify(value));fs.renameSync(tmp,file);};
const status=value=>atomic(statusFile,{...value,updatedAt:Date.now()});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
// A small, job-owned emergency journal reserves real blocks for a disk-full receipt.
const reserve=prefix+'.reserve';try{fs.writeFileSync(reserve,Buffer.alloc(256*1024));}catch{}
const child=spawn('/bin/bash',['-lc',spec.command],{cwd:spec.cwd,detached:true,env:{...process.env,HOME:'/root/skivu-home',PWD:spec.cwd},stdio:['pipe','pipe','pipe']});
const signal=name=>{try{process.kill(-child.pid,name);}catch{}};
let pausedStreams=0;
async function spool(stream,name){const log=prefix+'.'+name,fd=fs.openSync(log,'a');try{
  for await(const chunk of stream){let offset=0;
    while(offset<chunk.length){try{const n=fs.writeSync(fd,chunk,offset,chunk.length-offset);if(n<=0)throw Error('日志写入没有进展');offset+=n;}
      catch(error){if(!['ENOSPC','EDQUOT'].includes(error.code))throw error;
        if(!storagePaused){storagePaused=true;signal('SIGSTOP');}
        pausedStreams++;try{fs.unlinkSync(reserve);}catch{}
        const pending=prefix+'.'+name+'.pending';fs.writeFileSync(pending,chunk.subarray(offset));atomic(pending+'.meta.json',{offset:fs.fstatSync(fd).size,bytes:chunk.length-offset});
        status({state:'paused_storage',reason:'手机存储空间不足；已暂停所属程序，原始输出和待写分块保留。',pendingStream:name});
        while(true){await sleep(1000);try{const stat=fs.statfsSync(path.dirname(log));if(stat.bavail*stat.bsize<chunk.length-offset+65536)continue;const n=fs.writeSync(fd,chunk,offset,chunk.length-offset);offset+=n;if(offset===chunk.length)break;}catch(e){if(!['ENOSPC','EDQUOT'].includes(e.code))throw e;}}
        fs.unlinkSync(pending+'.meta.json');fs.unlinkSync(pending);pausedStreams--;if(!pausedStreams){storagePaused=false;status({state:'running',storageRecovered:true});signal('SIGCONT');}
      }
    }
  }
}finally{fs.closeSync(fd);}}
const output=Promise.all([spool(child.stdout,'stdout'),spool(child.stderr,'stderr')]);
status({state:'running',childPid:child.pid});
// Every stdin chunk has an on-disk identity; a prepared chunk is never replayed.
let reading=false;
const inputs=setInterval(async()=>{if(reading||ending)return;reading=true;try{
  for(const file of fs.readdirSync(inputDir).filter(name=>name.endsWith('.json')).sort()){
    const request=path.join(inputDir,file),ack=request+'.ack';if(fs.existsSync(ack))continue;
    const data=JSON.parse(fs.readFileSync(request,'utf8'));atomic(ack,{state:'prepared'});
    await new Promise((resolve,reject)=>child.stdin.write(data.text,error=>error?reject(error):resolve()));
    if(data.end)child.stdin.end();atomic(ack,{state:'accepted'});
  }
}catch(error){status({state:storagePaused?'paused_storage':'running',inputError:String(error.message)});}finally{reading=false;}},100);
let deadline=null;
if(spec.timeoutMs>0){const end=Date.now()+spec.timeoutMs;const arm=()=>{const left=end-Date.now();if(left>0){deadline=setTimeout(arm,Math.min(left,2147483647));return;}status({state:'stopping',timedOut:true,limitSource:'user'});signal('SIGCONT');signal('SIGTERM');setTimeout(()=>signal('SIGKILL'),1500).unref();};arm();}
const exited=new Promise(resolve=>{child.once('error',error=>resolve({state:'failed',error:String(error.message),exitCode:null}));child.once('close',(exitCode,signal)=>resolve({state:'exited',exitCode,signal}));});
const result=await exited;ending=true;clearInterval(inputs);if(deadline)clearTimeout(deadline);
try{await output;status({...result,finishedAt:Date.now()});}catch(error){status({state:'failed',exitCode:result.exitCode,error:String(error.message),outputComplete:false});}
try{fs.unlinkSync(reserve);}catch{}
