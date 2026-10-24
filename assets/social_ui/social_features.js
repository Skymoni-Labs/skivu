/* Original Skivu virtual-wallet and WeChat menu presentation. */
(() => {
  let state=null,plus=null,infoScroll=0,historyQuery='';
  ICONS['bell-off']='<path d="M5 17h14l-2-3V9a5 5 0 0 0-8-4M7 9v5l-2 3M10 21h4M3 3l18 18"/>';
  const act=(action,label,extra='')=>`data-feature="${action}" aria-label="${esc(label)}" ${extra}`;
  const money=cents=>(Number(cents||0)/100).toFixed(2);
  const roles=()=>state?.roles||[];
  const wallet=()=>state?.wallet||{balanceCents:0,entries:[]};
  const row=(label,action,ico='right')=>`<button class="wx-wallet-row" ${act(action,label)}><span>${esc(label)}</span>${icon(ico)}</button>`;
  const portrait=id=>SocialPreview.portrait(id);
  const currentRole=()=>roles().find(r=>r.id===state?.selectedRoleId);
  const infoRow=(label,action)=>`<button class="wx-info-row" ${act(action,label)}><span>${label}</span>${icon('right')}</button>`;
  const infoToggle=(label,key)=>`<div class="wx-info-row"><span>${label}</span><button class="wx-info-switch" role="switch" aria-checked="${!!state?.chatInfo?.[key]}" ${act('info-toggle',label,`data-key="${key}"`)}><i></i></button></div>`;
  const go=page=>{closePlus();closeSheet();SocialPreview.go(page)};
  function qrImage(text){const qr=qrcode(0,'M');qr.addData(text);qr.make();return qr.createImgTag(5,20,'Skivu 虚拟收款码')}
  function closePlus(){plus?.remove();plus=null;document.querySelector('#socialTopAction')?.setAttribute('aria-expanded','false')}
  function showPlus(){
    if(plus){closePlus();return}
    plus=document.createElement('div');plus.className='wx-plus-layer';
    plus.innerHTML=`<button class="wx-plus-dismiss" aria-label="关闭添加菜单" data-feature="close-plus"></button><div class="wx-plus-menu" role="menu">${[['group','发起群聊','users'],['friends','添加朋友','user'],['scan','扫一扫','qr'],['cashier','收付款','wallet'],['classic','回到原版','cloud']].map(([a,label,ico])=>`<button role="menuitem" ${act(a,label)}>${icon(ico)}<span>${label}</span></button>`).join('')}</div>`;
    $('#phone').append(plus);$('#socialTopAction').setAttribute('aria-expanded','true');
  }
  function friends(){closePlus();showSheet('添加朋友',`<div class="feature-friend-search"><label>搜索角色<input id="hostFriendSearch" placeholder="角色名称" autocomplete="off"></label></div><div id="hostFriendResults">${friendRows('')}</div><button class="sheet-item" data-feature="create-role">${icon('plus')}创建新角色</button>`)}
  function friendRows(filter){return roles().filter(r=>r.name.toLowerCase().includes(filter.toLowerCase())).map(r=>`<button class="social-contact-row" ${act('profile','查看 '+r.name,`data-role="${esc(r.id)}"`)}>${portrait(r.id)}<strong>${esc(r.name)}</strong>${icon('right')}</button>`).join('')||'<p class="sheet-caption">没有找到角色</p>'}
  function group(initial=[],editCurrent=false){closePlus();const editing=editCurrent&&!!state?.chatInfo?.groupMembers?.length,selected=editing?state.chatInfo.groupMembers:[...initial,...(state?.groupDefaults?.groupMembers||[])],config=editing?state.chatInfo:state.groupDefaults;showSheet(editing?'群聊成员与设置':'发起群聊',`<form id="hostGroupForm" class="social-form" data-edit="${editing}" data-kind="${editing?state.chatInfo.groupKind||'group':'group'}"><label>群名称<input name="title" required maxlength="60" value="${editing?esc(state.chatInfo.title):'角色群聊'}"></label><p class="sheet-caption">选择 2—8 位角色；群聊记录独立，角色卡与原版共用。</p>${roles().map(r=>`<label class="social-selection-row">${portrait(r.id)}${esc(r.name)}<input type="checkbox" name="members" value="${esc(r.id)}" ${selected.includes(r.id)?'checked':''}></label>`).join('')}<label>回复规则<select name="rule">${[['manual','首位成员回复，可用 @ 指定'],['mentions','仅回应 @ 的成员'],['roundRobin','按成员顺序轮流'],['automatic','优先回应 @ 提及，否则轮流']].map(([key,label])=>`<option value="${key}" ${config?.groupRule===key?'selected':''}>${label}</option>`).join('')}</select></label><label>每轮最多回复<select name="limit">${[1,2,3,4,5,6].map(n=>`<option value="${n}" ${config?.groupMaxReplies===n?'selected':''}>${n} 位成员</option>`).join('')}</select></label><p class="sheet-caption">每位回复成员使用一次模型请求，仅发送本群上下文。</p><button type="submit" class="social-primary">${editing?'保存':'创建群聊'}</button></form>`)}
  function historyRows(query=''){
    const q=query.trim().toLowerCase();if(!q)return '<div class="social-search-empty">搜索这段对话中的文字</div>';
    return (state?.messages||[]).map((m,index)=>({m,index})).filter(({m})=>m.text?.toLowerCase().includes(q)).map(({m,index})=>{
      const at=m.text.toLowerCase().indexOf(q),start=Math.max(0,at-18);
      return `<button class="wx-history-row" ${act('history-result','查看聊天记录',`data-index="${index}"`)}><strong>${esc(m.role==='user'?state.userLabel:currentRole()?.name||'角色')}<time>${esc(m.time||'')}</time></strong><span>${start?'…':''}${esc(m.text.slice(start,start+110))}</span></button>`;
    }).join('')||'<div class="social-search-empty">没有找到相关聊天记录</div>';
  }
  function showChatInfo(){infoScroll=$('#messages').scrollTop;go('chat-info')}
  function backFromInfo(){SocialPreview.back();requestAnimationFrame(()=>{$('#messages').scrollTop=infoScroll})}
  function walletForm(operation,roleId=''){
    closePlus();const title=operation==='set'?'设置虚拟零钱':operation==='pay'?'向角色付款':'模拟角色收款';
    showSheet(title,`<form id="hostWalletForm" class="social-form" data-operation="${operation}" data-request="${crypto.randomUUID?.()||'wallet-'+Date.now()+'-'+Math.random()}">
      ${operation!=='set'?`<label>${operation==='pay'?'付款给':'收款角色'}<select name="roleId" required>${roles().map(r=>`<option value="${esc(r.id)}" ${r.id===roleId?'selected':''}>${esc(r.name)}</option>`).join('')}</select></label>`:''}
      <label>${operation==='set'?'零钱余额':'虚拟金额'}<input name="amount" inputmode="decimal" placeholder="0.00" value="${operation==='set'?money(wallet().balanceCents):''}" maxlength="9" required autocomplete="off"></label>
      <label>备注<input name="note" maxlength="100" placeholder="选填"></label><p class="sheet-caption">角色互动虚拟钱包 · ${operation==='pay'?'付款将扣减虚拟零钱并记录明细':operation==='receive'?'收款将增加虚拟零钱并记录明细':'设置后保存在此设备'}</p>
      <button type="submit" class="social-primary">${operation==='set'?'保存余额':operation==='pay'?'确认虚拟付款':'确认模拟收款'}</button></form>`);
  }
  function parseAmount(raw){const text=raw.trim();if(!/^(0|[1-9]\d{0,5})(\.\d{1,2})?$/.test(text))return null;const [whole,part='']=text.split('.');return Number(whole)*100+Number(part.padEnd(2,'0'))}
  function decodeText(text){
    if(typeof text!=='string'||text.length>500){toast('二维码内容不受支持');return}
    let uri;try{uri=new URL(text)}catch{toast('请使用 Skivu 角色码或虚拟钱包码');return}
    let id;try{id=decodeURIComponent(uri.pathname.slice(1))}catch{toast('二维码内容不正确');return}
    if(uri.protocol!=='skivu:'||uri.search||uri.hash||uri.username||uri.password){toast('仅支持 Skivu 角色码和虚拟钱包码');return}
    if(uri.hostname==='role'&&roles().some(r=>r.id===id)){closeSheet();SocialPreview.showRole(id);return}
    if(uri.hostname==='virtual-wallet'&&id===wallet().id){go('cashier');toast('这是你的虚拟收款码');return}
    toast('此二维码未对应本机角色或虚拟钱包');
  }
  async function scanImage(file){
    if(!file)return;
    if(!['image/png','image/jpeg','image/webp'].includes(file.type)||file.size>5*1024*1024){toast('请选择 5MB 以内的 PNG、JPG 或 WebP 图片');return}
    const image=new Image();const url=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=reject;reader.readAsDataURL(file)});
    try {
      await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=reject;image.src=url});
      if(image.width>8192||image.height>8192)throw new Error('size');
      const scale=Math.min(1,1600/Math.max(image.width,image.height));
      const canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(image.width*scale));canvas.height=Math.max(1,Math.round(image.height*scale));
      const ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.drawImage(image,0,0,canvas.width,canvas.height);
      const pixels=ctx.getImageData(0,0,canvas.width,canvas.height),result=jsQR(pixels.data,pixels.width,pixels.height);
      if(result)decodeText(result.data);else toast('没有识别到二维码，请使用清晰、完整的图片');
    }catch{toast('图片无法识别，请换一张图片')}
    finally{image.src=''}
  }
  window.SocialFeatures={
    update(value,update){state=value;if(update.error){const button=document.querySelector('#hostWalletForm button[type=submit]');if(button)button.disabled=false}if(update.ack==='walletChange'){closeSheet();toast('虚拟钱包已保存')}},
    chatInfo:()=>state?.mode==='qq'?`<div class="qq-info-card"><button class="qq-info-person" ${act('profile','查看角色资料',`data-role="${esc(state?.selectedRoleId||'')}"`)}>${portrait(state?.selectedRoleId)}<strong>${esc(currentRole()?.name||'角色')}</strong>${icon('right')}</button>${infoRow('发起群聊','info-add')}</div><div class="qq-info-card">${infoRow('查找聊天记录','chat-search')}</div><div class="qq-info-card">${infoToggle('设为置顶','pinned')}${infoToggle('特别关心','replyReminder')}${infoToggle('消息免打扰','muted')}${infoToggle('确认后再回复','confirmBeforeReply')}</div><div class="qq-info-card">${infoRow('自定义背景','info-background')}${infoRow('聊天气泡','info-bubbles')}</div><div class="qq-info-card">${infoRow('清空聊天记录','info-clear')}</div>`:`<div class="wx-info-members"><button class="wx-info-member" ${act('profile','查看角色资料',`data-role="${esc(state?.selectedRoleId||'')}"`)}>${portrait(state?.selectedRoleId)}<span>${esc(currentRole()?.name||'角色')}</span></button><button class="wx-info-member wx-info-add" ${act('info-add','添加聊天成员')}>${icon('plus')}</button></div><div class="wx-info-group">${infoRow('查找聊天记录','chat-search')}</div><div class="wx-info-group">${infoToggle('消息免打扰','muted')}${infoToggle('确认后再回复','confirmBeforeReply')}${infoToggle('置顶聊天','pinned')}${infoToggle('提醒','replyReminder')}</div><div class="wx-info-group">${infoRow('自定义背景','info-background')}${infoRow('聊天气泡','info-bubbles')}</div><div class="wx-info-group">${infoRow('清空聊天记录','info-clear')}</div><div class="wx-info-group">${infoRow('投诉','info-report')}</div>`,
    chatSearch:()=>`<label class="social-search">${icon('search')}<input id="hostChatHistorySearch" aria-label="搜索聊天记录" placeholder="搜索聊天记录" value="${esc(historyQuery)}" autocomplete="off"></label><div id="hostChatHistoryResults">${historyRows(historyQuery)}</div>`,
    services:()=>`<div class="wx-services-wallet"><button ${act('wallet','钱包')}>${icon('wallet')}<strong>钱包</strong><span>¥ ${money(wallet().balanceCents)}</span></button></div><p class="feature-note">角色互动虚拟钱包</p>`,
    wallet:()=>`<div class="wx-wallet-head">${icon('wallet')}<h2>零钱</h2><div class="wx-wallet-amount">¥ ${money(wallet().balanceCents)}</div><p>角色互动虚拟零钱</p></div><div class="social-group">${row('零钱明细','wallet-records')}${row('收付款','cashier')}${row('设置虚拟零钱','set-balance')}</div>`,
    records:()=>`<div class="wx-ledger">${(wallet().entries||[]).map(e=>`<article><span><strong>${esc(e.kind==='set'?'余额调整':(e.cents<0?'付款给 ':'收到 ')+(roles().find(r=>r.id===e.roleId)?.name||e.roleName||'角色'))}</strong><small>${esc(e.created.replace('T',' ').slice(0,16))}${e.note?' · '+esc(e.note):''}</small></span><b class="${e.cents>0?'income':''}">${e.cents>0?'+':'−'}${money(Math.abs(e.cents))}</b></article>`).join('')||'<p class="social-search-empty">暂无收支记录</p>'}</div><p class="feature-note">仅记录角色互动中的虚拟收支</p>`,
    cashier:()=>`<div class="wx-cashier-card"><h2>二维码收款</h2><div class="wx-wallet-qr">${qrImage('skivu://virtual-wallet/'+wallet().id)}</div><p>${esc(state?.userLabel||'我')}的虚拟收款码</p></div><div class="social-group">${row('向角色付款','pay')}${row('模拟角色收款','receive')}${row('零钱明细','wallet-records')}</div><p class="feature-note">角色互动虚拟钱包</p>`,
    scan:()=>`<div class="wx-scan-view"><div class="wx-scan-frame">${icon('qr')}</div><p>识别 Skivu 角色码和虚拟钱包码</p><button class="social-primary" ${act('scan-file','拍照或从相册选择二维码')}>拍照或从相册选择二维码</button><button class="wx-scan-text" ${act('scan-text','输入二维码内容')}>输入二维码内容</button></div>`,
    capture(event,node){
      const a=node.dataset.feature;
      if(!a)return false;
      event.preventDefault();event.stopImmediatePropagation();
      if(a==='close-plus')closePlus();
      else if(a==='plus')showPlus();
      else if(a==='friends')friends();
      else if(a==='group')group();
      else if(a==='info-add')group([state.selectedRoleId],true);
      else if(a==='info-toggle'){
        const key=node.dataset.key,value=!state.chatInfo?.[key];
        if(key==='replyReminder'&&value)showSheet('提醒',`<p class="sheet-caption">开启后，当前对话收到完整回复时会在应用内显示提示。</p><button class="sheet-item" ${act('approve-reminder','开启提醒',`data-chat="${esc(state.selectedId)}"`)}>开启提醒</button>`);
        else SkivuHost.emit('chatOptions',{key,value});
      }
      else if(a==='approve-reminder'){SkivuHost.emit('chatOptions',{key:'replyReminder',value:true,chatId:node.dataset.chat});closeSheet()}
      else if(a==='info-background'||a==='info-bubbles')SkivuHost.emit('chatAppearance',{section:a==='info-background'?'background':'bubbles'});
      else if(a==='info-clear')SkivuHost.emit('clearChat');
      else if(a==='info-report')showSheet('投诉','<p class="sheet-caption">投诉服务即将开放。</p>');
      else if(a==='history-result')SocialPreview.locate(Number(node.dataset.index));
      else if(a==='classic'){closePlus();SkivuHost.emit('classicUi')}
      else if(a==='profile'){closeSheet();SocialPreview.showRole(node.dataset.role)}
      else if(a==='create-role'){closeSheet();SkivuHost.emit('roles')}
      else if(a==='set-balance')walletForm('set');
      else if(a==='pay'||a==='receive')walletForm(a);
      else if(a==='scan-file')$('#hostScanFile').click();
      else if(a==='scan-text')showSheet('输入二维码内容','<form id="hostScanForm" class="social-form"><label>Skivu 二维码内容<input name="code" required maxlength="500" placeholder="skivu://role/…"></label><button type="submit" class="social-primary">识别</button></form>');
      else if(a==='chat-search'){historyQuery='';go(a)}
      else if(['wallet','wallet-records','cashier','scan'].includes(a))go(a);
      return true;
    },showPlus,friends,group,showChatInfo,backFromInfo,
  };
  document.addEventListener('input',e=>{if(e.target.id==='hostFriendSearch')$('#hostFriendResults').innerHTML=friendRows(e.target.value);if(e.target.id==='hostChatHistorySearch'){historyQuery=e.target.value;$('#hostChatHistoryResults').innerHTML=historyRows(historyQuery)}});
  document.addEventListener('submit',e=>{
    const form=e.target;if(!['hostWalletForm','hostGroupForm','hostScanForm'].includes(form.id))return;
    e.preventDefault();e.stopImmediatePropagation();const values=new FormData(form);
    if(form.id==='hostScanForm'){decodeText(String(values.get('code')||'').trim());return}
    if(form.id==='hostGroupForm'){const members=values.getAll('members');if(members.length<2||members.length>8){toast('请选择 2—8 位角色');return}form.querySelector('[type=submit]').disabled=true;SkivuHost.emit(form.dataset.edit==='true'?'groupConfig':'createGroup',{members,title:String(values.get('title')||''),rule:String(values.get('rule')||'manual'),maxReplies:Number(values.get('limit')||1),kind:form.dataset.kind||'group'});return}
    const cents=parseAmount(String(values.get('amount')||''));
    if(cents===null||(form.dataset.operation!=='set'&&cents===0)){toast('请输入有效金额，最多两位小数');return}
    form.querySelector('button[type=submit]').disabled=true;
    SkivuHost.emit('walletChange',{operation:form.dataset.operation,cents,requestId:form.dataset.request,roleId:String(values.get('roleId')||''),note:String(values.get('note')||'')});
  },true);
  const picker=document.createElement('input');picker.id='hostScanFile';picker.type='file';picker.accept='image/png,image/jpeg,image/webp';picker.setAttribute('capture','environment');picker.hidden=true;
  picker.addEventListener('change',()=>{scanImage(picker.files[0]);picker.value=''});document.body.append(picker);
  document.addEventListener('keydown',e=>{if(e.key==='Escape')closePlus()});
  document.addEventListener('click',e=>{const node=e.target.closest('[data-feature]');if(node&&!window.SKIVU_HOSTED)SocialFeatures.capture(e,node)},true);
  SocialPreview.sync();
})();
