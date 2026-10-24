/* Read-only rendering of the original Skivu appearance preferences. */
(() => {
  let settings=null,assets={},scene={},frame=null;
  const url=value=>typeof value==='string'&&/^data:(image\/(png|jpeg|webp)|font\/ttf);base64,[A-Za-z0-9+/=]+$/.test(value)?`url("${value}")`:'none';
  const color=value=>'#'+(Number(value)&0xffffff).toString(16).padStart(6,'0');
  const font=value=>({sans:'SkivuSharedSans',serif:'SkivuSharedSerif',mono:'SkivuSharedMono',custom:'SkivuSharedCustom'}[value]||'SkivuSharedSans');
  const root=$('#chatPlane'),messagesEl=$('#messages');
  const fonts=document.createElement('style');document.head.append(fonts);
  function alignFrost(){
    frame=null;
    const width=scene.width||root.clientWidth,height=scene.height||root.clientHeight;
    messagesEl.querySelectorAll('.bubble').forEach(bubble=>{
      const box=bubble.getBoundingClientRect();
      if(box.bottom<0||box.top>innerHeight)return;
      bubble.style.setProperty('--frost-size',`${width}px ${height}px`);
      bubble.style.setProperty('--frost-position',`${-box.left-(scene.x||0)}px ${-box.top-(scene.y||0)}px`);
    });
  }
  function schedule(){if(!frame)frame=requestAnimationFrame(alignFrost)}
  function paint(){
    if(!settings)return;
    root.querySelectorAll('.message.user .avatar').forEach(node=>{node.innerHTML=SocialPreview.portrait('self')});
    root.classList.add('shared-chat-appearance');
    document.body.classList.toggle('native-chat-background',settings.background&&SocialPreview.page()==='chat');
    root.dataset.bubbleShape=settings.rounded?settings.bubbleShape:'rectangle';
    root.dataset.bubbleStyle=settings.bubbleStyle;
    root.dataset.replyLayout=settings.assistantBubbleLayout;
    root.classList.toggle('shared-no-avatars',!settings.avatars);
    root.classList.toggle('shared-square-avatars',settings.squareAvatars);
    root.classList.toggle('shared-compact',settings.compact);
    root.classList.toggle('shared-wide',settings.wideChat);
    root.style.setProperty('--shared-font-size',`${16*settings.textScale}px`);
    for(const side of ['user','assistant']){
      root.style.setProperty(`--${side}-fill`,color(settings[side+'Color']));
      root.style.setProperty(`--${side}-alpha`,settings.glass?settings[side+'Opacity']:1);
      root.style.setProperty(`--${side}-text`,color(settings[side+'Text']));
      root.style.setProperty(`--${side}-font`,settings[side+'Font']==='custom'?`SkivuSharedCustom-${side}`:font(settings[side+'Font']));
      root.style.setProperty(`--${side}-frost`,settings.glass?url(assets[side+'Frost']):'none');
      root.style.setProperty(`--${side}-image`,url(assets[side+'Image']));
    }
    schedule();
  }
  window.SharedChatAppearance={
    update(snapshot){
      settings=snapshot.appearance||settings;scene=snapshot.appearanceScene||scene;
      if(snapshot.appearanceAssets&&snapshot.appearanceAssets!==assets){
        assets=snapshot.appearanceAssets;
        fonts.textContent=['user','assistant'].filter(side=>url(assets[side+'Font'])!=='none').map(side=>`@font-face{font-family:SkivuSharedCustom-${side};src:${url(assets[side+'Font'])}}`).join('');
      }
      paint();
    },paint,
  };
  messagesEl.addEventListener('scroll',schedule,{passive:true});
  new ResizeObserver(schedule).observe(root);
  document.fonts.ready.then(schedule);
})();
