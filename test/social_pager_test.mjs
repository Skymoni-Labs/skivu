import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

function setup(page='inbox', reduce=false) {
  const events={}, timers=new Map(), changes=[];
  let current=page, nextTimer=0;
  function element(name='') {
    return {name,hidden:false,inert:false,scrollTop:0,style:{visibility:''},children:[],attrs:{id:name},events:{},
      classList:{add(){}},setAttribute(k,v){this.attrs[k]=v},removeAttribute(k){delete this.attrs[k]},
      querySelectorAll(){return []},cloneNode(){const n=element(this.name);n.scrollTop=this.scrollTop;return n},
      append(n){this.children.push(n);n.parent=this},remove(){if(this.parent)this.parent.children=this.parent.children.filter(n=>n!==this)},
      getBoundingClientRect(){return {left:0,top:0,right:400,width:400,height:700}},
      addEventListener(k,f){this.events[k]=f},contains(){return true}};
  }
  const root=element('chatPlane'), surface=element('socialPage');
  root.getBoundingClientRect=()=>({left:0,top:0,right:400,width:400,height:800});
  root.addEventListener=(name,handler)=>{events[name]=handler};
  const window={getSelection:()=>({isCollapsed:true}),matchMedia:()=>({matches:reduce}),
    getComputedStyle:()=>({paddingTop:'52px'}),addEventListener(name,f){events[name]=f}};
  const context=vm.createContext({window,document:{querySelector(){return null},createElement(){return element()}},
    $(selector){return selector==='#socialPage'?surface:root},Date,
    setTimeout(f){timers.set(++nextTimer,f);return nextTimer},clearTimeout(id){timers.delete(id)},
    SocialPreview:{page:()=>current,previewTab:target=>'<button id="preview">'+target+'</button>',
      switchTab(target,options){assert.equal(options.animate,false);current=target;surface.scrollTop=0;changes.push(target)}}});
  vm.runInContext(fs.readFileSync(new URL('../legacy/social_ui/social_navigation.js',import.meta.url),'utf8'),context);
  window.SocialNavigation.update({mode:'wx',selectedId:'chat'});
  const point=(x,y)=>({clientX:x,clientY:y});
  const target={closest(){return null}};
  function touch(name,x,y,extra={}) {
    events[name]({target,touches:name==='touchend'?[]:[point(x,y)],changedTouches:[point(x,y)],
      cancelable:true,preventDefault(){},...extra});
  }
  return {events,window,root,surface,changes,touch,get page(){return current},get deck(){return root.children[0]},
    finish(){for(const [id,f] of [...timers]){timers.delete(id);f()}},
    drag(dx){touch('touchstart',200,100);touch('touchmove',200+dx,100)},
    end(dx){touch('touchend',200+dx,100)}};
}

test('cards follow the finger before release; the live page commits only after settling',()=>{
  const h=setup();h.surface.scrollTop=120;h.drag(-100);
  assert.equal(h.page,'inbox');assert.equal(h.surface.style.visibility,'hidden');
  assert.match(h.deck.children[0].style.transform,/translate3d\(-100px/);
  assert.match(h.deck.children[1].style.transform,/translate3d\(312px/);
  assert.equal(h.deck.children[0].scrollTop,120);
  assert.equal(h.deck.inert,true);assert.equal(h.deck.children[1].attrs['aria-hidden'],'true');
  h.end(-100);assert.equal(h.page,'inbox');h.finish();
  assert.equal(h.page,'contacts');assert.equal(h.root.children.length,0);assert.equal(h.surface.style.visibility,'');
});
test('short swipes and first/last boundary pulls settle back without navigation',()=>{
  for(const [page,dx] of [['inbox',-40],['inbox',160],['me',-160]]) {
    const h=setup(page);h.drag(dx);
    if(page!=='inbox'||dx>0)assert.match(h.deck.children[0].style.transform,/translate3d\(-?28px/);
    h.end(dx);h.finish();assert.equal(h.page,page);assert.deepEqual(h.changes,[]);
    let stopped=false;
    assert.equal(h.window.SocialNavigation.consumeClick({target:{},preventDefault(){},stopImmediatePropagation(){stopped=true}}),true);
    assert.equal(stopped,true);
  }
});
test('vertical scroll never creates a card deck',()=>{
  const h=setup();h.touch('touchstart',200,200);h.touch('touchmove',190,140);h.touch('touchmove',80,100);h.touch('touchend',60,80);
  assert.equal(h.deck,undefined);assert.equal(h.page,'inbox');
});
test('drag reversal previews the correct neighbor and each page restores its own scroll',()=>{
  const h=setup('contacts');h.surface.scrollTop=235;h.drag(-130);h.touch('touchmove',330,100);h.end(130);h.finish();
  assert.equal(h.page,'inbox');
  h.surface.scrollTop=17;h.window.SocialNavigation.navigate('contacts');h.finish();
  assert.equal(h.surface.scrollTop,235);
  h.window.SocialNavigation.navigate('inbox');h.finish();assert.equal(h.surface.scrollTop,17);
});
test('clicking navigation animates and repeated clicks queue only the latest destination',()=>{
  const h=setup();assert.equal(h.window.SocialNavigation.navigate('contacts'),true);
  assert.equal(h.page,'inbox');assert.match(h.deck.children[0].style.transform,/translate3d\(-412px/);
  h.window.SocialNavigation.navigate('discover');h.window.SocialNavigation.navigate('me');
  h.finish();assert.equal(h.page,'contacts');h.finish();assert.equal(h.page,'me');
  assert.deepEqual(h.changes,['contacts','me']);
});
test('ordinary snapshots preserve dragging, role changes discard pending transitions',()=>{
  const h=setup();h.drag(-130);
  h.window.SocialNavigation.update({mode:'wx',selectedId:'chat',unread:3});assert.ok(h.deck);
  h.end(-130);h.window.SocialNavigation.update({mode:'wx',selectedId:'different'});h.finish();
  assert.equal(h.page,'inbox');assert.equal(h.deck,undefined);assert.equal(h.surface.style.visibility,'');
});
test('cancel, second finger, resize and route changes restore the visible original page',()=>{
  for(const action of ['cancel','multi','resize','route']) {
    const h=setup();h.drag(-150);
    if(action==='cancel')h.events.touchcancel();
    if(action==='multi')h.touch('touchmove',50,100,{touches:[{},{}]});
    if(action==='resize')h.events.resize();
    if(action==='route')assert.equal(h.window.SocialNavigation.navigate('moments'),false);
    h.finish();assert.equal(h.page,'inbox');assert.equal(h.deck,undefined);assert.equal(h.surface.style.visibility,'');
  }
});
test('reduced motion keeps direct drag feedback and commits without a timed animation',()=>{
  const h=setup('inbox',true);h.drag(-130);assert.equal(h.page,'inbox');h.end(-130);assert.equal(h.page,'contacts');assert.equal(h.deck,undefined);
});
test('the earliest host capture consumes dragged clicks before selecting a chat',()=>{
  const source=fs.readFileSync(new URL('../legacy/social_ui/host.js',import.meta.url),'utf8');
  const start=source.indexOf('SkivuHost.captureClick=event=>{');
  const check=source.indexOf('SocialNavigation?.consumeClick(event)',start);
  const node=source.indexOf('const node=',start);
  assert.ok(check>start&&check<node);
});
