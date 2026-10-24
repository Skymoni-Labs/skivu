/* Shared local role interactions. No Tencent protocol, account or payment API. */
(() => {
  let state=null,layer=null,panel=null,panelKind='',context='',view='',detailId='',busy=false,mediaStream=null,recorder=null,recordTimer=null,eventSignature='',pendingOpen=null,voiceMode=false,hold=null,downloadUrls=[],screenRevision=0;
  const root=$('#chatPlane'),uid=()=>crypto.randomUUID?.()||'event-'+Date.now()+'-'+Math.random().toString(36).slice(2);
  const cash=n=>(Number(n||0)/100).toFixed(2),role=()=>state?.roles?.find(r=>r.id===state.selectedRoleId);
  const act=(action,extra='')=>`data-interaction="${action}" ${extra}`;
  const btn=(action,label,ico,extra='')=>`<button ${act(action,extra)} ${action==='video-call'?'disabled aria-disabled="true"':''} aria-label="${esc(label)}${action==='video-call'?'，开发中':''}">${ico?icon(ico):''}<span>${esc(label)}${action==='video-call'?'<small class="video-call-unavailable">开发中</small>':''}</span></button>`;
  const wxPages=[
    [['image','相册','image'],['camera','拍摄','camera'],['video-call','视频通话','video'],['location','位置','pin'],['redpacket-menu','红包','envelope'],['gifts','礼物','gift'],['transfer','转账','transfer'],['voice','语音输入','mic']],
    [['favorites','收藏','box'],['contacts','个人名片','user'],['file','文件','folder'],['music','音乐','music'],['describe-image','描述照片','image']],
  ];
  ICONS.transfer='<path d="M4 8h15l-4-4M20 16H5l4 4"/>';
  ICONS.envelope='<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M5 8c5 5 9 5 14 0"/><circle cx="12" cy="11" r="2"/>';
  ICONS['interaction-back']='<path d="m15 5-7 7 7 7"/>';
  ICONS.clock='<circle cx="12" cy="12" r="9"/><path d="M12 7v6l4 2"/>';
  ICONS.list='<path d="M9 6h12M9 12h12M9 18h12M3 6h1M3 12h1M3 18h1"/>';
  ICONS.keyboard='<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M5 9h1m3 0h1m3 0h1m3 0h1M5 12h1m3 0h1m3 0h1m3 0h1M7 16h10"/>';
  ICONS.hash='<path d="M9 3 6 21M18 3l-3 18M3 9h19M2 16h19"/>';
  ICONS['qq-zone']='<path d="M17 4a9 9 0 1 0 4 11M17 2l1.3 3.5L22 6.8l-3.7 1.3L17 12l-1.3-3.9L12 6.8l3.7-1.3Z"/>';
  ICONS['address-book']='<circle cx="9" cy="7" r="4"/><path d="M2 21v-3c0-4 3-6 7-6s7 2 7 6v3M18 6h4M18 11h4M18 16h4"/>';
  const instructions='<p class="interaction-disclosure">角色互动 · 虚拟资金，仅保存在此设备</p>';
  const originalSheet=showSheet;
  showSheet=(title,html)=>{originalSheet(title,html);if(state){const button=$('.sheet-header [data-action=close-sheet]');if(button)button.innerHTML=icon('interaction-back')}};
  function stopMedia(){clearTimeout(recordTimer);recordTimer=null;if(recorder?.state==='recording')recorder.stop();recorder=null;mediaStream?.getTracks().forEach(t=>t.stop());mediaStream=null}
  function close(){screenRevision++;stopMedia();downloadUrls.forEach(url=>URL.revokeObjectURL(url));downloadUrls=[];layer?.remove();layer=null;view='';detailId='';busy=false}
  function closePanel(){panel?.remove();panel=null;panelKind='';root.querySelector('.wx-plus')?.setAttribute('aria-expanded','false');measureComposer()}
  function show(title,html,kind){
    screenRevision++;closePanel();stopMedia();if(!layer){layer=document.createElement('section');layer.className='interaction-screen';$('#phone').append(layer)}
    view=kind;layer.dataset.mode=state.mode;layer.dataset.view=kind;
    delete layer._sendId;delete layer._pending;delete layer._record;
    layer.classList.remove('money-keyboard-open');
    layer.innerHTML=`<header class="interaction-header"><button ${act('back')} aria-label="返回">${icon('interaction-back')}</button><h2>${esc(title)}</h2><button ${act('screen-more')} aria-label="更多">${icon('more')}</button></header><div class="interaction-content">${html}</div>`;
  }
  function error(text){const el=layer?.querySelector('.interaction-error');if(el){el.textContent=text;el.hidden=false}else toast(text)}
  function parse(text){if(!/^(0|[1-9]\d{0,5})(\.\d{1,2})?$/.test(text.trim()))return null;const [a,b='']=text.trim().split('.');return Number(a)*100+Number(b.padEnd(2,'0'))}
  function keypad(red){return `<div class="money-keypad" aria-label="金额键盘">${['1','2','3','back','4','5','6','submit','7','8','9','.','0','hide'].map(key=>`<button ${act('money-key',`data-key="${key}"`)} aria-label="${key==='back'?'退格':key==='hide'?'收起键盘':key==='submit'?(red?'塞钱进红包':'转账'):key}">${key==='back'?icon('close'):key==='hide'?icon('down'):key==='submit'?(red?'塞钱':'转账'):key}</button>`).join('')}</div>`}
  function transfers(){return (state?.wallet?.transactions||[]).filter(t=>t.chatId===state.selectedId)}
  function events(){const since=state?.interactionsClearedAt||'',hidden=new Set(state?.hiddenInteractions||[]);return [...(state?.interactions||[]),...transfers().map(t=>({...t,user:!t.incoming,kind:t.kind,payload:t}))].filter(e=>!hidden.has(e.id)&&(!since||e.created>since)).sort((a,b)=>a.created.localeCompare(b.created))}
  function append(kind,payload){if(busy)return;busy=true;const id=layer?(layer._sendId||=uid()):uid();SkivuHost.emit('chatInteraction',{event:{id,kind,payload,created:new Date().toISOString(),user:true}})}
  function panelOpen(kind){
    if(panelKind===kind){closePanel();return}closePanel();$('#messageInput').blur();panelKind=kind;
    panel=document.createElement('section');panel.className='wx-chat-panel';panel.setAttribute('aria-label',kind==='emoji'?'微信表情面板':'微信更多功能');
    panel.addEventListener('pointerdown',e=>e.stopPropagation());panel.addEventListener('pointerup',e=>e.stopPropagation());
    if(kind==='emoji')panel.innerHTML=`<div class="chat-emoji-grid">${['😀','😊','🥰','🤔','😂','🥺','😎','😴','👍','👏','❤️','🌹','🎉','✨','☀️','☕','😭','🤝','💪','🙏','🎂','🎁','🌙','🍀'].map(v=>btn('emoji','插入 '+v,null,`data-value="${v}"`).replace(`<span>插入 ${v}</span>`,`<span>${v}</span>`)).join('')}</div>`;
    else panel.innerHTML=`<div class="wx-tool-pages">${wxPages.map((items,i)=>`<div class="wx-tool-page" aria-label="微信更多功能第 ${i+1} 页">${items.map(([a,l,ico])=>btn(a,l,ico)).join('')}</div>`).join('')}</div><div class="interaction-dots">${wxPages.map((_,i)=>`<button ${act('panel-page',`data-page="${i}"`)} aria-label="微信更多功能第 ${i+1} 页" aria-pressed="${!i}"></button>`).join('')}</div>`;
    $('.composer-area').append(panel);root.querySelector('.wx-plus')?.setAttribute('aria-expanded',String(kind==='more'));
    const track=panel.querySelector('.wx-tool-pages');track?.addEventListener('scroll',()=>{const at=Math.round(track.scrollLeft/Math.max(1,track.clientWidth));panel?.querySelectorAll('[data-interaction=panel-page]').forEach((dot,i)=>dot.setAttribute('aria-pressed',String(at===i)))},{passive:true});measureComposer();
  }
  function finance(kind,incoming=false,gift=null){
    const red=kind==='redpacket';
    show(red?'发红包':kind==='gift'?'赠送礼物':'',`<form id="interactionMoneyForm" data-kind="${kind}" data-request="${uid()}" data-incoming="${incoming}">
      ${!red?`<div class="transfer-recipient"><span><strong>${incoming?'来自':'转账给'} ${esc(role()?.name||'角色')}</strong><small>角色互动</small></span>${SocialPreview.portrait(state.selectedRoleId)}</div>`:''}
      <div class="interaction-money-card ${red?'redpacket-money-card':''}"><label>${red?'金额':kind==='gift'?'礼物金额':'转账金额'}<span class="money-entry">${red?'':'¥'}<input name="amount" aria-label="${red?'红包金额':'转账金额'}" placeholder="${red?'¥0.00':''}" inputmode="none" autocomplete="off" maxlength="9" required value="${gift?cash(gift.cents):''}" ${gift?'readonly':''}></span></label>
      ${!red?`<input class="transfer-note" name="note" placeholder="添加转账说明" maxlength="100" value="${gift?esc(gift.name):''}">`:''}</div>
      ${red?`<div class="interaction-money-card"><input class="redpacket-note" name="note" placeholder="恭喜发财，大吉大利" maxlength="100"></div><div class="interaction-money-card redpacket-cover"><span>红包封面</span><select name="cover" aria-label="红包封面"><option value="classic">经典红包</option><option value="spring">春日祝福</option><option value="blue">星空心意</option></select></div><div class="redpacket-amount" aria-live="polite">¥ <b id="redpacketTotal">0.00</b></div>`:''}
      <p class="interaction-error" role="alert" hidden></p><div class="money-submit">${instructions}<button class="interaction-primary ${red?'redpacket-primary':''}" type="submit">${red?'塞钱进红包':kind==='gift'?'赠送':'转账'}</button></div></form>${gift?'':keypad(red)}`,kind);
    if(!red&&!gift)layer.classList.add('money-keyboard-open');
  }
  function receipt(id,details=false){
    const t=(state.wallet?.transactions||[]).find(t=>t.id===id);if(!t){toast('交易记录已不存在');return}detailId=id;
    const pending=t.state==='pending',red=t.kind==='redpacket',label=t.state==='refunded'?'已退回':pending?(red?'待领取':'待收款'):(red?'已领取':'已收款');
    if(red&&pending&&t.incoming&&!details){show('',`<div class="redpacket-envelope">${btn('back','关闭红包','close','class="redpacket-close"')}<div class="redpacket-sender">${SocialPreview.portrait(t.roleId)}<span>${esc(t.roleName)}发来的红包</span></div><p>${esc(t.note||'恭喜发财，大吉大利')}</p><button class="redpacket-open-button" ${act('receive-transaction',`data-id="${esc(id)}"`)} aria-label="开红包">開</button>${btn('redpacket-details','查看领取详情',null,`data-id="${esc(id)}" class="redpacket-detail-link"`)}</div>`,'open-redpacket');layer.dataset.cover=t.cover||'classic';return}
    show(red?'红包详情':'转账详情',`<div class="transfer-receipt ${red?'redpacket-receipt':''}"><div class="receipt-symbol">${icon(red?'envelope':pending?'clock':'check')}</div><h3>${esc(label)}</h3><div class="receipt-value">¥${cash(t.cents)}</div><p>${esc(t.note|| (red?'恭喜发财，大吉大利':''))}</p><div class="receipt-person">${SocialPreview.portrait(t.roleId)}<span>${t.incoming?'来自 '+esc(t.roleName):'转账给 '+esc(t.roleName)}</span></div>
      ${pending&&t.incoming?`${btn('receive-transaction',red?'开红包':'确认收款',null,`data-id="${esc(id)}" class="interaction-primary"`)}${btn('refund-transaction','立即退还',null,`data-id="${esc(id)}" class="interaction-link"`)}`:pending?'<p class="receipt-waiting">等待对方'+(red?'领取':'确认收款')+'</p>':''}
      <small>${esc(t.created.replace('T',' ').slice(0,19))}</small>${instructions}</div>`,'receipt');
  }
  function wallet(){show(state.mode==='qq'?'QQ 钱包':'钱包',`<div class="local-wallet-head">${icon('wallet')}<p>零钱</p><strong>¥ ${cash(state.wallet?.balanceCents)}</strong>${instructions}</div><div class="interaction-list">${btn('balance','设置虚拟零钱','wallet')}${btn('ledger','账单','list')}${btn('incoming','模拟角色转账','transfer')}${btn('incoming-redpacket','模拟角色红包','envelope')}</div>`,'wallet')}
  function ledgerLabel(t){const kind=(state.wallet?.transactions||[]).find(v=>v.id===t.transactionId)?.kind||t.kind;return t.kind==='set'?'余额调整':t.kind==='refund'?'退回':kind==='redpacket'?'红包':kind==='gift'?'礼物':'转账'}
  function ledger(){show('账单',`<div class="interaction-ledger">${(state.wallet?.entries||[]).map(t=>`<article><div><strong>${esc(ledgerLabel(t))} ${esc(t.roleName||'')}</strong><small>${esc(t.created.replace('T',' ').slice(0,16))}</small></div><b>${t.cents>0?'+':'−'}${cash(Math.abs(t.cents))}</b></article>`).join('')||'<p class="interaction-empty">暂无账单</p>'}</div>${instructions}`,'ledger')}
  async function pick(kind){
    closePanel();const source=context,revision=screenRevision,input=document.createElement('input');input.type='file';
    input.accept=kind==='image'?'image/png,image/jpeg,image/webp':kind==='video'?'video/mp4,video/webm':kind==='music'?'audio/mpeg,audio/mp4,audio/wav,audio/ogg,audio/webm':'.pdf,.txt,.zip';
    input.addEventListener('change',async()=>{
      const file=input.files?.[0];if(!file||source!==context||revision!==screenRevision)return;
      if(file.size>2*1024*1024){toast('请选择 2MB 以内的本机文件');return}
      let data;try{data=await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=reject;r.readAsDataURL(file)})}catch{toast('文件无法读取');return}
      if(source!==context||revision!==screenRevision)return;
      show('发送'+({image:'图片',video:'视频',music:'音乐',file:'文件'}[kind]),`${kind==='image'?`<img class="interaction-image-preview" src="${esc(data)}" alt="待发送图片">`:kind==='video'?`<video class="interaction-image-preview" src="${esc(data)}" controls></video>`:kind==='music'?`<audio src="${esc(data)}" controls></audio>`:icon('folder')}<p>${esc(file.name)}</p><p class="interaction-disclosure">仅保存至当前角色对话，不发送给其他用户</p>${btn('send-preview','发送',null,'class="interaction-primary"')}`,'file-preview');
      layer._pending={kind,payload:{data:kind==='file'?data.replace(/^data:[^;]*;/,'data:application/octet-stream;'):data,name:file.name}};
    },{once:true});input.click();
  }
  function camera(screen=false){show(screen?'屏幕分享':'拍摄',`<video id="interactionCamera" autoplay muted playsinline></video><p class="interaction-disclosure">${screen?'本机屏幕预览，不连接其他设备':'打开摄像头后可拍照，发送前会预览确认'}</p><div class="interaction-camera-actions">${btn(screen?'start-screen':'start-camera',screen?'选择窗口':'打开摄像头','camera')}${!screen?btn('take-photo','拍照','camera'):''}</div>`,'camera')}
  function voice(){show('语音',`<div class="voice-record-symbol">${icon('mic')}</div><p class="interaction-empty" id="voiceStatus">按下开始录音，完成后可试听并发送</p><audio id="voicePlayback" controls hidden></audio><div class="voice-actions">${btn('start-record','开始录音','mic')}${btn('stop-record','结束录音','stop')}${btn('send-record','发送语音','arrow-up')}</div><p class="interaction-error" role="alert" hidden></p>`,'voice')}
  function open(action){
    if(!state)return;closePanel();
    if(['transfer','redpacket'].includes(action)){finance(action);return}
    if(action==='redpacket-menu'){show('红包',`<div class="interaction-list">${btn('redpacket','红包','envelope')}${btn('redpacket','拜年红包','gift')}</div>`,'redpacket-menu');return}
    if(action==='wallet'){wallet();return}if(action==='ledger'){ledger();return}
    if(['image','file','music','video'].includes(action)){pick(action).catch(()=>toast('文件无法读取'));return}
    if(action==='video-call'){toast('视频通话开发中');return}
    if(action==='camera'||action==='screen'){camera(action==='screen');return}
    if(action==='voice'){voice();return}
    if(action==='voice-call'){show('语音通话',`<div class="role-call-portrait">${SocialPreview.portrait(state.selectedRoleId,'big')}<h3>${esc(role()?.name||'角色')}</h3><p>使用 Skivu 角色语音引擎</p>${btn('native-call','开始语音通话','phone','class="interaction-primary"')}</div>`,'voice-call');return}
    if(action==='location'){show('位置',`<form id="interactionLocationForm" class="interaction-form"><label>位置名称<input name="label" required maxlength="120" placeholder="例如：湖边咖啡馆"></label><label>地址<input name="address" maxlength="300" placeholder="输入地点或情景地址"></label><div class="location-map">${icon('pin')}<span>角色场景位置</span></div><button class="interaction-primary" type="submit">发送位置</button></form>`,'location');return}
    if(action==='contacts'){show('选择联系人',`<div class="interaction-list">${(state.roles||[]).map(r=>`<button ${act('share-contact',`data-role="${esc(r.id)}"`)}>${SocialPreview.portrait(r.id)}<span>${esc(r.name)}</span>${icon('right')}</button>`).join('')}</div>`,'contacts');return}
    if(action==='favorites'){SkivuHost.emit('favorites');show('收藏','<div id="interactionFavorites"></div>','favorites');paintFavorites();return}
    if(action==='gifts'){show('礼物',`<div class="gift-catalog">${[['🌹','一枝玫瑰',100],['☕','一杯咖啡',520],['⭐','一颗星星',1314],['🎂','生日蛋糕',2000]].map(([emoji,name,cents])=>`<button ${act('gift',`data-name="${esc(name)}" data-cents="${cents}"`)}><strong>${emoji}</strong><span>${name}</span><small>¥${cash(cents)}</small></button>`).join('')}</div>${instructions}`,'gifts');return}
    if(action==='models'){SkivuHost.emit('models');return}
  }
  function paintFavorites(){const el=$('#interactionFavorites');if(el)el.innerHTML=(state.favorites||[]).map((t,i)=>`<button ${act('use-favorite',`data-index="${i}"`)} class="favorite-choice">${esc(t)}</button>`).join('')||'<p class="interaction-empty">暂无收藏，可在消息菜单中收藏内容。</p>'}
  function card(e){
    const p=e.payload,financial=['transfer','redpacket','gift'].includes(e.kind),extra=`data-id="${esc(e.id)}"`;
    if(financial){const red=e.kind==='redpacket',label=p.state==='received'?(red?'已领取':'已收款'):p.state==='refunded'?'已退回':red?'领取红包':'待收款';return `<button class="finance-chat-card ${red?'redpacket-chat-card':''} ${p.state!=='pending'?'resolved':''}" ${act('receipt',extra)}><span class="finance-card-main">${icon(red?'envelope':e.kind==='gift'?'gift':'transfer')}<span><strong>${red?esc(p.note||'恭喜发财，大吉大利'):'¥'+cash(p.cents)}</strong><small>${esc(label)}</small></span></span><span class="finance-card-footer">${e.kind==='gift'?'礼物':red?'红包':'转账'} · 角色虚拟钱包</span></button>`}
    if(e.kind==='image')return `<button class="image-chat-card" ${act('view-event',extra)}><img src="${esc(p.data)}" alt="${esc(p.name)}"></button>`;
    if(e.kind==='video')return `<video class="media-chat-card" src="${esc(p.data)}" controls playsinline aria-label="${esc(p.name)}"></video>`;
    if(e.kind==='audio'||e.kind==='music')return `<div class="audio-chat-card"><span>${esc(p.name)}</span><audio src="${esc(p.data)}" controls aria-label="${esc(p.name)}"></audio></div>`;
    if(e.kind==='location')return `<button class="location-chat-card" ${act('view-event',extra)}><strong>${esc(p.label)}</strong><small>${esc(p.address)}</small><span class="location-map">${icon('pin')}</span></button>`;
    if(e.kind==='contact')return `<button class="contact-chat-card" ${act('view-event',extra)}>${SocialPreview.portrait(p.roleId)}<strong>${esc(p.name)}</strong><small>个人名片</small></button>`;
    if(e.kind==='file')return `<button class="file-chat-card" ${act('view-event',extra)}>${icon('folder')}<span><strong>${esc(p.name)}</strong><small>${Math.ceil(p.bytes/1024)} KB</small></span></button>`;
    return `<div class="file-chat-card">${icon('phone')} 通话 ${p.duration||0} 秒</div>`;
  }
  function paint(){
    if(!state)return;const wx=state.mode==='wx';
    if(SocialPreview.page()!=='chat'&&panel)closePanel();
    root.classList.toggle('wx-default-bubbles',wx&&state.appearance?.defaultBubbleSurface===true&&state.appearance.userBlur===6&&state.appearance.assistantBlur===6);
    const all=events();root.classList.toggle('chat-has-events',all.length>0);
    root.classList.toggle('interaction-empty-chat',!state.messages?.length&&!all.length);
    if(!state.messages?.length&&all.length&&$('#messages .date-separator'))$('#messages .date-separator').textContent=all[0].created.replace('T',' ').slice(0,16);
    const signature=context+':'+all.map(e=>e.id+':'+(e.payload.state||'')).join('|');
    if(signature!==eventSignature||$$('.interaction-message').length!==all.length){
      eventSignature=signature;$$('.interaction-message').forEach(n=>n.remove());
    if(SocialPreview.page()==='chat'){
      const originals=[...$('#messages').querySelectorAll('.message')];
      all.forEach(e=>{const el=document.createElement('article');el.className='interaction-message '+(e.user?'user':'assistant');el.dataset.eventId=e.id;
        el.innerHTML=`<span class="interaction-avatar">${SocialPreview.portrait(e.user?'self':state.selectedRoleId)}</span><div class="interaction-message-content">${card(e)}<button class="interaction-event-more" ${act('event-menu',`data-id="${esc(e.id)}"`)} aria-label="消息更多">${icon('more')}</button></div>`;
        const next=originals.find((n,i)=>state.messages[i]?.created>e.created);if(next)next.before(el);else $('#messages').append(el);
      });
    }
    }
    if(wx){
      const input=$('#messageInput'),voiceButton=$('.wx-voice');
      voiceButton.setAttribute('aria-label',voiceMode?'切换键盘输入':'切换语音输入');voiceButton.setAttribute('aria-pressed',String(voiceMode));voiceButton.innerHTML=icon(voiceMode?'keyboard':'voice');$('.wx-plus')?.setAttribute('aria-label','微信更多功能');$('.wx-smile')?.setAttribute('aria-label','微信表情');
      root.classList.toggle('wx-voice-mode',voiceMode);
      if(!$('.wx-hold')){const held=document.createElement('button');held.className='wx-hold';held.dataset.interaction='voice-hold';held.textContent='语音消息';held.setAttribute('aria-label','录入或描述语音消息');input.before(held);held.addEventListener('pointerdown',beginHold);held.addEventListener('pointermove',moveHold);held.addEventListener('pointerup',endHold);held.addEventListener('pointercancel',()=>endHold({cancelled:true}))}
      if(!$('.wx-inline-mic')){const mic=document.createElement('button');mic.className='wx-inline-mic';mic.dataset.interaction='voice';mic.setAttribute('aria-label','语音输入');mic.innerHTML=icon('mic');input.after(mic)}
      root.classList.toggle('wx-text-draft',!!input.value.trim());
    }
    if(SocialPreview.page()==='me'&&state.mode==='qq'&&!$('#qqLocalWallet')){const el=document.createElement('button');el.id='qqLocalWallet';el.className='social-menu-row';el.dataset.interaction='wallet';el.innerHTML=`${icon('wallet')}<span class="menu-text">QQ 钱包</span>${icon('right')}`;$('#socialPage').append(el)}
    if(SocialPreview.page()==='chat-info'&&state.chatInfo?.groupMembers?.length){
      const members=`<button class="wx-info-member" data-action="user-avatar" aria-label="我的资料">${SocialPreview.portrait('self')}<span>${esc(state.userLabel||'我')}</span></button>`+state.chatInfo.groupMembers.map(id=>`<button class="wx-info-member" data-feature="profile" data-role="${esc(id)}">${SocialPreview.portrait(id)}<span>${esc(state.roles.find(r=>r.id===id)?.name||'角色')}</span></button>`).join('');
      const wxMembers=$('.wx-info-members');if(wxMembers)wxMembers.innerHTML=members+`<button class="wx-info-member wx-info-add" data-feature="info-add" aria-label="管理群成员">${icon('plus')}</button>`;
      const qqPerson=$('.qq-info-person strong');if(qqPerson){qqPerson.textContent=state.chatInfo.title;const top=qqPerson.closest('button');top.dataset.feature='info-add';top.setAttribute('aria-label','管理成员与设置');const manage=$('.qq-info-card [data-feature=info-add]:not(.qq-info-person)');if(manage){const name=state.chatInfo.groupKind==='channel'?'频道成员与设置':'群成员与设置';manage.setAttribute('aria-label',name);manage.querySelector('span').textContent=name}}
      if(qqPerson&&!$('.qq-group-members')){const el=document.createElement('div');el.className='qq-group-members';el.innerHTML=members;$('.qq-info-person').after(el)}
    }
    const custom=ChatInteractions.moduleMarkup(SocialPreview.page());if(custom!==null&&$('#socialPage').innerHTML!==custom){const old=$('#socialPage').scrollTop;$('#socialPage').innerHTML=custom;$('#socialPage').scrollTop=old}
    paintFavorites();
  }
  window.ChatInteractions={open,paint,moduleMarkup(page,query=''){
    if(!state)return null;
    if(page==='groups')return `<div class="interaction-list">${(state.chats||[]).filter(c=>c.groupMembers?.length&&c.groupKind!=='channel'&&c.title.toLowerCase().includes(query.toLowerCase())).map(c=>`<button data-host="select" data-id="${esc(c.id)}">${icon('users')}<span>${esc(c.title)}</span>${icon('right')}</button>`).join('')}${btn('new-group','发起群聊','plus')}</div>`;
    if(page==='channels')return `<div class="role-channels-header"><h2>我的频道</h2><p>和角色一起，聊聊感兴趣的事</p>${btn('create-channel','创建频道','plus')}</div><div class="interaction-attachment-list">${(state.chats||[]).filter(c=>c.groupKind==='channel').map(c=>`<button data-host="select" data-id="${esc(c.id)}">${icon('hash')}<span><strong>${esc(c.title)}</strong><small>${c.groupMembers.length+1} 位成员</small></span>${icon('right')}</button>`).join('')||'<p class="interaction-empty">还没有加入的角色频道</p>'}</div>`;
    if(page==='subscriptions')return '<p class="interaction-empty">暂无订阅</p>';
    if(page==='calls')return `<div class="interaction-list">${btn('voice-call','语音通话','phone')}${btn('video-call','视频通话','video')}</div>`;
    if(page==='files'||page==='albums'){
      const list=(state.attachmentIndex||[]).filter(e=>page==='files'?['file','music','audio'].includes(e.kind):['image','video'].includes(e.kind));
      const photos=page==='albums'?(state.posts||[]).flatMap(post=>(post.images||[]).map((image,i)=>`<button ${act('view-post-image',`data-post="${esc(post.id)}" data-image="${i}"`)}>${SocialPreview.artImage(image)}</button>`)):[];
      return `${photos.length?'<div class="post-album-grid">'+photos.join('')+'</div>':''}<div class="interaction-attachment-list">${list.map(e=>`<button ${act('open-attachment',`data-id="${esc(e.id)}" data-chat="${esc(e.chatId)}"`)}>${icon(e.kind==='image'?'image':e.kind==='video'?'video':e.kind==='file'?'folder':'music')}<span><strong>${esc(e.name)}</strong><small>${esc(state.roles.find(r=>r.id===e.roleId)?.name||'角色')} · ${esc(e.created.slice(0,10))}</small></span>${icon('right')}</button>`).join('')||(!photos.length?'<p class="interaction-empty">还没有'+(page==='files'?'文件':'图片或视频')+'，可从聊天“＋”中添加。</p>':'')}</div>`;
    }
    if(page==='favorites')return `<div class="interaction-attachment-list">${(state.favorites||[]).map((text,i)=>`<button ${act('show-favorite',`data-index="${i}"`)}><span>${esc(text)}</span></button>`).join('')||'<p class="interaction-empty">暂无收藏，可从聊天消息菜单添加。</p>'}</div>`;
    return null;
  },inboxPreview(chat,snapshot){
    let at=chat.lastCreated||'',preview=chat.preview||'',time=chat.time||'';
    const e=chat.localEvent;
    if(e&&e.created>at){at=e.created;preview='['+({image:'图片',audio:'语音',video:'视频',file:'文件',music:'音乐',contact:'个人名片',location:'位置'}[e.kind]||'消息')+']';time=e.created.slice(11,16)}
    const t=(snapshot.wallet?.transactions||[]).find(t=>t.chatId===chat.id&&t.created>(chat.interactionsClearedAt||'')&&!(chat.hiddenInteractions||[]).includes(t.id));
    if(t&&t.created>at){preview='['+(t.kind==='redpacket'?'红包':t.kind==='gift'?'礼物':'转账')+'] '+(t.note||'¥'+cash(t.cents));time=t.created.slice(11,16)}
    return {preview,time};
  },update(value){
    $('#phone').dataset.presenterMode=value.mode;
    const next=value.mode+':'+value.selectedId;if(context&&next!==context){endHold({cancelled:true});voiceMode=false;root.classList.remove('wx-voice-mode');close();closePanel()}context=next;state=value;
    if(value.ack==='walletInteraction'){busy=false;if(layer){if(view==='receipt'||view==='open-redpacket')receipt(detailId);else close()}}
    if(value.ack==='walletChange'&&layer){busy=false;wallet()}
    if(value.ack==='chatInteraction'){busy=false;close()}
    if(value.error){busy=false;error(value.error);layer?.querySelectorAll('button[type=submit]').forEach(b=>b.disabled=false)}
    paint();
    if(pendingOpen&&value.selectedId===pendingOpen.chatId){const item=pendingOpen;pendingOpen=null;const el=document.createElement('button');el.dataset.interaction='view-event';el.dataset.id=item.id;ChatInteractions.capture({preventDefault(){},stopImmediatePropagation(){}},el)}
  },capture(event,node){
    if(!state)return false;const a=node.dataset.interaction,base=node.dataset.action,feature=node.dataset.feature;
    const handle=()=>{event.preventDefault();event.stopImmediatePropagation()};
    if(!a){
      if(state.mode==='wx'&&['attachments','emoji','voice'].includes(base)){handle();if(base==='attachments')panelOpen('more');else if(base==='emoji')panelOpen('emoji');else {closePanel();voiceMode=!voiceMode;paint()}return true}
      if(['wallet','pay','receive','set-balance','wallet-records'].includes(feature)){handle();if(feature==='pay')finance('transfer');else if(feature==='receive')finance('transfer',true);else if(feature==='set-balance')showBalance();else if(feature==='wallet-records')ledger();else wallet();return true}
      return false;
    }
    handle();
    if(a==='voice-hold')return true;
    if(a==='back'){close();return true}
    if(a==='money-key'){
      const input=layer?.querySelector('#interactionMoneyForm [name=amount]');if(!input)return true;
      const key=node.dataset.key;
      if(key==='hide')layer.classList.remove('money-keyboard-open');
      else if(key==='submit')input.form.requestSubmit();
      else {let next=key==='back'?input.value.slice(0,-1):input.value+key;if(key==='.'&&!input.value)next='0.';if(/^\d{0,6}(\.\d{0,2})?$/.test(next)){input.value=next;input.dispatchEvent(new Event('input',{bubbles:true}))}}
      return true;
    }
    if(a==='screen-more'){const t=(state.wallet?.transactions||[]).find(t=>t.id===detailId),actions=view==='receipt'&&t?.state==='pending'&&!t.incoming?btn('receive-transaction',t.kind==='redpacket'?'模拟角色领取':'模拟角色收款','check',`data-id="${esc(t.id)}"`)+btn('refund-transaction','撤回虚拟资金','transfer',`data-id="${esc(t.id)}"`):'';show('更多',`<div class="interaction-list">${actions}${btn('wallet','钱包','wallet')}${btn('models','选择模型','sparkles')}${btn('settings','设置','settings')}</div>`,'more');return true}
    if(a==='settings'){close();SkivuHost.emit('settings');return true}
    if(a==='new-group'){close();SocialFeatures.group();return true}
    if(a==='create-channel'){close();SocialFeatures.group();const form=$('#hostGroupForm');form.dataset.kind='channel';form.querySelector('[name=title]').value='角色频道';form.querySelector('[name=title]').parentElement.firstChild.textContent='频道名称';form.querySelector('.sheet-caption').textContent='选择 2—8 位角色；频道记录独立，角色卡与原版共用。';form.querySelector('[type=submit]').textContent='创建频道';$('#sheetTitle').textContent='创建频道';return true}
    if(a==='panel-page'){const track=panel?.querySelector('.wx-tool-pages');track?.scrollTo({left:Number(node.dataset.page)*track.clientWidth,behavior:'smooth'});return true}
    if(a==='emoji'){const input=$('#messageInput');input.setRangeText(node.dataset.value||'',input.selectionStart,input.selectionEnd,'end');input.dispatchEvent(new Event('input',{bubbles:true}));return true}
    if(a==='receipt'){receipt(node.dataset.id);return true}
    if(a==='redpacket-details'){receipt(node.dataset.id,true);return true}
    if(a==='receive-transaction'||a==='refund-transaction'){if(!busy){busy=true;SkivuHost.emit('walletInteraction',{operation:a==='receive-transaction'?'receive':'refund',requestId:uid(),id:node.dataset.id})}return true}
    if(a==='incoming'||a==='incoming-redpacket'){finance(a==='incoming'?'transfer':'redpacket',true);return true}
    if(a==='balance'){showBalance();return true}
    if(a==='gift'){finance('gift',false,{name:node.dataset.name,cents:Number(node.dataset.cents)});return true}
    if(a==='open-attachment'){pendingOpen={id:node.dataset.id,chatId:node.dataset.chat};SkivuHost.emit('selectChat',{id:node.dataset.chat});return true}
    if(a==='show-favorite'){show('收藏内容',`<p>${esc(state.favorites[Number(node.dataset.index)]||'')}</p>`,'favorite');return true}
    if(a==='view-post-image'){const image=state.posts.find(p=>p.id===node.dataset.post)?.images?.[Number(node.dataset.image)];if(image)show('照片',`<div class="post-album-preview">${SocialPreview.artImage(image)}</div>`,'photo');return true}
    if(a==='share-contact'){const r=state.roles.find(r=>r.id===node.dataset.role);if(r)append('contact',{roleId:r.id,name:r.name});return true}
    if(a==='use-favorite'){const text=state.favorites[Number(node.dataset.index)];if(typeof text==='string'){$('#messageInput').value=text;$('#messageInput').dispatchEvent(new Event('input',{bubbles:true}));close();$('#messageInput').focus()}return true}
    if(a==='send-preview'){const pending=layer?._pending;if(pending)append(pending.kind,pending.payload);return true}
    if(a==='view-event'){const e=events().find(e=>e.id===node.dataset.id);if(e){const p=e.payload;if(e.kind==='contact'){close();SocialPreview.showRole(p.roleId)}else if(e.kind==='file'){
      const bytes=Uint8Array.from(atob(p.data.split(',')[1]),c=>c.charCodeAt(0)),url=URL.createObjectURL(new Blob([bytes],{type:'application/octet-stream'}));downloadUrls.push(url);
      const preview=/\.txt$/i.test(p.name)&&bytes.length<200000?`<pre class="file-text-preview">${esc(new TextDecoder().decode(bytes))}</pre>`:'';
      show(p.name,`<p>${esc(p.name)}</p>${preview}<a class="interaction-primary" href="${esc(url)}" download="${esc(p.name)}">保存文件</a>`,'event-detail');
    }else show(p.name||p.label,e.kind==='image'?`<img class="interaction-image-preview" src="${esc(p.data)}" alt="${esc(p.name)}">`:`<div class="location-map">${icon('pin')}</div><h3>${esc(p.label)}</h3><p>${esc(p.address)}</p>`,'event-detail')}return true}
    if(a==='event-menu'){show('删除这条消息？',`<p>只从当前聊天移除，钱包账单不受影响。</p>${btn('confirm-hide','确认删除','close',`data-id="${esc(node.dataset.id)}" class="interaction-delete"`)}`,'event-menu');return true}
    if(a==='confirm-hide'){SkivuHost.emit('hideInteraction',{id:node.dataset.id});close();return true}
    if(a==='native-call'){close();SkivuHost.emit('call');return true}
    if(['start-camera','start-screen','take-photo','start-record','stop-record','send-record'].includes(a)){mediaAction(a).catch(e=>error(e.name==='NotAllowedError'?'未授权设备访问，可返回后重新选择。':'此设备不支持该操作或媒体无法读取。'));return true}
    open(a);return true;
  }};
  function showBalance(){show('零钱',`<form id="interactionBalanceForm" class="interaction-form"><label>虚拟零钱余额<input name="amount" aria-label="虚拟零钱余额" value="${cash(state.wallet?.balanceCents)}" inputmode="decimal" required></label>${instructions}<button type="submit" class="interaction-primary">保存</button><p class="interaction-error" role="alert" hidden></p></form>`,'balance')}
  async function beginHold(event){
    if(window.SKIVU_HOSTED){event.preventDefault();SkivuHost.emit('composeMedia',{kind:'voice',real:true});return;}
    if(event.button!==0||hold)return;event.preventDefault();event.currentTarget.setPointerCapture(event.pointerId);
    const item={active:true,cancelled:false,context,y:event.clientY,chunks:[],started:0};hold=item;
    try {
      const stream=await navigator.mediaDevices.getUserMedia({audio:true});item.stream=stream;
      if(!item.active||item.context!==context){stream.getTracks().forEach(t=>t.stop());return}
      const active=new MediaRecorder(stream);item.recorder=active;item.started=Date.now();
      active.ondataavailable=e=>{if(e.data.size)item.chunks.push(e.data)};
      active.onstop=async()=>{
        stream.getTracks().forEach(t=>t.stop());if(item.cancelled||item.context!==context||Date.now()-item.started<300)return;
        const blob=new Blob(item.chunks,{type:active.mimeType.split(';')[0]});if(blob.size>2*1024*1024){toast('录音超过 2MB，请缩短后重试');return}
        const data=await new Promise(resolve=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.readAsDataURL(blob)});
        if(item.context===context)append('audio',{data,name:'语音 '+Math.max(1,Math.round((Date.now()-item.started)/1000))+'秒'});
      };
      active.start();const hud=document.createElement('div');hud.className='voice-hold-hud';hud.innerHTML=icon('mic')+'<span>松开发送，上滑取消</span>';$('#phone').append(hud);item.hud=hud;
      item.timer=setTimeout(()=>endHold({}),60000);
    }catch(e){toast(e.name==='NotAllowedError'?'未开启麦克风权限':'此设备暂不支持录音');endHold({cancelled:true})}
  }
  function moveHold(event){if(!hold)return;hold.cancelled=hold.y-event.clientY>55;if(hold.hud){hold.hud.classList.toggle('cancelled',hold.cancelled);hold.hud.querySelector('span').textContent=hold.cancelled?'松开取消':'松开发送，上滑取消'}}
  function endHold(event){if(!hold)return;const item=hold;hold=null;item.active=false;item.cancelled=item.cancelled||event.cancelled===true;clearTimeout(item.timer);item.hud?.remove();if(item.recorder?.state==='recording')item.recorder.stop();else item.stream?.getTracks().forEach(t=>t.stop())}
  async function mediaAction(action){
    if(action==='start-camera'||action==='start-screen'){
      stopMedia();const source=layer,revision=screenRevision;
      const stream=action==='start-screen'?await navigator.mediaDevices.getDisplayMedia({video:true,audio:false}):await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'},audio:false});
      if(layer!==source||revision!==screenRevision){stream.getTracks().forEach(t=>t.stop());return}mediaStream=stream;$('#interactionCamera').srcObject=stream;return;
    }
    if(action==='take-photo'){
      const video=$('#interactionCamera');if(!video?.videoWidth){error('请先打开摄像头');return}const c=document.createElement('canvas');c.width=800;c.height=Math.round(video.videoHeight/video.videoWidth*800);c.getContext('2d').drawImage(video,0,0,c.width,c.height);const data=c.toDataURL('image/jpeg',.78);show('发送照片',`<img class="interaction-image-preview" src="${data}" alt="照片预览">${btn('send-preview','发送',null,'class="interaction-primary"')}`,'file-preview');layer._pending={kind:'image',payload:{data,name:'照片.jpg'}};return;
    }
    if(action==='start-record'){
      stopMedia();const source=layer,revision=screenRevision;const stream=await navigator.mediaDevices.getUserMedia({audio:true});if(layer!==source||revision!==screenRevision){stream.getTracks().forEach(t=>t.stop());return}mediaStream=stream;recorder=new MediaRecorder(stream);const active=recorder,chunks=[];
      active.ondataavailable=e=>{if(e.data.size)chunks.push(e.data)};active.onstop=async()=>{stream.getTracks().forEach(t=>t.stop());if(layer!==source||revision!==screenRevision)return;const blob=new Blob(chunks,{type:active.mimeType.split(';')[0]});if(blob.size>2*1024*1024){error('录音超过 2MB，请缩短后重试');return}const data=await new Promise(resolve=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.readAsDataURL(blob)});if(layer!==source||revision!==screenRevision)return;layer._record={data,name:'语音消息'};$('#voicePlayback').src=data;$('#voicePlayback').hidden=false;$('#voiceStatus').textContent='录音已结束，可试听后发送'};active.start();$('#voiceStatus').textContent='正在录音，最长 60 秒';recordTimer=setTimeout(()=>mediaAction('stop-record'),60000);return;
    }
    if(action==='stop-record'){clearTimeout(recordTimer);if(recorder?.state==='recording')recorder.stop();return}
    if(action==='send-record'){if(layer?._record)append('audio',layer._record);else error('请先完成录音');}
  }
  document.addEventListener('submit',event=>{
    const form=event.target;if(!['interactionMoneyForm','interactionBalanceForm','interactionLocationForm'].includes(form.id))return;event.preventDefault();event.stopImmediatePropagation();if(busy)return;
    const data=new FormData(form);
    if(form.id==='interactionLocationForm'){append('location',{label:String(data.get('label')||''),address:String(data.get('address')||'')});return}
    const cents=parse(String(data.get('amount')||''));if(cents===null||(form.id==='interactionMoneyForm'&&cents===0)){error('请输入有效金额，最多两位小数');return}
    busy=true;form.querySelector('[type=submit]').disabled=true;
    if(form.id==='interactionBalanceForm')SkivuHost.emit('walletChange',{operation:'set',requestId:uid(),cents});
    else SkivuHost.emit('walletInteraction',{operation:'create',requestId:form.dataset.request,kind:form.dataset.kind,cents,note:String(data.get('note')|| (form.dataset.kind==='redpacket'?'恭喜发财，大吉大利':'')),incoming:form.dataset.incoming==='true',cover:String(data.get('cover')||'classic')});
  },true);
  document.addEventListener('input',event=>{if(event.target.id==='messageInput')paint();if(event.target.name==='amount'&&$('#redpacketTotal'))$('#redpacketTotal').textContent=cash(parse(event.target.value)||0)});
  document.addEventListener('focusin',event=>{if(event.target.id==='messageInput'&&state?.mode==='wx')closePanel();if(event.target.closest('#interactionMoneyForm')&&event.target.name==='amount'&&!event.target.readOnly)layer?.classList.add('money-keyboard-open')});
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&(layer||panel)){event.preventDefault();event.stopImmediatePropagation();if(layer?.classList.contains('money-keyboard-open'))layer.classList.remove('money-keyboard-open');else if(layer)close();else closePanel()}},true);
  addEventListener('pagehide',()=>{endHold({cancelled:true});stopMedia();downloadUrls.forEach(url=>URL.revokeObjectURL(url))});
})();
