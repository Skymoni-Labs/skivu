/* Trusted built-in presenter bridge. No network, account keys or model endpoint. */
(() => {
  let snapshot=null, draftRevision=0;
  const emit=(command,args={})=>{
    const value={protocol:1,command,chatId:snapshot?.selectedId,...args};
    if(window.SkivuNative)window.SkivuNative.postMessage(JSON.stringify(value));
    else parent.postMessage({type:'skivu-ui-command',payload:value},location.origin);
  };
  function chooseRole(id,create=false){
    if(!snapshot)return;
    if(!id){showSheet('选择角色',snapshot.roles.map(r=>`<button class="social-contact-row" data-host="new" data-role="${esc(r.id)}">${SocialPreview.portrait(r.id)}<strong>${esc(r.name)}</strong></button>`).join(''));return}
    if(create){emit('newChat',{roleId:id});closeSheet();return}
    const role=snapshot.roles.find(r=>r.id===id);if(!role)return;
    const chats=snapshot.chats.filter(c=>c.personaId===id&&!c.groupMembers?.length);
    showSheet(role.name,`<p class="sheet-caption">${chats.length} 段独立对话 · 共用角色卡，记录各自保存</p>`+chats.map(c=>`<button class="sheet-item" data-host="select" data-id="${esc(c.id)}"><span style="min-width:0;flex:1"><strong>${esc(c.title)}</strong><small style="display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(c.preview||'还没有消息')}</small></span>${c.id===snapshot.selectedId?icon('check'):''}</button>`).join('')+`<button class="sheet-item" data-host="new" data-role="${esc(id)}">${icon('plus')}新建独立对话</button>`);
  }
  window.SkivuHost={
    emit,chooseRole,
    inboxHtml(filter=''){
      if(!snapshot)return '';
      return snapshot.chats.filter(c=>{const role=snapshot.roles.find(r=>r.id===c.personaId);return role&&!(snapshot.mode==='qq'&&c.groupKind==='channel')&&(role.name+' '+c.title).toLowerCase().includes(filter.toLowerCase())}).map(c=>{
        const role=snapshot.roles.find(r=>r.id===c.personaId);
        const local=window.ChatInteractions?.inboxPreview(c,snapshot)||c;
        const group=c.groupMembers?.length;
        return `<button class="social-chat-row ${c.pinned?'pinned':''}" data-host="select" data-id="${esc(c.id)}" aria-label="打开对话 ${esc(c.title)}">${group?'<span class="social-group-face">'+c.groupMembers.slice(0,4).map(id=>SocialPreview.portrait(id)).join('')+'</span>':SocialPreview.portrait(role.id)}<span class="social-chat-info"><span class="social-chat-title">${esc(group?c.title:role.name)} <span style="font-size:11px;color:#999">${esc(group?'群聊':c.title)}</span></span><span class="social-chat-snippet">${esc(c.hasDraft?'[草稿] '+c.preview:local.preview||'还没有消息')}</span></span><span class="social-chat-tail"><time>${esc(local.time||'')}</time>${c.muted?'<span class="wx-inbox-muted" aria-label="消息免打扰">'+icon('bell-off')+'</span>':c.id===snapshot.selectedId?'<span style="color:#07c160;font-size:9px">●</span>':''}</span></button>`;
      }).join('')||'<div class="social-search-empty">还没有对话，点击右上角选择角色新建。</div>';
    },
    receive(update){
      if(Number.isFinite(update.safeTop))document.documentElement.style.setProperty('--host-safe-top',Math.max(0,update.safeTop)+'px');
      const previous=snapshot;
      if(!previous){try{const saved=JSON.parse(localStorage.getItem('skivu.host.social.v1')||'null');if(Array.isArray(saved?.posts)&&saved.posts.length)emit('importPosts',{posts:saved.posts})}catch{}}
      if(update.ack==='importPosts'){try{const saved=JSON.parse(localStorage.getItem('skivu.host.social.v1')||'{}');delete saved.posts;localStorage.setItem('skivu.host.social.v1',JSON.stringify(saved))}catch{}}
      snapshot={...snapshot,...update};if(!update.delta)delete snapshot.delta;if(!update.ack)delete snapshot.ack;
      if(update.delta&&previous){snapshot.messages=[...previous.messages];snapshot.messages[update.delta.index]=update.delta.message}
      const changed=previous&&snapshot.selectedId!==previous.selectedId;
      window.SocialFeatures?.update(snapshot,update);
      SocialPreview.hostApply(snapshot,{changed,view:update.view});
      SharedChatAppearance.update(snapshot);
      QqChat.update(snapshot);
      ChatInteractions.update(snapshot);
      CompanionChat.update(snapshot);
      const input=$('#messageInput');
      if(changed||!previous||((update.draftRevision||0)>=draftRevision&&(update.ack==='send'||document.activeElement!==input))){input.value=snapshot.draft||'';applyDraftState()}
      draftRevision=Math.max(changed?0:draftRevision,update.draftRevision||0);
      document.body.classList.add('host-ready');
      if(update.notice)toast(update.notice);
      if(update.error){toast(update.error);const b=document.querySelector('[data-social=publish]');if(b)b.disabled=false}
      if(update.socialError&&update.socialError!==previous?.socialError)toast(update.socialError);
    },
    home(){SocialPreview.go('inbox')}
  };
  addEventListener('message',event=>{if(event.source!==parent||event.origin!==location.origin||event.data?.type!=='skivu-ui-state')return;SkivuHost.receive(event.data.payload)});
  save=()=>{};
  setDrawer=side=>{if(side==='left'||side==='right')emit('drawer',{side})};
  send=()=>{if(!snapshot)return;if(snapshot.streaming){emit('stop');return}const text=$('#messageInput').value.trim();if(text)emit('send',{text,revision:++draftRevision})};
  stopStream=()=>{};
  document.addEventListener('input',event=>{if(event.target.id==='messageInput'&&snapshot)emit('draft',{text:event.target.value,revision:++draftRevision})},true);
  document.addEventListener('submit',event=>{
    if(event.target.id==='socialRemarkForm'){event.preventDefault();event.stopImmediatePropagation();const name=String(new FormData(event.target).get('name')||'').trim();emit('renameRole',{roleId:SocialPreview.currentRole().id,name});closeSheet()}
    if(event.target.id==='socialCommentForm'){event.preventDefault();event.stopImmediatePropagation();emit('postAction',{operation:'comment',id:event.target.dataset.post,text:String(new FormData(event.target).get('text')||'')});closeSheet()}
    if(event.target.id==='socialProfileForm'){emit('userName',{name:String(new FormData(event.target).get('name')||'')})}
  },true);
  SkivuHost.captureClick=event=>{
    const node=event.target.closest('[data-companion],[data-interaction],[data-qq],[data-feature],[data-host],[data-action],[data-social]');if(!node)return;
    if(window.CompanionChat?.capture(event,node))return;
    if(window.ChatInteractions?.capture(event,node))return;
    if(window.QqChat?.capture(event,node))return;
    if(node.dataset.feature){window.SocialFeatures?.capture(event,node);return}
    const host=node.dataset.host,a=node.dataset.action,s=node.dataset.social;
    const handle=()=>{event.preventDefault();event.stopImmediatePropagation()};
    if(host){handle();if(host==='select')emit('selectChat',{id:node.dataset.id});if(host==='new')chooseRole(node.dataset.role,true);if(host==='role-chats')chooseRole(snapshot?.selectedRoleId);return}
    if(a==='send'){handle();send();return}
    if(a==='edit-role'){handle();emit('editRole',{roleId:snapshot?.selectedRoleId});return}
    if(['models','settings','call','left','right','user-avatar'].includes(a)){
      handle();emit(a==='left'||a==='right'?'drawer':a==='user-avatar'?'userCard':a,{side:a});return;
    }
    if(a==='message-more'){handle();emit('messageMenu',{index:Number(node.dataset.index),created:snapshot?.messages[Number(node.dataset.index)]?.created});return}
    if(s==='social-settings'){handle();emit('socialSettings');return}
    if(s==='favorites'){handle();emit('favorites');SocialPreview.go('favorites');return}
    if(s==='publish'){handle();const post=SocialPreview.postDraft();node.disabled=true;emit('publishPost',post);return}
    if(s==='like'||s==='confirm-delete-post'){handle();emit('postAction',{operation:s==='like'?'like':'delete',id:node.dataset.post});if(s==='confirm-delete-post')closeSheet();return}
    if(s==='top-action'&&SocialPreview.page()==='inbox'){handle();if(snapshot?.mode==='wx')SocialFeatures.showPlus();else chooseRole(null);return}
    if(s==='top-action'&&SocialPreview.page()==='contacts'&&snapshot?.mode==='wx'){handle();SocialFeatures.friends();return}
    if(s==='back'&&SocialPreview.page()==='chat-info'){handle();SocialFeatures.backFromInfo();return}
    if(s==='top-action'&&SocialPreview.page()==='chat'){handle();SocialFeatures.showChatInfo();return}
    if(s==='chat'){handle();chooseRole(node.dataset.id||snapshot?.selectedRoleId);return}
    if(['new-group','requests','groups','tags','subscriptions','edit-role'].includes(s)){
      handle();if(s==='edit-role')emit('editRole',{roleId:SocialPreview.currentRole().id});else emit('roles');return;
    }
    if(s==='favorite-message'){handle();emit('messageMenu',{index:Number(node.dataset.index),created:snapshot?.messages[Number(node.dataset.index)]?.created});return}
    if(s==='upload-profile-avatar'){handle();emit('userAvatar');return}
  };
  document.addEventListener('contextmenu',event=>{const row=event.target.closest('.social-chat-row[data-host="select"]');if(row){event.preventDefault();emit('chatMenu',{id:row.dataset.id})}});
  let hold=null,holdOrigin=null,suppressClick=false;
  document.addEventListener('pointerdown',event=>{const row=event.target.closest('.social-chat-row[data-host="select"]');if(row&&event.pointerType!=='mouse'){holdOrigin=[event.clientX,event.clientY];hold=setTimeout(()=>{hold=null;suppressClick=true;emit('chatMenu',{id:row.dataset.id})},600)}},{passive:true});
  const cancelHold=()=>{clearTimeout(hold);hold=null};
  document.addEventListener('pointermove',event=>{if(holdOrigin&&Math.hypot(event.clientX-holdOrigin[0],event.clientY-holdOrigin[1])>10)cancelHold()},{passive:true});
  document.addEventListener('pointerup',cancelHold,{passive:true});document.addEventListener('pointercancel',cancelHold,{passive:true});
  const priorCapture=SkivuHost.captureClick;SkivuHost.captureClick=event=>{if(suppressClick){suppressClick=false;event.preventDefault();event.stopImmediatePropagation();return}priorCapture(event)};
  emit('ready');
})();
