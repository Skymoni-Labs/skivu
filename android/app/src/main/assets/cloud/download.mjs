// SPDX-License-Identifier: GPL-3.0-only
import fs from 'node:fs';
import crypto from 'node:crypto';
import {hashFile} from './streaming.mjs';
const specFile=process.argv[2],s=JSON.parse(fs.readFileSync(specFile,'utf8'));
const atomic=value=>{const temp=s.progress+'.tmp';fs.writeFileSync(temp,JSON.stringify(value));fs.renameSync(temp,s.progress);};
let old={};try{old=JSON.parse(fs.readFileSync(s.progress,'utf8'));}catch{}
let latest=old;
if(old.state==='completed'&&fs.existsSync(s.file)&&hashFile(s.file)===old.sha256){console.log(JSON.stringify({...old,reused:true}));process.exit(0);}
let bytes=fs.existsSync(s.partial)?fs.statSync(s.partial).size:0;
const headers={...(s.headers??{})};if(bytes&&!old.etag&&!old.modified&&!s.sha256){bytes=0;fs.writeFileSync(s.partial,'');}if(bytes){headers.Range=`bytes=${bytes}-`;if(old.etag||old.modified)headers['If-Range']=old.etag||old.modified;}
try {
 const response=await fetch(s.url,{headers});
 if(!response.ok)throw Error(`下载服务返回 HTTP ${response.status}`);
 if(bytes&&response.status!==206){bytes=0;fs.writeFileSync(s.partial,'');}
 const range=/^bytes (\d+)-(\d+)\/(\d+|\*)$/.exec(response.headers.get('content-range')??'');
 if(response.status===206&&(!range||Number(range[1])!==bytes))throw Error('远端续传范围与本地文件不一致；未拼接错误内容。');
 const remaining=response.headers.get('content-length'),total=range&&range[3]!=='*'?Number(range[3]):remaining?bytes+Number(remaining):null;
 if(bytes&&response.status===206&&((old.etag&&response.headers.get('etag')!==old.etag)||(!old.etag&&old.modified&&response.headers.get('last-modified')!==old.modified)))throw Error('远端文件版本变化，未拼接不同内容。');
 const meta={url:s.url,file:s.file,etag:response.headers.get('etag'),modified:response.headers.get('last-modified'),total,state:'downloading'};latest=meta;
 const fd=fs.openSync(s.partial,bytes?'a':'w');let last=0;
 try{for await(const part of response.body){let offset=0;while(offset<part.length){const written=fs.writeSync(fd,part,offset);if(written<=0)throw Error('下载写入没有进展，部分文件已保留。');offset+=written;}bytes+=part.length;if(Date.now()-last>250){atomic({...meta,bytes});last=Date.now();}}fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
 if(total!==null&&bytes!==total)throw Error('网络提前结束，保留已下载部分供续传。');
 const digest=hashFile(s.partial);if(s.sha256&&s.sha256!==digest)throw Error('下载文件 SHA-256 与预期不一致。');
 if(fs.existsSync(s.file)){if(!s.expectedBefore||hashFile(s.file)!==s.expectedBefore)throw Error('目标文件已被外部修改，完整下载留在临时文件，未覆盖。');}
 else if(s.expectedBefore)throw Error('原目标文件已消失，未自动覆盖或重建。');
 fs.renameSync(s.partial,s.file);if(hashFile(s.file)!==digest)throw Error('手机运行目录回读核对失败。');
 const completed={...meta,state:'completed',bytes,sha256:digest,verified:true};atomic(completed);console.log(JSON.stringify(completed));
}catch(error){atomic({...latest,state:'interrupted',bytes:fs.existsSync(s.partial)?fs.statSync(s.partial).size:bytes,error:String(error.message),resumeSupported:true});throw error;}
