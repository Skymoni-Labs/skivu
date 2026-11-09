Skivu.on('companion.invoke',async ({tool,arguments:args})=>{
 try {
  const request=JSON.parse(args.request);
  if(!request||typeof request.op!=='string')throw Error('需要明确的 op');
  const value=await Skivu.call('lab.call',{request});
  await Skivu.call('runtime.complete',{result:value});
 } catch(e) { await Skivu.call('runtime.complete',{result:{ok:false,outcome:e.code==='UNKNOWN'?'unknown':'failed',code:e.code??'FAILED',error:e.message}}); }
});
Skivu.call('runtime.ready',{});
