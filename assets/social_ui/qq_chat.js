/* Original chat-only QQ presentation, based on user-authorized visual reference.
 * No QQ assets, account access or device integration. All chat data stays in Skivu.
 */
(() => {
  let snapshot=null,panel=null,panelKind='',context='';
  const root=$('#chatPlane');
  const enabled=()=>window.SKIVU_HOSTED&&snapshot?.mode==='qq';
  const button=(action,label,ico)=>`<button data-qq="${action}" aria-label="${esc(label)}">${icon(ico)}<span>${esc(label)}</span></button>`;
  const pages=[
    [['voice-call','语音通话','phone'],['video-call','视频通话','video'],['location','位置','pin'],['file','文件','folder'],['redpacket','红包','gift'],['transfer','转账','wallet'],['favorites','收藏','star'],['screen','屏幕分享','panel']],
    [['contacts','名片','user'],['gifts','礼物','gift'],['music','一起听歌','music']],
  ];
  ICONS.video='<rect x="3" y="5" width="12" height="14" rx="3"/><path d="m15 9 6-3v12l-6-3"/>';
  ICONS.pin='<path d="M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 1 1 14 0Z"/><circle cx="12" cy="10" r="2.5"/>';
  ICONS.gift='<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M5 12v9h14v-9M12 8v13M12 8H8a3 3 0 1 1 3-3l1 3Zm0 0h4a3 3 0 1 0-3-3l-1 3Z"/>';
  ICONS.music='<path d="M9 18V5l11-2v13M9 8l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2.5"/><ellipse cx="17" cy="16" rx="3" ry="2.5"/>';
  function closePanel(){panel?.remove();panel=null;panelKind='';root.querySelector('[data-tool=attachments]')?.setAttribute('aria-expanded','false');measureComposer()}
  function refreshSend(){
    if(!enabled())return;
    const send=$('#sendButton');send.disabled=!snapshot.streaming&&!$('#messageInput').value.trim();
    send.setAttribute('aria-label',snapshot.streaming?'停止回复':'发送消息');
  }
  function openPanel(kind){
    if(panelKind===kind){closePanel();return}
    closePanel();$('#messageInput').blur();panelKind=kind;
    panel=document.createElement('section');panel.className='qq-chat-panel';panel.setAttribute('aria-label',kind==='emoji'?'表情面板':'更多聊天功能');
    // A horizontal tool-page swipe belongs to this panel, not the host drawers.
    panel.addEventListener('pointerdown',event=>event.stopPropagation());
    panel.addEventListener('pointerup',event=>event.stopPropagation());
    if(kind==='emoji'){
      panel.innerHTML=`<div class="qq-emoji-grid">${['😀','😊','🥰','🤔','😂','🥺','😎','😴','👍','👏','❤️','🌹','🎉','✨','☀️','☕'].map(emoji=>`<button data-qq="emoji" data-value="${emoji}" aria-label="插入 ${emoji}">${emoji}</button>`).join('')}</div>`;
    }else{
      panel.innerHTML=`<div class="qq-tool-pages">${pages.map((items,i)=>`<div class="qq-tool-page" aria-label="更多功能第 ${i+1} 页">${items.map(([action,label,ico])=>button(action,label,ico)).join('')}</div>`).join('')}</div><div class="qq-panel-dots">${pages.map((_,i)=>`<button data-qq="page" data-page="${i}" aria-label="更多功能第 ${i+1} 页" aria-pressed="${!i}"></button>`).join('')}</div>`;
      const track=panel.querySelector('.qq-tool-pages');
      track.addEventListener('scroll',()=>{const at=Math.round(track.scrollLeft/Math.max(1,track.clientWidth));panel?.querySelectorAll('[data-qq=page]').forEach((dot,i)=>dot.setAttribute('aria-pressed',String(at===i)))},{passive:true});
    }
    $('.composer-area').append(panel);
    root.querySelector('[data-tool=attachments]')?.setAttribute('aria-expanded',String(kind==='more'));
    measureComposer();
  }
  function favorites(){
    closePanel();SkivuHost.emit('favorites');
    showSheet('收藏',`<p class="sheet-caption">来自 Skivu 的消息收藏</p><div id="qqFavoriteItems">${favoriteRows()}</div>`);
  }
  function favoriteRows(){return (snapshot.favorites||[]).map(text=>`<p class="qq-favorite-item">${esc(text)}</p>`).join('')||'<p class="sheet-caption">暂时没有收藏的消息</p>'}
  function paint(){
    if(!enabled()){if(panel)closePanel();root.classList.remove('qq-default-bubbles','qq-empty-chat');$('#sendButton').disabled=false;$('#roleTitle').removeAttribute('aria-label');return}
    const page=SocialPreview.page();
    if(page!=='chat'&&panel)closePanel();
    const appearance=snapshot.appearance;
    root.classList.toggle('qq-default-bubbles',appearance?.defaultBubbleSurface===true&&appearance.userBlur===6&&appearance.assistantBlur===6);
    root.classList.toggle('qq-empty-chat',!snapshot.messages?.length);
    if(page==='inbox'){
      $('#roleTitle').innerHTML=`${esc(snapshot.userLabel||'我')}<small class="qq-inbox-subtitle">消息</small>`;
      $('#roleTitle').setAttribute('aria-label','打开 Skivu 导航');
      $('#socialQQProfile').setAttribute('aria-label','打开 Skivu 导航');
      $('#socialTopAction').setAttribute('aria-label','添加对话');
    }else{
      $('#roleTitle').removeAttribute('aria-label');
      if(page==='chat'){$('#socialTopAction').setAttribute('aria-label','聊天设置');$('#socialTopAction').removeAttribute('aria-expanded')}
    }
    const tools=$('.qq-tools');
    if(tools.dataset.qqChatTools!=='1'){
      tools.innerHTML=[['voice','语音','mic'],['image','图片','image'],['camera','拍照','camera'],['models','模型助手','sparkles'],['emoji','表情','smile'],['attachments','更多','plus-circle']].map(([action,label,ico])=>`<button data-social="chat-tool" data-tool="${action}" aria-label="QQ ${label}" ${action==='attachments'?'aria-expanded="false"':''}>${icon(ico)}</button>`).join('');
      tools.dataset.qqChatTools='1';
    }
    refreshSend();
  }
  window.QqChat={
    update(value){
      const next=`${value.mode}:${value.selectedId}`;
      if(next!==context||value.ack==='send')closePanel();context=next;snapshot=value;paint();
      const saved=$('#qqFavoriteItems');if(enabled()&&saved)saved.innerHTML=favoriteRows();
    },paint,
    capture(event,node){
      if(!enabled())return false;
      const action=node.dataset.qq,s=node.dataset.social,a=node.dataset.action,page=SocialPreview.page();
      const handled=()=>{event.preventDefault();event.stopImmediatePropagation();return true};
      if(action){
        handled();
        if(action==='page'){const track=panel?.querySelector('.qq-tool-pages');track?.scrollTo({left:Number(node.dataset.page)*track.clientWidth,behavior:'smooth'})}
        else if(action==='emoji'){
          const input=$('#messageInput'),start=input.selectionStart,end=input.selectionEnd;
          input.setRangeText(node.dataset.value||'',start,end,'end');input.dispatchEvent(new Event('input',{bubbles:true}));refreshSend();
        }
        else if(['voice-call','video-call','location','file','redpacket','transfer','favorites','screen','contacts','gifts','music'].includes(action)){closePanel();ChatInteractions.open(action)}
        else if(action==='role'){closePanel();SkivuHost.emit('editRole',{roleId:snapshot.selectedRoleId})}
        else if(action==='new'){closeSheet();SkivuHost.chooseRole(null)}
        else if(action==='roles'){closeSheet();SkivuHost.emit('roles')}
        else if(action==='profile'){closeSheet();SkivuHost.emit('userCard')}
        else if(action==='classic'){closeSheet();SkivuHost.emit('classicUi')}
        return true;
      }
      if(s==='qq-profile'||(a==='edit-role'&&page==='inbox')){handled();SkivuHost.emit('drawer',{side:'left'});return true}
      if(s==='top-action'&&page==='inbox'){
        handled();showSheet('添加',button('new','新建对话','chat')+button('roles','角色管理','users')+button('profile','我的资料与头像','user')+button('classic','回到原版','cloud'));return true;
      }
      if(s==='back'&&page==='chat'&&panel){handled();closePanel();return true}
      if(node.dataset.feature==='profile'){handled();SocialPreview.showRole(node.dataset.role||snapshot.selectedRoleId);return true}
      if(s!=='chat-tool')return false;
      handled();const tool=node.dataset.tool;
      if(tool==='attachments')openPanel('more');
      else if(tool==='emoji')openPanel('emoji');
      else if(tool==='models'){closePanel();SkivuHost.emit('models')}
      else {closePanel();ChatInteractions.open(tool==='voice'?'voice':tool==='image'?'image':'camera')}
      return true;
    },
  };
  document.addEventListener('input',event=>{if(event.target.id==='messageInput')refreshSend()});
  document.addEventListener('focusin',event=>{if(event.target.id==='messageInput'&&enabled())closePanel()});
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&panel){event.preventDefault();closePanel()}},true);
})();
