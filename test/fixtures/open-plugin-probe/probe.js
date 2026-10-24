/* GPL-3.0-only. Synthetic local tests: never uses a real model or account. */
const results=[];const show=()=>document.querySelector('#result').textContent=results.join('\n');
async function test(name,task){try{if(!await task())throw Error('assertion');results.push('PASS '+name);}catch(e){results.push('FAIL '+name+' '+(e.code||e.message));}show();}
async function denied(method,params,code){try{await Skivu.call(method,params);return false;}catch(e){return e.code===code;}}
document.querySelector('#run').onclick=async()=>{
  document.querySelector('#run').disabled=true;
  await test('no admin bridge',()=>denied('admin.login',{},'METHOD_NOT_FOUND'));
  await test('no host settings bridge',()=>denied('settings.get',{},'METHOD_NOT_FOUND'));
  await test('host server denied with LAN permission',()=>denied('network.request',{url:'https://skymoni.com/'},'NETWORK_DENIED'));
  await test('cloud metadata denied',()=>denied('network.request',{url:'http://169.254.169.254/latest/meta-data/'},'NETWORK_DENIED'));
  await test('no arbitrary filesystem',()=>denied('fs.read',{path:'../package.json'},'INVALID_ARGUMENT'));
  await test('undeclared chat permission',()=>denied('chat.read',{},'PERMISSION_DENIED'));
  await test('own secret namespace',async()=>{await Skivu.call('secrets.set',{key:'probe',value:'synthetic-only'});return await Skivu.call('secrets.get',{key:'probe'})==='synthetic-only'&&await Skivu.call('secrets.get',{key:'skivu.api.fixture'})===null;});
  await test('six MiB save',async()=>{const value='x'.repeat(6*1024*1024);await Skivu.call('storage.set',{key:'large',value});return (await Skivu.call('storage.get',{key:'large'})).length===value.length;});
  await test('raw fetch blocked',async()=>{try{await fetch('https://example.com/');return false;}catch(_){return true;}});
  await test('raw WebRTC unavailable',async()=>typeof RTCPeerConnection==='undefined');
  await test('owned LAN companion',async()=>{const response=await Skivu.call('network.request',{url:'http://127.0.0.1:8765/probe',headers:{'X-Plugin-Test':'only-own-header'}});const body=JSON.parse(response.body);return response.status===200&&body.probe==='synthetic-companion'&&!body.authorization&&!body.cookie;});
  results.push('DONE '+results.filter(x=>x.startsWith('PASS')).length+'/11');show();
};
