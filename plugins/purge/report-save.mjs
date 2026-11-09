export async function saveReport(sdk,text,label){
 const safe=String(label||'report').replace(/[<>:"/\\|?*\x00-\x1f]/g,'_').slice(0,100);
 const bytes=new TextEncoder().encode(String(text));let binary='';
 for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
 const saved=await sdk.call('files.save',{name:'report-'+safe+'.md',mime:'text/markdown',base64:btoa(binary)});
 if(saved!==true)throw Error('保存已取消，原资料保留。');
 return true;
}
