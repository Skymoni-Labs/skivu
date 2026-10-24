import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

function host(mode='wx') {
  const nodes=new Map(), notices=[], emitted=[], screens=[];
  function node() {return {dataset:{},value:'',innerHTML:'',classList:{toggle(){},remove(){}},setAttribute(){},querySelector(){return null},querySelectorAll(){return []},append(child){screens.push(child)},remove(){}}}
  const get=selector=>{if(!nodes.has(selector))nodes.set(selector,node());return nodes.get(selector)};
  const context=vm.createContext({window:{SKIVU_HOSTED:true},ICONS:{},
    $:get,$$:()=>[],esc:String,icon:String,showSheet(){},measureComposer(){},
    toast:text=>notices.push(text),crypto:{},clearTimeout(){},addEventListener(){},
    document:{addEventListener(){},createElement:node},
    navigator:{mediaDevices:{getUserMedia(){throw Error('Unexpected camera access')},getDisplayMedia(){throw Error('Unexpected screen access')}}},
    SocialPreview:{page:()=> 'inbox',portrait:()=>''},
    SkivuHost:{emit:command=>emitted.push(command)},
  });
  vm.runInContext(fs.readFileSync(new URL('../assets/social_ui/chat_interactions.js',import.meta.url),'utf8'),context);
  const api=context.window.ChatInteractions;
  context.ChatInteractions=api;
  api.update({mode,selectedId:'qa',selectedRoleId:'role',roles:[],messages:[],interactions:[]});
  screens.length=0;
  return {api,notices,emitted,screens};
}

for(const mode of ['wx','qq']) test(mode+' blocks direct and stale video-call actions before media or host calls',()=>{
  const h=host(mode);
  h.api.open('video-call');
  h.api.capture({preventDefault(){},stopImmediatePropagation(){}},{dataset:{interaction:'video-call'}});
  assert.deepEqual(h.notices,['视频通话开发中','视频通话开发中']);
  assert.deepEqual(h.emitted,[]);
  assert.deepEqual(h.screens,[]);
  const menu=h.api.moduleMarkup('calls');
  assert.match(menu,/data-interaction="video-call"[^>]*disabled[^>]*开发中/);
  assert.match(menu,/data-interaction="voice-call"[^>]*aria-label="语音通话"/);
});

test('voice-call screen still offers the native voice engine without a video preview',()=>{
  const h=host();h.api.open('voice-call');
  assert.equal(h.screens.length,1);
  assert.match(h.screens[0].innerHTML,/开始语音通话/);
  assert.doesNotMatch(h.screens[0].innerHTML,/<video|start-camera/);
});
