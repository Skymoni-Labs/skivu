/* Shared app-owned queued turns, typed media and user sticker library. */
(() => {
  let state=null,group='';
  const button=(action,label,extra='')=>`<button data-companion="${action}" ${extra}>${esc(label)}</button>`;
  function paintStickers(force=false){
    document.querySelectorAll('.chat-emoji-grid,.qq-emoji-grid').forEach(grid=>{
      const parent=grid.parentElement;
      let holder=parent.querySelector('.companion-stickers');
      if(!holder){holder=document.createElement('section');holder.className='companion-stickers';parent.append(holder)}
      const groups=state.stickerGroups||[],stickers=(state.stickers||[]).filter(s=>s.active);
      if(group&&!groups.some(g=>g.id===group))group='';
      const key=group+JSON.stringify([groups,stickers.map(s=>[s.id,s.groupId,s.name])]);
      if(!force&&holder.dataset.key===key)return;holder.dataset.key=key;
      const values=stickers.filter(s=>!group||s.groupId===group);
      holder.innerHTML=`<div class="companion-sticker-groups">${button('group','全部',`data-group="" aria-pressed="${!group}"`)}${groups.map(g=>button('group',g.name,`data-group="${esc(g.id)}" aria-pressed="${group===g.id}"`)).join('')}${button('manage-stickers','＋ 管理')}</div><div class="companion-sticker-grid">${values.map(s=>`<button data-companion="sticker" data-id="${esc(s.id)}" aria-label="发送表情 ${esc(s.name)}"><img src="${esc(s.data)}" alt="${esc(s.name)}"><span>${esc(s.name)}</span></button>`).join('')||'<p>添加自己的表情，并按分组整理。</p>'}</div>`;
    });
  }
  function paint(){
    if(!state)return;
    const area=$('.composer-area');let bar=$('#companionBatchBar');
    if(!bar){bar=document.createElement('div');bar.id='companionBatchBar';area.prepend(bar)}
    const count=state.queuedCount||0;
    bar.hidden=SocialPreview.page()!=='chat'||(!state.confirmBeforeReply&&!count);
    bar.innerHTML=`<span>${count?count+' 条待发送':'分条输入，确认后统一回复'}</span>${count?button('discard','清空'):''}<button data-companion="confirm" ${!count||state.streaming?'disabled':''}>确认发送</button>`;
    (state.messages||[]).forEach((m,index)=>{
      const row=document.querySelector(`[data-message-id="${CSS.escape(m.id)}"]`),bubble=row?.querySelector('.bubble');
      if(!row||!bubble)return;
      row.classList.toggle('companion-sticker-message',m.kind==='sticker');
      const key=[m.kind,m.stickerId,m.imageData,m.described,m.text].join('|');
      if(m.kind&&m.kind!=='text'&&bubble.dataset.companionKey!==key){
        bubble.dataset.companionKey=key;
        if(m.kind==='sticker'){
          const sticker=(state.stickers||[]).find(s=>s.id===m.stickerId);
          bubble.innerHTML=sticker?`<img class="companion-sticker-image" src="${esc(sticker.data)}" alt="${esc(m.text)}">`:`[表情包：${esc(m.text)}]`;
        }else if(m.kind==='voice')bubble.innerHTML=`<details class="companion-voice"><summary>${icon('mic')}<span>语音 · ${m.described?'文字描述':'识别转写'}</span><small>查看内容</small></summary><p>${esc(m.text)}</p></details>`;
        else if(m.kind==='image')bubble.innerHTML=`<img class="companion-photo-image" src="${esc(m.imageData||'')}" alt="${esc(m.text)}"><p class="companion-photo-caption">${esc(m.text)}</p>`;
        else if(m.kind==='photo')bubble.innerHTML=`<div class="companion-photo-label">${icon('image')}<span>照片 · 内容描述</span></div><p class="companion-photo-caption">${esc(m.text)}</p>`;
      }
      let pending=row.querySelector('.companion-queued');
      if(m.queued){if(!pending){pending=document.createElement('div');pending.className='companion-queued';row.querySelector('.message-content').append(pending)}pending.innerHTML=`<span>待确认</span>${button('remove-queued','移除',`data-index="${index}"`)}`}
      else pending?.remove();
    });
    paintStickers();measureComposer();
  }
  window.CompanionChat={update(value){
    const previous=state;state=value;paint();
    const last=state.messages?.at(-1);
    if(previous&&previous.selectedId===state.selectedId&&state.messages.length>previous.messages.length&&last?.role==='user'){
      bottom();
      document.querySelectorAll('#messages .message:last-child img').forEach(img=>{if(!img.complete)img.addEventListener('load',()=>{if(state.selectedId===value.selectedId&&state.messages?.at(-1)?.id===last.id)bottom()},{once:true})});
    }
  },paint,capture(event,node){
    if(!state)return false;
    const action=node.dataset.companion,a=node.dataset.interaction,tool=node.dataset.tool,qq=node.dataset.qq;
    const media=action==='photo'||a==='describe-image'||qq==='describe-image'?'photo':action==='voice'||a==='describe-voice'||qq==='describe-voice'?'voice':null;
    const camera=a==='camera'||tool==='camera';
    const realPhoto=a==='image'||tool==='image'||camera;
    const realVoice=a==='voice'||tool==='voice';
    if(!action&&!media&&!realPhoto&&!realVoice)return false;
    event.preventDefault();event.stopImmediatePropagation();
    if(media||realPhoto||realVoice){SkivuHost.emit('composeMedia',{kind:media||(realPhoto?'photo':'voice'),real:!!(realPhoto||realVoice),...(realPhoto?{source:camera?'camera':'chooser'}:{})});return true}
    if(action==='confirm')SkivuHost.emit('confirmBatch');
    if(action==='discard')SkivuHost.emit('discardBatch');
    if(action==='manage-stickers')SkivuHost.emit('stickerLibrary');
    if(action==='sticker')SkivuHost.emit('sendSticker',{stickerId:node.dataset.id});
    if(action==='remove-queued'){const index=Number(node.dataset.index);SkivuHost.emit('removeQueued',{index,created:state.messages[index]?.created})}
    if(action==='group'){group=node.dataset.group||'';paintStickers(true)}
    return true;
  }};
  new MutationObserver(()=>{if(state)paintStickers()}).observe($('#phone'),{childList:true,subtree:true});
})();
