// SPDX-License-Identifier: GPL-3.0-only
// Small OOXML/ZIP writer for real final files. No extension renaming or network.
import fs from 'node:fs';
import path from 'node:path';
import {deflateRawSync} from 'node:zlib';
const xml=s=>String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&apos;');
const table=Array.from({length:256},(_,i)=>{let n=i;for(let k=0;k<8;k++)n=(n&1)?0xedb88320^(n>>>1):n>>>1;return n>>>0;});
function crc32(b){let n=0xffffffff;for(const c of b)n=table[(n^c)&255]^(n>>>8);return (n^0xffffffff)>>>0;}
// ZIP64, stored entries, streamed from files. Neither total archive size nor
// the number of entries depends on an in-memory Buffer.concat or ZIP32 fields.
export function writeZip(file,entries){
 fs.mkdirSync(path.dirname(path.resolve(file)),{recursive:true});
 const centralFile=file+'.central.tmp',output=fs.openSync(file,'w'),central=fs.openSync(centralFile,'w');
 let offset=0,centralSize=0,count=0;const seen=new Set();
 const put=(fd,b)=>{let at=0;while(at<b.length)at+=fs.writeSync(fd,b,at,b.length-at);return b.length;};
 try {for(const entry of entries){const {name,data,source}=entry;
   if(typeof name!=='string'||name.startsWith('/')||name.includes('\\')||name.split('/').some(v=>v==='..'||!v)||seen.has(name))throw Error('Unsafe/duplicate ZIP name');seen.add(name);
   const n=Buffer.from(name);if(n.length>65535)throw Error('ZIP format cannot encode this entry name');
   let crc=0xffffffff,size=0;const raw=source?null:Buffer.isBuffer(data)?data:Buffer.from(data);
   const each=callback=>{if(raw){callback(raw);return;}const fd=fs.openSync(source,'r'),buffer=Buffer.alloc(65536);try{let len;while((len=fs.readSync(fd,buffer,0,buffer.length,null))>0)callback(buffer.subarray(0,len));}finally{fs.closeSync(fd);}};
   each(b=>{size+=b.length;for(const value of b)crc=table[(crc^value)&255]^(crc>>>8);});crc=(crc^0xffffffff)>>>0;
   const local=Buffer.alloc(30),extra=Buffer.alloc(20);local.writeUInt32LE(0x04034b50);local.writeUInt16LE(45,4);local.writeUInt16LE(0x800,6);local.writeUInt32LE(crc,14);local.writeUInt32LE(0xffffffff,18);local.writeUInt32LE(0xffffffff,22);local.writeUInt16LE(n.length,26);local.writeUInt16LE(extra.length,28);extra.writeUInt16LE(1);extra.writeUInt16LE(16,2);extra.writeBigUInt64LE(BigInt(size),4);extra.writeBigUInt64LE(BigInt(size),12);
   const c=Buffer.alloc(46),ce=Buffer.alloc(28);c.writeUInt32LE(0x02014b50);c.writeUInt16LE(45,4);c.writeUInt16LE(45,6);c.writeUInt16LE(0x800,8);c.writeUInt32LE(crc,16);c.writeUInt32LE(0xffffffff,20);c.writeUInt32LE(0xffffffff,24);c.writeUInt16LE(n.length,28);c.writeUInt16LE(ce.length,30);c.writeUInt32LE(0xffffffff,42);ce.writeUInt16LE(1);ce.writeUInt16LE(24,2);ce.writeBigUInt64LE(BigInt(size),4);ce.writeBigUInt64LE(BigInt(size),12);ce.writeBigUInt64LE(BigInt(offset),20);
   centralSize+=put(central,c)+put(central,n)+put(central,ce);offset+=put(output,local)+put(output,n)+put(output,extra);each(b=>offset+=put(output,b));count++;
 }
 fs.closeSync(central);const centralOffset=offset,fd=fs.openSync(centralFile,'r'),buffer=Buffer.alloc(65536);try{let len;while((len=fs.readSync(fd,buffer,0,buffer.length,null))>0)offset+=put(output,buffer.subarray(0,len));}finally{fs.closeSync(fd);}
 const end64=Buffer.alloc(56);end64.writeUInt32LE(0x06064b50);end64.writeBigUInt64LE(44n,4);end64.writeUInt16LE(45,12);end64.writeUInt16LE(45,14);end64.writeBigUInt64LE(BigInt(count),24);end64.writeBigUInt64LE(BigInt(count),32);end64.writeBigUInt64LE(BigInt(centralSize),40);end64.writeBigUInt64LE(BigInt(centralOffset),48);put(output,end64);
 const locator=Buffer.alloc(20);locator.writeUInt32LE(0x07064b50);locator.writeBigUInt64LE(BigInt(offset),8);locator.writeUInt32LE(1,16);put(output,locator);
 const end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(0xffff,8);end.writeUInt16LE(0xffff,10);end.writeUInt32LE(0xffffffff,12);end.writeUInt32LE(0xffffffff,16);put(output,end);fs.fsyncSync(output);
 }finally{try{fs.closeSync(central);}catch{}fs.closeSync(output);if(fs.existsSync(centralFile))fs.unlinkSync(centralFile);}
}
const declaration='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const officeRel='http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const pkgRel='http://schemas.openxmlformats.org/package/2006/relationships';
const colName=n=>{let s='';for(n++;n;n=Math.floor((n-1)/26))s=String.fromCharCode(65+(n-1)%26)+s;return s;};
export function writeWorkbook(file,sheets){
 if(!Array.isArray(sheets)||!sheets.length)throw Error('Workbook needs real worksheets');
 const names=new Set();for(const s of sheets){if(typeof s.name!=='string'||!s.name||s.name.length>31||/[\[\]:*?/\\]/.test(s.name)||names.has(s.name))throw Error('Invalid worksheet name');names.add(s.name);if(!Array.isArray(s.rows))throw Error('Missing rows');}
 const formats=[],styles=[{bold:false,format:''}],styleIndex=cell=>{const value={bold:cell.bold===true,format:cell.format||''};let i=styles.findIndex(s=>s.bold===value.bold&&s.format===value.format);if(i<0){i=styles.length;styles.push(value);}if(value.format&&!formats.includes(value.format))formats.push(value.format);return i;};
 const files=[];
 for(let i=0;i<sheets.length;i++){
  const sheet=sheets[i];const rows=sheet.rows.map((row,r)=>{if(!Array.isArray(row))throw Error('Row must be an array');return `<row r="${r+1}">${row.map((raw,c)=>{
   const cell=raw&&typeof raw==='object'?raw:{value:raw};const ref=colName(c)+(r+1),style=styleIndex(cell);const value=cell.value;
   if(cell.formula){if(typeof cell.formula!=='string')throw Error('Invalid formula');return `<c r="${ref}" s="${style}"><f>${xml(cell.formula.replace(/^=/,''))}</f>${typeof value==='number'&&Number.isFinite(value)?`<v>${value}</v>`:''}</c>`;}
   if(typeof value==='number'){if(!Number.isFinite(value))throw Error('Non-finite number');return `<c r="${ref}" s="${style}"><v>${value}</v></c>`;}
   if(typeof value==='boolean')return `<c r="${ref}" s="${style}" t="b"><v>${+value}</v></c>`;
   return `<c r="${ref}" s="${style}" t="inlineStr"><is><t xml:space="preserve">${xml(value)}</t></is></c>`;
  }).join('')}</row>`;}).join('');
  const widths=sheet.widths?.length?`<cols>${sheet.widths.map((width,c)=>`<col min="${c+1}" max="${c+1}" width="${Math.max(1,Number(width)||12)}" customWidth="1"/>`).join('')}</cols>`:'';
  const freeze=sheet.freezeRows?`<sheetViews><sheetView workbookViewId="0"><pane ySplit="${Math.max(1,Math.floor(sheet.freezeRows))}" topLeftCell="A${Math.floor(sheet.freezeRows)+1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>`:'';
  files.push({name:`xl/worksheets/sheet${i+1}.xml`,data:declaration+`<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">${freeze}${widths}<sheetData>${rows}</sheetData></worksheet>`});
 }
 files.push({name:'xl/styles.xml',data:declaration+`<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="${formats.length}">${formats.map((f,i)=>`<numFmt numFmtId="${164+i}" formatCode="${xml(f)}"/>`).join('')}</numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="${styles.length}">${styles.map(s=>`<xf numFmtId="${s.format?164+formats.indexOf(s.format):0}" fontId="${s.bold?1:0}" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>`).join('')}</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`});
 files.push({name:'xl/workbook.xml',data:declaration+`<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="${officeRel}"><sheets>${sheets.map((s,i)=>`<sheet name="${xml(s.name)}" sheetId="${i+1}" r:id="rId${i+1}"/>`).join('')}</sheets><calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>`});
 files.push({name:'xl/_rels/workbook.xml.rels',data:declaration+`<Relationships xmlns="${pkgRel}">${sheets.map((_,i)=>`<Relationship Id="rId${i+1}" Type="${officeRel}/worksheet" Target="worksheets/sheet${i+1}.xml"/>`).join('')}<Relationship Id="rIdStyles" Type="${officeRel}/styles" Target="styles.xml"/></Relationships>`});
 files.push({name:'_rels/.rels',data:declaration+`<Relationships xmlns="${pkgRel}"><Relationship Id="rId1" Type="${officeRel}/officeDocument" Target="xl/workbook.xml"/></Relationships>`});
 files.push({name:'[Content_Types].xml',data:declaration+`<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${sheets.map((_,i)=>`<Override PartName="/xl/worksheets/sheet${i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}</Types>`});
 writeZip(file,files);return {file,worksheets:sheets.length};
}
export function writeDocument(file,paragraphs){
 if(!Array.isArray(paragraphs)||!paragraphs.length)throw Error('Document needs content');
 const body=paragraphs.map(raw=>{const p=typeof raw==='object'?raw:{text:String(raw)};return `<w:p>${p.heading?`<w:pPr><w:pStyle w:val="Heading${Math.min(3,Math.max(1,p.heading))}"/></w:pPr>`:''}<w:r><w:t xml:space="preserve">${xml(p.text)}</w:t></w:r></w:p>`;}).join('');
 writeZip(file,[
 {name:'[Content_Types].xml',data:declaration+'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'},
 {name:'_rels/.rels',data:declaration+`<Relationships xmlns="${pkgRel}"><Relationship Id="rId1" Type="${officeRel}/officeDocument" Target="word/document.xml"/></Relationships>`},
 {name:'word/document.xml',data:declaration+`<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>${body}<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>`},
 ]);return {file,paragraphs:paragraphs.length};
}
export function packageProject(file,root,finalPaths){
 if(!Array.isArray(finalPaths)||!finalPaths.length)throw Error('An explicit project manifest is required');root=fs.realpathSync(root);
 const entries=finalPaths.map(relative=>{if(typeof relative!=='string'||path.isAbsolute(relative)||relative.split('/').includes('..'))throw Error('Unrelated/generated paths are excluded');const source=fs.realpathSync(path.join(root,relative));if(!source.startsWith(root+'/')||!fs.statSync(source).isFile())throw Error('Final project entry is not a file');return {name:relative,source};});
 writeZip(file,entries);return {file,entries:entries.length};
}
