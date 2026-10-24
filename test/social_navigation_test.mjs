import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

function setup(mode='wx', page='inbox') {
  const events={}, changes=[];
  const root={addEventListener(name,handler){events[name]=handler},getBoundingClientRect(){return {top:0,right:400,height:800}}};
  let current=page,back=0;
  const context=vm.createContext({window:{getSelection(){return {isCollapsed:true}}}, document:{querySelector(){return null}},
    $(){return root}, Date, SocialPreview:{page(){return current},switchTab(next){current=next;changes.push(next)},back(){back++;current='inbox'}}});
  vm.runInContext(fs.readFileSync(new URL('../legacy/social_ui/social_navigation.js',import.meta.url),'utf8'),context);
  context.window.SocialNavigation.update({mode,selectedId:'test-chat'});
  const target={closest(){return null}};
  const point=(x,y)=>({clientX:x,clientY:y});
  function touch(name,x,y,extra={}) {
    let prevented=false;
    events[name]({target,touches:name==='touchend'?[]:[point(x,y)],changedTouches:[point(x,y)],cancelable:true,preventDefault(){prevented=true},...extra});
    return prevented;
  }
  return {events,changes,touch,context, get page(){return current},get backs(){return back},
    swipe(dx,dy=0,x=200,y=400){touch('touchstart',x,y);touch('touchmove',x+dx*.5,y+dy*.5);touch('touchend',x+dx,y+dy)}};
}

test('horizontal gestures switch one WeChat tab in order without wrapping',()=>{
  const h=setup();h.swipe(-100);h.swipe(-100);h.swipe(-100);h.swipe(-100);h.swipe(100);
  assert.deepEqual(h.changes,['contacts','discover','me','discover']);
});
test('vertical-first and diagonal scrolling never turn into a tab swipe',()=>{
  const h=setup();h.touch('touchstart',250,500);h.touch('touchmove',245,450);h.touch('touchmove',140,300);h.touch('touchend',120,270);
  h.swipe(-70,-100);assert.equal(h.page,'inbox');assert.deepEqual(h.changes,[]);
});
test('a right swipe in a chat returns inside the presenter; left stays in chat',()=>{
  const h=setup('wx','chat');h.swipe(-100);assert.equal(h.backs,0);h.swipe(100);assert.equal(h.backs,1);assert.equal(h.page,'inbox');
});
test('right middle edge is reserved while top/bottom gestures keep tab navigation',()=>{
  const h=setup('wx','contacts');h.swipe(100,0,395,400);assert.deepEqual(h.changes,[]);
  h.swipe(100,0,200,100);assert.equal(h.page,'inbox');
});
test('short, cancelled and multi-touch gestures have no navigation side effects',()=>{
  const h=setup();h.swipe(-40);h.touch('touchstart',200,400);h.events.touchcancel();h.touch('touchend',80,400);
  h.touch('touchstart',200,400,{touches:[{},{}]});h.touch('touchend',80,400);assert.deepEqual(h.changes,[]);
});
test('a role change during a gesture cannot navigate the new conversation',()=>{
  const h=setup();h.touch('touchstart',200,400);h.touch('touchmove',100,400);
  h.context.window.SocialNavigation.update({mode:'wx',selectedId:'another'});h.touch('touchend',80,400);assert.deepEqual(h.changes,[]);
});
test('QQ follows its own tab order and deeper pages do not swipe between roots',()=>{
  const qq=setup('qq');qq.swipe(-100);qq.swipe(-100);assert.deepEqual(qq.changes,['channels','contacts']);
  const deep=setup('wx','moments');deep.swipe(-100);assert.deepEqual(deep.changes,[]);
});
test('editable or nested interaction surfaces retain their own gestures',()=>{
  const h=setup();h.touch('touchstart',200,400,{target:{closest(){return {}}}});h.touch('touchmove',80,400);h.touch('touchend',50,400);
  assert.deepEqual(h.changes,[]);
});
test('the original prototype drawer listener cannot emit host drawer commands',()=>{
  const events={},opened=[];
  const source=fs.readFileSync(new URL('../legacy/social_ui/index.html',import.meta.url),'utf8');
  const start=source.indexOf('let touch=null;');const end=source.indexOf('fitPreview();icons();',start);
  assert.ok(start>0&&end>start);
  const context=vm.createContext({window:{SKIVU_HOSTED:true},$(){return {addEventListener(k,f){events[k]=f}}},setDrawer(side){opened.push(side)}});
  vm.runInContext(source.slice(start,end),context);
  const target={closest(){return null}};
  events.pointerdown({pointerType:'touch',target,clientX:100,clientY:200});events.pointerup({clientX:300,clientY:200});
  assert.deepEqual(opened,[]);
  context.window.SKIVU_HOSTED=false;
  events.pointerdown({pointerType:'touch',target,clientX:100,clientY:200});events.pointerup({clientX:300,clientY:200});
  assert.deepEqual(opened,['left']);
});
