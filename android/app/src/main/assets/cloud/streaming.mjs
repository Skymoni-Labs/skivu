// SPDX-License-Identifier: GPL-3.0-only
// Page sizes are transport windows, never limits on the source or result set.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import {StringDecoder} from 'node:string_decoder';
export const sha = value => crypto.createHash('sha256').update(value).digest('hex');
export function hashFile(file) {
  const digest=crypto.createHash('sha256'), fd=fs.openSync(file,'r'), buffer=Buffer.alloc(65536);
  try {let n;while((n=fs.readSync(fd,buffer,0,buffer.length,null))>0)digest.update(buffer.subarray(0,n));}
  finally {fs.closeSync(fd);}return digest.digest('hex');
}
export function rangeFiles(files,offset=0,length=48000,encoding='utf8') {
  offset=Number(offset);length=Number(length);
  if(!Number.isSafeInteger(offset)||offset<0||!Number.isSafeInteger(length)||length<1)throw Error('读取范围无效。');
  const sources=files.map(source=>typeof source==='string'?{file:source,start:0}:source).filter(source=>fs.existsSync(source.file)).map(source=>({...source,bytes:Math.max(0,fs.statSync(source.file).size-(source.start??0))})),size=sources.reduce((n,s)=>n+s.bytes,0);
  // Four bytes are the minimum UTF-8 transfer unit. A continuation offset is
  // always a byte offset; sequential pages never split a Unicode scalar.
  const window=Math.min(Math.max(4,length),1024*1024),buffer=Buffer.alloc(Math.min(window+3,Math.max(0,size-offset)));
  let logical=0,n=0;
  for(const source of sources){if(offset+n>=logical+source.bytes){logical+=source.bytes;continue;}const fd=fs.openSync(source.file,'r');try{let at=Math.max(0,offset+n-logical);while(n<buffer.length&&at<source.bytes){const got=fs.readSync(fd,buffer,n,Math.min(buffer.length-n,source.bytes-at),at+(source.start??0));if(!got)break;n+=got;at+=got;}}finally{fs.closeSync(fd);}logical+=source.bytes;if(n===buffer.length)break;}
  let end=Math.min(window,n);
  if(encoding==='utf8'&&offset+end<size){while(end>0&&end<n&&(buffer[end]&0xc0)===0x80)end--;}
  return {text:encoding==='base64'?undefined:buffer.subarray(0,end).toString('utf8'),data:encoding==='base64'?buffer.subarray(0,end).toString('base64'):undefined,offset,nextOffset:offset+end,bytes:size,complete:offset+end>=size,encoding};
}
export function logSources(file){const result=[file];try{const pending=JSON.parse(fs.readFileSync(file+'.pending.meta.json','utf8')),written=fs.existsSync(file)?fs.statSync(file).size:0;if(fs.existsSync(file+'.pending'))result.push({file:file+'.pending',start:Math.max(0,written-pending.offset)});}catch{}return result;}
export function range(file,offset=0,length=48000,encoding='utf8'){return rangeFiles([file],offset,length,encoding);}
export function* walkFiles(root,resolveFile,{relative='.',includeDependencies=true}={}) {
  // Iterative traversal avoids call-stack/depth limits; symlinks stay explicit.
  const stack=[{relative,dir:fs.opendirSync(resolveFile(root,relative))}];
  try {while(stack.length){const current=stack.at(-1),entry=current.dir.readSync();if(!entry){current.dir.closeSync();stack.pop();continue;}
    const name=current.relative==='.'?entry.name:current.relative+'/'+entry.name;
    if(entry.isSymbolicLink()){yield {path:name,type:'symlink'};continue;}
    if(entry.isDirectory()){
      const dependency=['node_modules','.git','.cache','build','dist'].includes(entry.name);
      yield {path:name,type:'directory',dependency};
      if(includeDependencies||!dependency)stack.push({relative:name,dir:fs.opendirSync(resolveFile(root,name))});
    }else if(entry.isFile())yield {path:name,type:'file',bytes:fs.statSync(resolveFile(root,name)).size};
  }}finally{for(const item of stack)try{item.dir.closeSync();}catch{}}
}
// Synchronous bounded reads avoid thousands of per-file worker-thread round
// trips under PRoot. Cooperative yields preserve cancellation and other jobs.
export async function* readLines(file){const fd=fs.openSync(file,'r'),buffer=Buffer.alloc(65536),decoder=new StringDecoder('utf8');let pending='',chunks=0;try{while(true){const n=fs.readSync(fd,buffer,0,buffer.length,null);if(!n)break;pending+=decoder.write(buffer.subarray(0,n));let start=0,index;while((index=pending.indexOf('\n',start))>=0){yield pending.slice(start,index).replace(/\r$/,'');start=index+1;}pending=pending.slice(start);if(++chunks%16===0)await new Promise(resolve=>setImmediate(resolve));}pending+=decoder.end();if(pending)yield pending.replace(/\r$/,'');}finally{fs.closeSync(fd);}}
export async function* readLogLines(sources){const decoder=new StringDecoder('utf8'),buffer=Buffer.alloc(65536);let pending='',chunks=0;for(const source of sources){const file=typeof source==='string'?source:source.file;if(!fs.existsSync(file))continue;const start=typeof source==='string'?0:source.start??0,end=fs.statSync(file).size,fd=fs.openSync(file,'r');try{for(let at=start;at<end;){const n=fs.readSync(fd,buffer,0,Math.min(buffer.length,end-at),at);if(!n)break;at+=n;pending+=decoder.write(buffer.subarray(0,n));let from=0,index;while((index=pending.indexOf('\n',from))>=0){yield pending.slice(from,index).replace(/\r$/,'');from=index+1;}pending=pending.slice(from);if(++chunks%16===0)await new Promise(resolve=>setImmediate(resolve));}}finally{fs.closeSync(fd);}}pending+=decoder.end();if(pending)yield pending.replace(/\r$/,'');}
export class ContentStore {
  constructor(base){this.base=path.join(base,'content');fs.mkdirSync(this.base,{recursive:true});}
  metadata(id,owner){if(typeof id!=='string'||!/^content_[a-f0-9]{32}$/.test(id))throw Error('内容引用无效。');const file=path.join(this.base,id+'.json'),m=JSON.parse(fs.readFileSync(file,'utf8'));if(m.owner!==owner)throw Error('内容不属于本会话。');return {m,file,data:path.join(this.base,id+'.bin')};}
  invoke(tool,args,owner){
    if(tool==='create'){const id='content_'+crypto.randomUUID().replaceAll('-',''),m={id,owner,complete:false,createdAt:Date.now()};fs.writeFileSync(path.join(this.base,id+'.bin'),'');fs.writeFileSync(path.join(this.base,id+'.json'),JSON.stringify(m));return {...m,bytes:0};}
    const {m,file,data}=this.metadata(args.contentId,owner),size=fs.statSync(data).size;
    if(tool==='read')return {...range(data,args.offset??0,args.length??48000,args.encoding??'utf8'),contentId:m.id,sha256:m.complete?m.sha256:undefined};
    if(tool==='append'){
      if(m.complete)throw Error('内容对象已经封存。');
      if(typeof args.text!=='string'&&typeof args.data!=='string')throw Error('缺少文本或base64数据。');
      const chunk=args.data!==undefined?Buffer.from(args.data,'base64'):Buffer.from(args.text),offset=args.offset;
      if(!Number.isSafeInteger(offset)||offset<0||offset>size)throw Error('分块偏移与实际内容不一致。');
      const overlap=Math.min(chunk.length,size-offset);
      if(overlap>0){const fd=fs.openSync(data,'r'),buffer=Buffer.alloc(65536);try{for(let at=0;at<overlap;){const n=fs.readSync(fd,buffer,0,Math.min(buffer.length,overlap-at),offset+at);if(!n||!buffer.subarray(0,n).equals(chunk.subarray(at,at+n)))throw Error('已写入分块内容不同。');at+=n;}}finally{fs.closeSync(fd);}}
      if(overlap<chunk.length)fs.appendFileSync(data,chunk.subarray(overlap));
      return {contentId:m.id,bytes:fs.statSync(data).size,nextOffset:Math.max(size,offset+chunk.length),reused:overlap===chunk.length};
    }
    if(tool==='finish'){const digest=hashFile(data);if(args.bytes!==undefined&&args.bytes!==size||args.sha256!==undefined&&args.sha256!==digest)throw Error('完整性核对未通过。');m.complete=true;m.bytes=size;m.sha256=digest;fs.writeFileSync(file+'.tmp',JSON.stringify(m));fs.renameSync(file+'.tmp',file);return m;}
    throw Error('内容操作无效。');
  }
  file(id,owner){const {m,data}=this.metadata(id,owner);if(!m.complete||hashFile(data)!==m.sha256)throw Error('内容未封存或已变化。');return data;}
}
export class QueryStore {
  constructor(base,contents){this.base=path.join(base,'queries');this.contents=contents;fs.mkdirSync(this.base,{recursive:true});}
  async execute(args,owner,signature,build){
    let metadata,offset=0;
    if(args.cursor){const cursor=JSON.parse(Buffer.from(args.cursor,'base64url').toString('utf8'));if(!/^query_[a-f0-9]{32}$/.test(cursor.id))throw Error('继续读取标识无效。');metadata=JSON.parse(fs.readFileSync(path.join(this.base,cursor.id+'.json'),'utf8'));if(metadata.owner!==owner||metadata.signature!==signature)throw Error('继续读取范围发生变化。');offset=cursor.offset;}
    else {const id='query_'+crypto.randomUUID().replaceAll('-',''),file=path.join(this.base,id+'.jsonl');const fd=fs.openSync(file,'w');let total=0;try {await build(row=>{if(typeof row.text==='string'&&Buffer.byteLength(row.text)>65536){const content=this.contents.invoke('create',{},owner);this.contents.invoke('append',{contentId:content.id,offset:0,text:row.text},owner);const ref=this.contents.invoke('finish',{contentId:content.id},owner);row={...row,text:row.text.slice(0,4096),textComplete:false,textRef:ref.id,textBytes:ref.bytes};}fs.writeSync(fd,JSON.stringify(row)+'\n');total++;});}finally{fs.closeSync(fd);}metadata={id,owner,signature,total,createdAt:Date.now()};fs.writeFileSync(path.join(this.base,id+'.json'),JSON.stringify(metadata));}
    const file=path.join(this.base,metadata.id+'.jsonl'),items=[],stream=fs.createReadStream(file,{start:offset}),lines=readline.createInterface({input:stream,crlfDelay:Infinity});
    const count=Number(args.pageSize??100);if(!Number.isSafeInteger(count)||count<1)throw Error('分页数量无效。');let consumed=0;
    try {for await(const line of lines){consumed+=Buffer.byteLength(line)+1;const row=JSON.parse(line);items.push(row);if(items.length>=Math.min(count,1000))break;}}finally{lines.close();stream.destroy();}
    const next=offset+consumed,complete=next>=fs.statSync(file).size;
    return {items,total:metadata.total,complete,nextCursor:complete?null:Buffer.from(JSON.stringify({id:metadata.id,offset:next})).toString('base64url'),snapshot:metadata.id};
  }
}
