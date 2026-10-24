import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

function host(mode='wx',chats=[]) {
  const events={},emitted=[];
  const document={visibilityState:'visible',addEventListener:(name,fn)=>events[name]=fn};
  let page='inbox';
  const window={SkivuHost:{emit:(command,value)=>emitted.push({command,...value})},SocialPreview:{page:()=>page}};
  vm.runInNewContext(fs.readFileSync(new URL('../legacy/social_ui/social_unread.js',import.meta.url),'utf8'),{window,document,addEventListener:(name,fn)=>events[name]=fn});
  const api=window.SocialUnread;api.update({mode,chats,selectedId:'one'});
  return {api,events,emitted,document,set page(value){page=value}};
}

test('avatar badges and header totals use actual counts and hide at zero',()=>{
  const {api}=host('wx',[{unread:4},{unread:5}]);
  assert.equal(api.total(),9);assert.equal(api.title('微信'),'微信(9)');
  assert.match(api.badge(9),/>9<\/span>/);assert.equal(api.badge(0),'');
  api.update({mode:'wx',chats:[]});assert.equal(api.title('微信'),'微信');
});
test('large counts display 99+ without widening the list or tab',()=>{
  const {api}=host('wx',[{unread:120}]);
  assert.equal(api.title('微信'),'微信(99+)');assert.match(api.badge(120),/>99\+<\/span>/);
});
test('muted chats retain a dot but do not inflate top or bottom totals',()=>{
  const {api}=host('wx',[{unread:3},{unread:9,muted:true}]);
  assert.equal(api.total(),3);assert.match(api.badge(9,true),/is-dot/);assert.doesNotMatch(api.badge(9,true),/>9</);
});
test('QQ channels and messages show separate totals',()=>{
  const {api}=host('qq',[{unread:2},{unread:7,groupKind:'channel'}]);
  assert.equal(api.total(),2);assert.equal(api.total('channels'),7);assert.equal(api.title('消息'),'消息(2)');
});
test('only the visible chat reports reading, including page changes and backgrounding',()=>{
  const h=host();h.api.visibility('inbox');h.api.visibility('chat');h.api.visibility('chat');
  assert.deepEqual(h.emitted.map(e=>e.visible),[false,true]);
  h.page='chat';h.document.visibilityState='hidden';h.events.visibilitychange();
  h.document.visibilityState='visible';h.events.visibilitychange();h.events.pagehide();
  assert.deepEqual(h.emitted.map(e=>e.visible),[false,true,false,true,false]);
});
test('a new selected conversation reports its own visibility and invalid counts are ignored',()=>{
  const h=host();h.api.visibility('chat');h.api.update({mode:'wx',selectedId:'two',chats:[{unread:-3},{unread:NaN},{unread:1.9}]});h.api.visibility('chat');
  assert.equal(h.emitted.length,2);assert.equal(h.api.total(),1);
});
