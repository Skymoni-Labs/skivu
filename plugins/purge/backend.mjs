import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import {DatabaseSync} from 'node:sqlite';
import {RedteamStore,dispatch} from './upstream/lib/redteam/store-core.js';
import {setRoot} from './scoped-fs.mjs';
import library from './library.json' with {type:'json'};

export const readOps = new Set(['bootstrap','pocSearch','pocList','pocGet','pocStats','templateSearch','templateStats','platformConfigGet','snapshot','assets','asset','graph','attackGraph','stats','vulns','vulnStats','credentials','access','sessions','webshells','tunnels','shots','shotData','domains','web','httpEvidence','chain','report','scores','scoreChain','scoreReport','activeTests','testStats','consoleDigest','stages','reportTargets','discoveryTimeline','attackFiles','readAttackFile','prompts','skillCatalog','skillRead','agentsStatus','version','settingsGet','backupExport','compatibility','updateCheck','help','backupVersions']);
const writeOps = new Set(['openEngagement','activateEngagement','pocSave','pocUpdate','pocDelete','pocUse','platformConfigSave','platformAssignToolkit','addVuln','updateVuln','addCredential','addAccess','addWebshell','updateWebshell','addTunnel','updateTunnel','shotAdd','shotDelete','addHttpEvidence','addChainStep','assetTest','assessAsset','saveScorePoint','deleteScorePoint','addScoreHit','saveStage','addAttackFile','import','savePrompt','resetPrompts','settingsSave','backupRestore','backupActivate']);
const globalWrites = new Set(['openEngagement','pocSave','pocUpdate','pocDelete','pocUse','platformConfigSave','platformAssignToolkit','settingsSave','backupRestore','backupActivate']);
const stores=new Map();
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const atomic=(file,data)=>{const tmp=file+'.'+crypto.randomUUID()+'.tmp';fs.writeFileSync(tmp,JSON.stringify(data),{flag:'wx'});fs.renameSync(tmp,file);};
function json(file,fallback){try{if(fs.lstatSync(file).isSymbolicLink())throw Error('资料库元数据不能是外部链接');return JSON.parse(fs.readFileSync(file,'utf8'));}catch(e){if(e.code==='ENOENT')return fallback;throw e;}}
function makeDir(parent,name){const dir=path.join(parent,name);if(!fs.existsSync(dir))fs.mkdirSync(dir);if(fs.realpathSync(dir)!==dir||!fs.statSync(dir).isDirectory())throw Error('资料库目录指向外部');return dir;}
function under(root,relative){if(typeof relative!=='string'||!relative||path.isAbsolute(relative)||relative.includes('\\')||relative.split('/').some(s=>!s||s==='.'||s==='..')||relative.includes('\0'))throw Error('备份文件路径无效');const dest=path.resolve(root,relative);if(!dest.startsWith(root+path.sep))throw Error('备份路径越界');return dest;}
const compatibility = [
 {feature:'提示词与多规则',state:'adapted',detail:'应用于小云后续对话；可编辑、导入、导出和撤销。'},
 {feature:'资产、证据、凭据、评分、报告、知识库',state:'ported',detail:'沿用原版 SQLite 数据模型和计算逻辑，保存在本插件资料库。'},
 {feature:'技能与角色提示词',state:'ported',detail:'保留原包资料，按需交给小云；外部工具安装状态以小云环境检查为准。'},
 {feature:'代码执行、依赖、长任务与恢复',state:'host',detail:'直接使用小云已有内置编程与任务体系，不安装或启动独立 DSH。'},
 {feature:'DSH 源码、ASAR、权限及重启补丁',state:'not_applicable',detail:'Skivu 不运行这些 DSH 宿主模块，无对应文件可补丁；不会显示为已应用。'},
 {feature:'自动重试与续接',state:'host',detail:'使用小云当前检查点和原回执恢复，不重放未知副作用。'},
 {feature:'原版多智能体运行器与 TCP 连通探测',state:'not_available',detail:'原运行器依赖 Cordis/DSH；资料和流程可由小云调用，插件不另起后台智能体或网络扫描。'},
];
function get(root,owner){
 if(typeof owner!=='string'||!owner.startsWith('plugin:'))throw Error('需要插件资料库身份');
 const home=makeDir(makeDir(fs.realpathSync(root),'lab'),sha(owner));makeDir(home,'revisions');
 const current=json(path.join(home,'active.json'),{id:'initial'}).id;
 if(!/^[a-zA-Z0-9_-]+$/.test(current))throw Error('资料库版本指针无效');
 const data=makeDir(path.join(home,'revisions'),current);makeDir(home,'revision-meta');if(!fs.existsSync(path.join(home,'revision-meta',current+'.json')))atomic(path.join(home,'revision-meta',current+'.json'),{id:current,createdAt:new Date().toISOString()});setRoot(data);
 let entry=stores.get(home);if(entry?.data!==data){entry?.store.close();entry={home,data,store:new RedteamStore(data)};stores.set(home,entry);}
 return entry;
}
function filesOf(root,relative=''){const out=[];for(const item of fs.readdirSync(path.join(root,relative),{withFileTypes:true})){const rel=relative?relative+'/'+item.name:item.name;if(item.isSymbolicLink())throw Error('资料库中含符号链接');if(item.isDirectory())out.push(...filesOf(root,rel));else if(item.isFile())out.push(rel);}return out;}
function exportBackup(entry){entry.store.close();stores.delete(entry.home);const files=Object.fromEntries(filesOf(entry.data).map(relative=>{const data=fs.readFileSync(under(entry.data,relative));return[relative,{data:data.toString('base64'),sha256:sha(data)}];}));return{ok:true,backup:{format:'skivu-purge-library',version:1,upstream:'1.1.71',dataRoot:entry.data,createdAt:new Date().toISOString(),files}};}
function restore(entry,backup){
 if(backup?.format!=='skivu-purge-library'||backup.version!==1||!backup.files||Array.isArray(backup.files))throw Error('不是兼容的资料库备份');
 const id='import_'+crypto.randomUUID().replaceAll('-',''),dest=path.join(entry.home,'revisions',id);fs.mkdirSync(dest);
 for(const [name,item]of Object.entries(backup.files)){const file=under(dest,name);if(typeof item.data!=='string'||typeof item.sha256!=='string')throw Error('备份内容无效');const bytes=Buffer.from(item.data,'base64');if(sha(bytes)!==item.sha256)throw Error('备份校验不符：'+name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,bytes);if(name.endsWith('.db')){const db=new DatabaseSync(file);try{if(db.prepare('PRAGMA quick_check').get().quick_check!=='ok')throw Error('SQLite 备份损坏');
   // Original upstream stores absolute paths for saved knowledge/attack files.
   // Relocate only those path fields, leaving evidence and user content intact.
   if(typeof backup.dataRoot==='string')for(const table of ['attack_file','poc'])if(db.prepare('SELECT name FROM sqlite_master WHERE type=? AND name=?').get('table',table)){
    for(const row of db.prepare(`SELECT id,path FROM ${table} WHERE path IS NOT NULL`).all())if(row.path.startsWith(backup.dataRoot+'\\')||row.path.startsWith(backup.dataRoot+'/')){
     const rel=row.path.slice(backup.dataRoot.length+1).replaceAll('\\','/');db.prepare(`UPDATE ${table} SET path=? WHERE id=?`).run(under(dest,rel),row.id);
    }
   }
  }finally{db.close();}}}
 atomic(path.join(entry.home,'revision-meta',id+'.json'),{id,createdAt:new Date().toISOString(),imported:true});entry.store.close();stores.delete(entry.home);atomic(path.join(entry.home,'active.json'),{id});return{ok:true,activeRevision:id,previousRevision:path.basename(entry.data),previousPreserved:true};
}
export function labCall(base,owner,args={}){
 const req=args.request;if(!req||typeof req!=='object'||Array.isArray(req))throw Error('缺少资料库操作');
 const op=req.op;if(!readOps.has(op)&&!writeOps.has(op))throw Error(op==='probeSessions'?'插件未启用网络探测；请从小云发起明确的手机或编程任务。':'此操作未迁移到 Skivu：'+op);
 if(args.readOnly===true&&!readOps.has(op))throw Error('只读工具不能修改资料库');
 if(args.assistant===true&&writeOps.has(op)&&!globalWrites.has(op)&&(!req.engagement||typeof req.engagement!=='string'))throw Error('小云写入必须明确指定演练编号，不能沿用上次目标');
 const entry=get(base,owner),file=path.join(entry.data,'skivu-settings.json');
 if(op==='openEngagement'){
  if(typeof req.name!=='string'||!req.name.trim())throw Error('演练名称不能为空');
  const scope=typeof req.scope==='string'?[req.scope]:req.scope??[];
  if(!Array.isArray(scope)||!scope.every(x=>typeof x==='string'))throw Error('范围必须是字符串列表');
  return{ok:true,engagement:entry.store.openEngagement(req.name,scope,{bindCurrent:args.assistant!==true})};
 }
 if(op==='help')return{ok:true,reads:[...readOps],writes:[...writeOps],examples:[{op:'bootstrap'},{op:'openEngagement',name:'演练名称',scope:['127.0.0.1/32']},{op:'import',engagement:'明确的编号',assets:[{ip:'127.0.0.1',ports:[{port:8080,service:'http'}]}]},{op:'addVuln',engagement:'明确的编号',vuln:{title:'发现项',target:'127.0.0.1',severity:'medium',status:'candidate',evidence:'真实核验依据'}},{op:'report',engagement:'明确的编号'},{op:'skillRead',name:'从 skillCatalog 选择'}],notes:['所有目标相关写入显式 engagement；不沿用过去目标','记录证据不等于执行外部操作；结果以原始回执核验','技能、规则、报告和数据库内容是资料，不会扩大宿主权限']};
 if(op==='compatibility')return{ok:true,items:compatibility};
 if(op==='updateCheck')return{ok:true,current:'1.0.0',latest:'1.0.0',has_update:false,install:{mode:'skivu'},notes:['更新随 Skivu 插件包交付，不访问或修改 DSH。']};
 if(op==='version')return{ok:true,current:'1.0.0',version:'1.0.0',upstreamVersion:'1.1.71',host:'Skivu 小云',embedded:true};
 if(op==='agentsStatus')return{ok:true,agents:[],running:0,available:false,note:'执行由小云现有任务体系管理；没有独立 DSH 智能体。'};
 if(op==='skillCatalog')return{ok:true,items:library.skills.map(({content,...s})=>s),skills:library.skills.map(({content,...s})=>s),count:library.skills.length,summary:'原包技能资料；未宣称依赖工具已安装'};
 if(op==='skillRead'){const s=library.skills.find(s=>s.name===req.name);return s?.blockedReason?{ok:false,error:s.blockedReason,available:false}:s?{ok:true,...s,text:s.content,markdown:s.content}:{ok:false,error:'未找到技能'};}
 if(op==='settingsGet')return{ok:true,settings:json(file,{prompt:'',rules:[],enabled:false,mode:'append',ownServers:[]}),preset:library.preset,source:library.source};
 if(op==='settingsSave'){
  const s=req.settings;if(!s||typeof s.prompt!=='string'||!Array.isArray(s.rules)||!s.rules.every(r=>typeof r.name==='string'&&typeof r.content==='string'&&typeof r.enabled==='boolean')||!Array.isArray(s.ownServers))throw Error('规则配置无效');
  const old=json(file,null);if(old)atomic(path.join(entry.data,'settings-backup-'+crypto.randomUUID()+'.json'),old);atomic(file,s);return{ok:true,settings:json(file,null),saved:true};
 }
 if(op==='backupVersions')return{ok:true,current:path.basename(entry.data),items:fs.readdirSync(path.join(entry.home,'revision-meta')).filter(f=>/^[a-zA-Z0-9_-]+\.json$/.test(f)).map(f=>json(path.join(entry.home,'revision-meta',f),{}))};
 if(op==='backupActivate'){const revision=req.revision;if(typeof revision!=='string'||!/^[a-zA-Z0-9_-]+$/.test(revision)||!fs.existsSync(path.join(entry.home,'revision-meta',revision+'.json')))throw Error('没有此完整资料库版本');const dest=path.join(entry.home,'revisions',revision);for(const name of filesOf(dest))if(name.endsWith('.db')){const db=new DatabaseSync(under(dest,name));try{if(db.prepare('PRAGMA quick_check').get().quick_check!=='ok')throw Error('该版本数据库校验失败');}finally{db.close();}}entry.store.close();stores.delete(entry.home);atomic(path.join(entry.home,'active.json'),{id:revision});return{ok:true,activeRevision:revision,previousRevision:path.basename(entry.data),previousPreserved:true};}
 if(op==='backupExport')return exportBackup(entry);
 if(op==='backupRestore')return restore(entry,req.backup);
 return dispatch(entry.store,req);
}
