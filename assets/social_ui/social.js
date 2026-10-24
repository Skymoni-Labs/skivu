/* Original local-only social prototype. No account, model or social network API. */
(() => {
  'use strict';
  const STORE = 'skivu.social-demo.v2';
  const freshContacts = [
    {id:'ski',name:'ski',color:'#a4b5a4',hair:'#465958',shirt:'#819f96',bio:'慢慢来，也是一种很好的节奏。',tag:'特别关心',group:'我的朋友',unread:2,pinned:true,time:'09:38',snippet:'今天有没有哪一刻，让你觉得还不错？'},
    {id:'xia',name:'许知夏',color:'#d9c8b7',hair:'#6d5147',shirt:'#b69b87',bio:'收集日落，也收集生活里的小事。',tag:'',group:'我的朋友',unread:1,time:'09:21',snippet:'刚看到一片很好看的云，想分享给你。'},
    {id:'weekend',name:'周末去哪里',groupChat:true,color:'#c7d9d1',bio:'四个人，和许多个还没出发的周末。',group:'群聊',unread:3,time:'08:56',snippet:'林羽：那就周六见！'},
    {id:'lin',name:'林羽',color:'#bcc8d9',hair:'#3e4a61',shirt:'#8b9db7',bio:'有空一起听歌。',tag:'',group:'我的朋友',unread:0,time:'昨天',snippet:'分享了一首最近单曲循环的歌。'},
    {id:'cheng',name:'程野',color:'#d8cbb3',hair:'#4e4b42',shirt:'#8b9580',bio:'比起目的地，更喜欢路上。',tag:'',group:'我的朋友',unread:0,time:'昨天',snippet:'下次一起去走走。'},
    {id:'book',name:'林间书店',color:'#bbcbb4',official:true,bio:'让生活慢下来的一间小书店。',group:'订阅',unread:0,time:'周三',snippet:'本周书单｜在书页之间，留一点空白。'}
  ];
  const freshPosts = [
    {id:'p1',author:'xia',text:'把今天的好天气存下来。\n云慢慢走，我也慢慢走。',images:['coast','flowers','clouds'],time:'10分钟前',location:'沿河步道',likes:['lin','cheng'],comments:[{name:'林羽',text:'这光线也太好看了。'},{name:'许知夏',text:'下次一起走走呀。'}]},
    {id:'p2',author:'lin',text:'咖啡、旧书，还有一个不用赶路的下午。',images:['coffee'],time:'38分钟前',location:'林间书店',likes:['xia'],comments:[]},
    {id:'p3',author:'cheng',text:'走过的路不会白走，今天也是。',images:['mountain','sunset'],time:'1小时前',likes:[],comments:[{name:'ski',text:'想看看沿途的风景。'}]}
  ];
  function initialData() {
    return {
      contacts:structuredClone(freshContacts),
      threads:{ski:structuredClone(seed).map((m,i)=>({...m,time:['09:33','09:34','09:36','09:37','09:38'][i]})),xia:[{id:101,role:'assistant',text:'刚看到一片很好看的云，想分享给你。',time:'09:21'}],lin:[{id:102,role:'assistant',text:'这首歌很适合今天。等你有空，我们一起听。',time:'昨天'}],cheng:[{id:103,role:'assistant',text:'下次一起去走走吧。',time:'昨天'}],weekend:[{id:104,role:'assistant',text:'林羽：那就周六见！\n\n许知夏：好呀，我带相机。',time:'08:56'}],book:[{id:105,role:'assistant',text:'本周书单｜在书页之间，留一点空白。\n\n营业时间 10:00—20:00。',time:'周三'}]},
      posts:structuredClone(freshPosts),profile:{name:'小屿',account:'skivu_island',bio:'生活很慢，喜欢的事要慢慢来。',city:'杭州'},
      requests:[{id:'ning',name:'宁宁',color:'#d6c4ce',hair:'#5c4859',shirt:'#b793ab',bio:'我是宁宁，很高兴认识你。',accepted:false}],
      favorites:[],lastPage:'inbox',active:'ski',notifications:true,quiet:false
    };
  }
  let data=initialData();
  try {
    const raw=window.SKIVU_HOSTED?null:JSON.parse(localStorage.getItem(STORE)||'null');
    if(raw&&Array.isArray(raw.contacts)&&raw.contacts.length&&raw.contacts.length<100&&raw.threads&&Array.isArray(raw.posts)&&raw.posts.length<101&&raw.profile) data={...data,...raw};
  } catch {}
  const routeNames=new Set(['inbox','contacts','discover','moments','me','contact','requests','groups','calls','favorites','albums','settings','compose','search','call','miniapps','subscriptions','files','services','wallet','wallet-records','cashier','scan','chat-info','chat-search']);
  const routeParam=new URLSearchParams(location.search).get('screen');
  let page=routeParam==='chat'?'chat':routeNames.has(routeParam)?routeParam:'inbox';
  let active=data.contacts.some(c=>c.id===data.active)?data.active:'ski';
  let trail=[],searchQuery='',contactFilter='friends',draftText='',draftImages=[],callStarted=0,callTimer=null,uploadTarget='post';
  const artKeys=['coast','flowers','clouds','coffee','mountain','sunset'];
  const findContact=id=>data.contacts.find(c=>c.id===id)||(window.SKIVU_HOSTED?{id,name:'已删除角色',color:'#b9c5ca'}:freshContacts[0]);
  const person=id=>id==='self'?{id:'self',name:data.profile.name,color:'#b2c8c6',hair:'#4d6e6a',shirt:'#749b9b',avatar:data.profile.avatar}:findContact(id);
  const current=()=>findContact(active);
  const getName=id=>person(id).name;
  const hi=icon;
  let nativeView=state.nativeView!==false;
  let postMenu=null;
  ICONS.wallet='<rect x="3" y="5" width="18" height="15" rx="2"/><path d="M15 10h6v6h-6Z"/>';
  ICONS.shop='<path d="M3 9h18l-2-5H5L3 9ZM4 10v11h16V10M9 21v-8h6v8"/>';
  ICONS.heart='<path d="M20.8 5.6a5.3 5.3 0 0 0-7.4 0L12 7l-1.4-1.4a5.3 5.3 0 0 0-7.4 7.5L12 22l8.8-8.9a5.3 5.3 0 0 0 0-7.5Z"/>';
  ICONS.book='<path d="M3 4h7l2 2 2-2h7v16h-7l-2 2-2-2H3V4ZM12 6v16"/>';
  ICONS.camera='<rect x="3" y="6" width="18" height="15" rx="3"/><path d="m7 6 2-3h6l2 3"/><circle cx="12" cy="13" r="4"/>';
  ICONS.compass='<circle cx="12" cy="12" r="9"/><path d="m16 8-3 5-5 3 3-5 5-3Z"/>';
  ICONS.pin='<path d="M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 0 1 14 0Z"/><circle cx="12" cy="10" r="2"/>';
  ICONS.star='<path d="m12 3 2.8 5.7 6.2.9-4.5 4.4 1 6.2-5.5-2.9-5.5 2.9 1-6.2L3 9.6l6.2-.9L12 3Z"/>';
  ICONS.bell='<path d="M5 17h14l-2-3V9A5 5 0 0 0 7 9v5l-2 3ZM10 21h4M12 3v1"/>';
  ICONS.music='<path d="M9 18V5l11-2v13M9 8l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/>';
  ICONS.video='<rect x="3" y="5" width="12" height="14" rx="3"/><path d="m15 10 6-4v12l-6-4"/>';
  ICONS.qr='<path d="M3 3h6v6H3ZM15 3h6v6h-6ZM3 15h6v6H3ZM15 15h2v2h-2ZM20 15v6h-5M12 3v3M3 12h3M12 10v5M11 20v1"/>';
  function keep(){if(window.SKIVU_HOSTED){try{const prior=JSON.parse(localStorage.getItem('skivu.host.social.v1')||'{}');localStorage.setItem('skivu.host.social.v1',JSON.stringify({...((Array.isArray(prior.posts)&&prior.posts.length)?{posts:prior.posts}:{}),profile:data.profile}))}catch{}return}try{localStorage.setItem(STORE,JSON.stringify(data))}catch{toast('本地存储已满，新增内容暂只保留在当前页面')}}
  function flushThread(){
    if(window.SKIVU_HOSTED)return;
    if(!data.threads[active])data.threads[active]=[];
    data.threads[active]=structuredClone(messages);
    if(state.mode!=='skivu'&&state.role){current().name=state.role;current().avatar=state.avatar||null;}
    const last=messages.at(-1);if(last&&last.text){current().snippet=last.text.replace(/\s+/g,' ').slice(0,90);current().time=last.time||'刚刚'}
    data.active=active;keep();
  }
  function portrait(id,sizeClass='') {
    const p=person(id);
    if(p.avatar)return `<span class="social-face ${sizeClass}"><img src="${esc(p.avatar)}" alt="${esc(p.name)}"></span>`;
    if(window.SKIVU_HOSTED&&p.glyph)return `<span class="social-face ${sizeClass}" style="background:${p.color}1f"><span class="host-role-icon" aria-hidden="true">${esc(p.glyph)}</span></span>`;
    if(p.groupChat)return `<span class="social-face is-group ${sizeClass}"><span>屿</span><span>夏</span><span>羽</span><span>野</span></span>`;
    if(p.official)return `<span class="social-face ${sizeClass}" style="--face-color:#9cb69e"><svg viewBox="0 0 48 48" aria-hidden="true"><rect width="48" height="48" fill="#b1c9b2"/><path d="M10 13h13l2 3h13v22H10Z" fill="#f1eee2"/><path d="M24 17v21M14 20h6M14 24h6M29 21h5M29 25h5" fill="none" stroke="#7c9c80" stroke-width="1.7"/></svg></span>`;
    return `<span class="social-face ${sizeClass}" style="--face-color:${p.color||'#bdd5da'}"><svg viewBox="0 0 48 48" aria-hidden="true"><rect width="48" height="48" fill="${p.color||'#bdd5da'}"/><circle cx="36" cy="11" r="13" fill="#fff" opacity=".12"/><path d="M8 48c0-11 5-17 16-17s17 6 17 17" fill="${p.shirt||'#8babb8'}"/><path d="M15 22c-5-11 0-19 10-19 11 0 15 9 10 22" fill="${p.hair||'#4e6471'}"/><ellipse cx="24" cy="22" rx="10" ry="12" fill="#f4dfca"/><path d="M13 19c1-9 5-14 13-13 5 0 10 5 10 13-5-2-9-5-12-10-1 5-6 8-11 10" fill="${p.hair||'#4e6471'}"/><path d="m19 22 1 0m9 0 1 0" stroke="#4f555a" stroke-width="1.7" stroke-linecap="round"/><path d="M22 28q2 2 4 0" stroke="#bb8b7b" fill="none" stroke-width="1.1" stroke-linecap="round"/><path d="m20 35 4 5 4-5" fill="#f3dfd0"/></svg></span>`;
  }
  function art(key) {
    const base={coast:['#cbdedb','#98b8b5','#688f8e'],flowers:['#e5d8d0','#d2aca8','#9ba793'],clouds:['#bfdae8','#9bbfcd','#eff4ee'],coffee:['#ded3c2','#a2947e','#6e715d'],mountain:['#c6d5d1','#93ada6','#607f7b'],sunset:['#e7c8b7','#c19c92','#8f9d97']}[key]||['#cbdedb','#98b8b5','#688f8e'];
    const shapes=key==='coffee'?'<path d="M0 130 200 100v100H0Z" fill="#aa9e87"/><rect x="20" y="112" width="70" height="45" rx="2" fill="#e9e3d4" transform="rotate(-13 20 112)"/><path d="M116 86h43v41c0 20-43 20-43 0Z" fill="#f5eee4"/><ellipse cx="138" cy="87" rx="22" ry="7" fill="#e7d8c6"/><ellipse cx="138" cy="87" rx="17" ry="5" fill="#8d7460"/><path d="M159 92c25-4 25 29 0 26" fill="none" stroke="#f5eee4" stroke-width="8"/>':key==='flowers'?'<path d="M60 200 78 62M98 200l21-115M145 200l-4-74" stroke="#8d9b7c" stroke-width="3"/><g fill="#f3e9e0"><circle cx="75" cy="60" r="14"/><circle cx="87" cy="66" r="13"/><circle cx="72" cy="74" r="13"/><circle cx="120" cy="86" r="15"/><circle cx="132" cy="93" r="12"/><circle cx="116" cy="99" r="12"/><circle cx="144" cy="123" r="13"/><circle cx="134" cy="134" r="13"/><circle cx="152" cy="136" r="12"/></g><g fill="#cbaf77"><circle cx="79" cy="68" r="5"/><circle cx="122" cy="94" r="5"/><circle cx="143" cy="132" r="5"/></g>':`<path d="M0 111 51 64 116 129 163 84 200 103v97H0Z" fill="${base[1]}"/><path d="M0 150 69 119 122 148 200 120v80H0Z" fill="${base[2]}"/><path d="M0 163q40-12 100 0t100 0v37H0Z" fill="#dce8df" opacity=".45"/>`;
    return `<svg viewBox="0 0 200 200" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><rect width="200" height="200" fill="${base[0]}"/><circle cx="148" cy="46" r="17" fill="#fff2dc" opacity=".72"/><path d="M12 35q15-10 30 0t30 0M80 68q15-7 30 0t30 0" fill="none" stroke="#fff" stroke-width="3" opacity=".34"/>${shapes}</svg>`;
  }
  function act(action,label,extra='') {return `data-social="${action}" aria-label="${esc(label)}" ${extra}`}
  function menu(label,action,ico='right',note='',color='#586e91',extra='') {
    return `<button class="social-menu-row" ${act(action,label,extra)} style="--menu-color:${color}">${ico==='right'&&nativeView?'':hi(ico)}<span class="menu-text">${esc(label)}</span>${note?`<small>${esc(note)}</small>`:''}${hi('right')}</button>`;
  }
  function searchBar(placeholder='搜索',value='') {return `<label class="social-search">${hi('search')}<input data-social-search aria-label="搜索社交内容" placeholder="${esc(placeholder)}" value="${esc(value)}" autocomplete="off"></label>`}
  function contactRow(c,action='contact') {return `<button class="social-contact-row" ${act(action,c.name,`data-id="${c.id}"`)}>${portrait(c.id)}<strong>${esc(c.name)}</strong>${c.tag?'<span class="side-note">特别关心</span>':''}${hi('right').replace('<svg ','<svg class="social-chevron" ')}</button>`}
  function inboxRows(filter='') {
    if(window.SKIVU_HOSTED&&window.SkivuHost)return SkivuHost.inboxHtml(filter);
    const list=[...data.contacts].sort((a,b)=>Number(!!b.pinned)-Number(!!a.pinned)).filter(c=>(c.name+' '+c.snippet).toLowerCase().includes(filter.toLowerCase()));
    return list.length?list.map(c=>`<button class="social-chat-row ${c.pinned?'pinned':''}" ${act('chat','打开与'+c.name+'的聊天',`data-id="${c.id}"`)}>${portrait(c.id)}<span class="social-chat-info"><span class="social-chat-title">${esc(c.name)}${c.official?'<small>订阅</small>':''}</span><span class="social-chat-snippet">${esc(c.snippet)}</span></span><span class="social-chat-tail"><time>${esc(c.time)}</time>${c.unread?`<span class="social-unread">${c.unread}</span>`:'<span class="social-muted">'+(c.muted?'免打扰':'')+'</span>'}</span></button>`).join(''):'<div class="social-search-empty">没有匹配的会话</div>';
  }
  function inbox() {
    const presence=state.mode==='qq'?`<div class="social-qq-presence">${data.contacts.filter(c=>!c.groupChat&&!c.official).slice(0,5).map(c=>`<button class="social-presence-item" ${act('contact',c.name,`data-id="${c.id}"`)}><span style="position:relative">${portrait(c.id)}<i class="presence-dot"></i></span>${esc(c.name)}</button>`).join('')}</div>`:'';
    return (state.mode==='wx'?'':searchBar(nativeView?'搜索':'搜索好友、群聊或消息'))+(nativeView?'':presence)+'<div class="social-list" id="socialResults">'+inboxRows()+'</div>';
  }
  function contactsRows(filter='') {
    if(window.SKIVU_HOSTED&&state.mode==='qq'&&contactFilter==='groups')return window.ChatInteractions?.moduleMarkup('groups',filter)||'';
    let list=data.contacts.filter(c=>!c.official&&(contactFilter==='groups'?c.groupChat:!c.groupChat));
    if(state.mode==='wx')list=data.contacts.filter(c=>!c.groupChat&&!c.official);
    list=list.filter(c=>c.name.toLowerCase().includes(filter.toLowerCase()));
    if(state.mode==='wx'&&nativeView){const grouped={};for(const c of list.sort((a,b)=>a.name.localeCompare(b.name,'zh-CN'))){const first=c.name.charAt(0),key=/[a-z]/i.test(first)?first.toUpperCase():({'程':'C','林':'L','宁':'N','许':'X'}[first]||'#');(grouped[key]||=[]).push(c)}return Object.keys(grouped).sort().map(key=>`<div class="social-section-label" id="contact-letter-${key}">${key}</div>${grouped[key].map(c=>contactRow(c)).join('')}`).join('')||'<div class="social-search-empty">没有找到联系人</div>'}
    return list.length?list.map(c=>contactRow(c)).join(''):'<div class="social-search-empty">没有找到联系人</div>';
  }
  function contacts() {
    if(state.mode==='qq') return searchBar('搜索联系人')+`<div class="social-segments">${[['friends','好友'],['groups','群聊']].map(([id,name])=>`<button ${act('filter',name,`data-filter="${id}"`)} class="${contactFilter===id?'active':''}">${name}</button>`).join('')}<button ${act('requests','新朋友')}>新朋友</button><button ${act('calls','通话')}>通话</button></div><div class="social-group-label">${hi('down')} ${contactFilter==='groups'?'我的群聊':'特别关心与我的朋友'} <span>${window.SKIVU_HOSTED&&contactFilter==='groups'?(data.hostGroups||[]).length:data.contacts.filter(c=>contactFilter==='groups'?c.groupChat:!c.groupChat&&!c.official).length}</span></div><div id="socialResults">${contactsRows()}</div>`;
    return searchBar('搜索')+`<div class="social-list">${[['新的朋友','requests','users','#fa9d3b'],['群聊','groups','chat','#07c160'],['标签','tags','box','#2782d7'],['公众号','subscriptions','book','#2782d7']].map(([name,action,ico,color])=>`<button class="social-contact-row" ${act(action,name)}><span class="social-shortcut" style="--shortcut-color:${color}">${hi(ico)}</span><strong>${name}</strong>${action==='requests'&&data.requests.some(r=>!r.accepted)?'<span class="social-unread">1</span>':''}</button>`).join('')}</div><div class="social-section-label">我的朋友</div><div class="social-list" id="socialResults">${contactsRows()}</div><div class="social-contact-count">${data.contacts.filter(c=>!c.groupChat&&!c.official).length} 位联系人</div><div class="social-alpha"><span>↑</span><span>☆</span><span>C</span><span>L</span><span>N</span><span>S</span><span>X</span><span>#</span></div>`;
  }
  function discover() {
    if(state.mode==='qq')return `<div class="social-group">${menu('好友动态','moments','image',window.SKIVU_HOSTED?(data.posts.length?data.posts.length+' 条动态':'还没有动态'):'刚刚有新动态','#359cde')}${menu('我的空间','moments','star','记录生活','#e5af4d')}</div><div class="social-group">${menu('相册','albums','image',window.SKIVU_HOSTED?data.posts.reduce((sum,p)=>sum+(p.images?.length||0),0)+' 张照片':'12 张照片','#52b2c3')}${menu('收藏','favorites','star','','#d6ad69')}${menu('文件','files','folder','','#71a8cf')}${menu('通话记录','calls','phone','','#719fd0')}</div><div class="social-group">${menu('小程序','miniapps','grid','','#5a9eb5')}${menu('个人主页','me','user','','#7796b7')}${menu('设置','settings','settings','','#8ca1b1')}</div>`;
    return `<div class="social-group">${menu('朋友圈','moments','compass','','#2782d7')}</div>`;
  }
  function postCard(post) {
    const p=person(post.author);
    const actions=`<div class="social-post-actions ${nativeView&&state.mode==='wx'?'native-post-popup':''}" ${nativeView&&state.mode==='wx'&&postMenu!==post.id?'hidden':''}><button class="${post.likes.includes('self')?'liked':''}" ${act('like',post.likes.includes('self')?'取消点赞':'点赞',`data-post="${post.id}"`)}>${hi('heart')}${post.likes.includes('self')?'取消':'赞'}</button><button ${act('comment','评论',`data-post="${post.id}"`)}>${hi('chat')}评论</button></div>`;
    return `<article class="social-post">${portrait(post.author)}<div class="social-post-body"><button class="social-post-author" ${act(post.author==='self'?'me':'contact',p.name,`data-id="${post.author}"`)}>${esc(p.name)}</button><div class="social-post-text">${esc(post.text)}</div>${post.images?.length?`<div class="social-post-images ${post.images.length===1?'one':''}">${post.images.map((image,i)=>`<button class="social-post-image" ${act('photo','查看动态图片',`data-post="${post.id}" data-image="${i}"`)}>${image.startsWith('data:image/')?`<img src="${image}" alt="本地选择的图片">`:art(image)}</button>`).join('')}</div>`:''}${post.location?`<div class="native-post-location">${esc(post.location)}</div>`:''}<div class="social-post-bottom"><span>${esc(post.time)}</span>${post.author==='self'?`<button class="native-delete-post" ${act('delete-post','删除动态',`data-post="${post.id}"`)}>删除</button>`:''}${nativeView&&state.mode==='wx'?`<button class="native-post-more" ${act('post-menu','动态操作',`data-post="${post.id}"`)} aria-expanded="${postMenu===post.id}">${hi('more')}</button>`:''}${actions}</div>${post.likes.length||post.comments.length?`<div class="social-post-replies">${post.likes.length?`<div class="social-like-names">${hi('heart')}${post.likes.map(id=>esc(getName(id))).join('、')}</div>`:''}${post.comments.map(comment=>`<div class="social-comment"><strong>${esc(comment.author?getName(comment.author):comment.name)}：</strong>${esc(comment.text)}</div>`).join('')}</div>`:''}</div></article>`;
  }
  function moments() {
    return `<div class="social-moments"><div class="social-cover"><div class="social-cover-art">${art('coast')}</div><span class="cover-label">A LITTLE EVERYDAY</span><span class="social-cover-name">${esc(data.profile.name)}</span><button class="social-cover-avatar" ${act('me','我的主页')}>${portrait('self')}</button><span class="social-signature">${esc(data.profile.bio)}</span></div>${state.mode==='qq'?`<div class="social-zone-stats"><button ${act('albums','相册')}><strong>${window.SKIVU_HOSTED?data.posts.reduce((sum,p)=>sum+(p.images?.length||0),0):12}</strong>相册</button><button ${act('compose','写说说')}><strong>${data.posts.filter(p=>p.author==='self').length+(window.SKIVU_HOSTED?0:23)}</strong>说说</button><button ${act('visitors','访客')}><strong>${window.SKIVU_HOSTED?'—':128}</strong>访客</button></div>`:''}<div class="social-feed">${data.posts.map(postCard).join('')}</div><div class="social-contact-count">已经看到这里啦</div></div>`;
  }
  function me() {
    if(state.mode==='wx'&&nativeView)return `<button class="social-profile-head" style="width:100%;text-align:left" ${act('edit-profile','编辑个人资料')}>${portrait('self','big')}<span class="social-profile-info"><h2>${esc(data.profile.name)}</h2><p>微信号：${esc(data.profile.account)}</p><span class="profile-status">＋ 状态</span></span>${hi('qr')}${hi('right')}</button><div class="social-group">${menu('服务','services','wallet','','#07c160')}</div><div class="social-group">${menu('收藏','favorites','box','','#fa9d3b')}${menu('朋友圈','moments','image','','#2782d7')}${menu('卡包','cards','wallet','','#2782d7')}${menu('表情','stickers','smile','','#fa9d3b')}</div><div class="social-group">${menu('设置','settings','settings','','#2782d7')}</div>`;
    return `<button class="social-profile-head" style="width:100%;text-align:left" ${act('edit-profile','编辑个人资料')}>${portrait('self','big')}<span class="social-profile-info"><h2>${esc(data.profile.name)}</h2><p>${state.mode==='qq'?'QQ 号':'账号'}：${esc(data.profile.account)}</p><span class="profile-status">${hi('smile').replace('<svg ','<svg style="width:11px;height:11px" ')} ${esc(data.profile.status||'记录生活中')}</span></span>${hi('qr')}</button><div class="social-group">${menu('个人状态','status','smile',data.profile.status||'记录生活中','#68a394')}${menu(state.mode==='qq'?'我的空间':'我的朋友圈','moments','image','','#6d9dbd')}</div><div class="social-group">${menu('收藏','favorites','star',data.favorites.length?data.favorites.length+' 条':'','#dcad63')}${menu('相册','albums','image','','#699bc8')}${menu('表情','stickers','smile','','#d6aa65')}${menu('文件','files','folder','','#7c9fba')}</div><div class="social-group">${menu('设置','settings','settings','','#78909f')}</div>`;
  }
  function contactDetail() {
    if(nativeView){const c=current();return `<div class="social-contact-card">${portrait(c.id,'big')}<div><h2>${esc(c.name)}</h2><p>角色卡：${esc(c.name)}<br>${window.SKIVU_HOSTED?esc(c.bio||'角色资料由 Skivu 统一管理'):'地区：浙江 杭州'}</p></div></div><div class="social-group">${menu('备注和标签','remark','user')}${window.SKIVU_HOSTED?menu('编辑角色卡','edit-role','sliders'):''}${menu('朋友权限','privacy','user')}</div><div class="social-group">${menu(state.mode==='qq'?'QQ空间':'朋友圈','moments','image')}${menu('更多信息','bio','more')}</div><div class="social-contact-buttons"><button class="social-primary" ${act('chat','发消息',`data-id="${c.id}"`)}>发消息</button><button ${act('call','音视频通话',`data-id="${c.id}"`)}>音视频通话</button></div>`}
    const c=current();return `<div class="social-contact-card">${portrait(c.id,'big')}<div><h2>${esc(c.name)}</h2><p>${c.groupChat?'群聊 · '+(c.members?c.members.length+1:4)+' 位成员':'昵称：'+esc(c.name)}<br>地区：中国</p></div></div><div class="social-contact-tags"><span>${c.groupChat?'周末计划':'日常陪伴'}</span><span>${c.tag?'特别关心':'我的朋友'}</span></div><div class="social-group">${menu('个性签名','bio','chat',c.bio||'还没有签名')}${menu('朋友圈 / 空间','moments','image','看看最近的生活')}${menu('角色卡片设定','edit-role','sliders','名称与头像')}</div><div class="social-contact-buttons"><button class="social-primary" ${act('chat','发消息',`data-id="${c.id}"`)}>发消息</button><button ${act('call','语音 / 视频通话',`data-id="${c.id}"`)}>语音 / 视频通话</button></div>`;
  }
  function requests() {return '<div class="social-section-label">好友申请</div>'+data.requests.map(r=>`<div class="social-request">${portrait(r.accepted?r.id:'xia')}<div class="social-request-info">${esc(r.name)}<p>${esc(r.bio)}</p></div>${r.accepted?'<small>已添加</small>':`<button ${act('accept','接受 '+r.name,`data-id="${r.id}"`)}>接受</button>`}</div>`).join('')}
  function groups() {return `<div class="social-group">${menu('发起群聊','new-group','plus','选择朋友')}</div><div class="social-list">${data.contacts.filter(c=>c.groupChat).map(c=>contactRow(c,'chat')).join('')}</div>`}
  function favorites() {return data.favorites.length?data.favorites.map((text,i)=>`<article class="social-collection-card"><p>${esc(text)}</p><small>来自聊天 · 收藏 ${i+1}</small></article>`).join(''):'<div class="social-search-empty">把喜欢的话收藏起来。<br>打开聊天，在消息的更多菜单中选择“收藏”。</div>'}
  function albums() {return `<div class="social-section-label">生活碎片 · 12 张</div><div class="social-photo-grid">${Array.from({length:12},(_,i)=>`<button ${act('art-photo','查看相册图片',`data-art="${artKeys[i%6]}"`)}>${art(artKeys[i%6])}</button>`).join('')}</div>`}
  function settingsContent() {if(nativeView&&state.mode==='wx')return `<div class="social-group">${menu('账号与安全','account-info')}${menu('青少年模式','youth')}${menu('关怀模式','care')}</div><div class="social-group">${menu('新消息通知','notifications')}${menu('聊天','chat-settings')}${menu('通用','general')}</div><div class="social-section-label">隐私</div><div class="social-group">${menu('朋友权限','privacy')}${menu('个人信息与权限','privacy')}</div><div class="social-group">${menu('帮助与反馈','help')}${menu('关于微信','about')}</div>`;return `<div class="social-group">${menu('个人资料','edit-profile','user')}${menu('聊天外观','appearance','sliders','玻璃、胶囊与信息条')}${menu('字体与排版','font','sliders',state.font+' px')}</div><div class="social-group"><div class="social-details-pair"><span>新消息通知</span><button class="switch" role="switch" aria-label="新消息通知" aria-checked="${!!data.notifications}" data-social="toggle-option" data-key="notifications"></button></div><div class="social-details-pair"><span>免打扰模式</span><button class="switch" role="switch" aria-label="免打扰模式" aria-checked="${!!data.quiet}" data-social="toggle-option" data-key="quiet"></button></div>${menu('隐私与可见范围','privacy','user','仅此预览')}${menu('关于此界面','about','cloud','Skivu 社交模式')}</div>`}
  function settings(){return (window.SKIVU_HOSTED?'<div class="social-group">'+menu('社交与群聊','social-settings','settings','自动动态、评论与群聊规则')+'</div>':'')+settingsContent()}
  function compose() {return `<div class="social-compose"><div class="social-compose-author">${portrait('self')}<span>${esc(data.profile.name)}</span></div><textarea id="socialPostText" aria-label="动态正文" maxlength="3000" placeholder="这一刻的想法…">${esc(draftText)}</textarea><div class="social-compose-grid" id="socialDraftImages">${composeImages()}</div><button class="social-privacy-row" ${act('location','所在位置')}>${hi('pin')}<span>所在位置</span><small>不显示位置</small>${hi('right')}</button><button class="social-privacy-row" ${act('privacy','谁可以看')}>${hi('users')}<span>谁可以看</span><small>朋友可见</small>${hi('right')}</button><div class="social-draft-actions"><button class="social-primary" ${act('publish','发表动态')}>发表</button></div></div>`}
  function composeImages() {return draftImages.map((key,i)=>`<button class="social-compose-thumb" ${act('remove-draft-image','移除图片',`data-index="${i}"`)}>${key.startsWith('data:image/')?`<img src="${key}" alt="待发布图片">`:art(key)}<span class="remove">×</span></button>`).join('')+(draftImages.length<9?`<button class="social-add-photo" ${act('add-photo','添加动态图片')}>${hi('plus')}</button>`:'')}
  function calls() {return `<div class="social-section-label">最近通话</div>${[['xia','今天 08:40','语音通话 · 05:32'],['lin','昨天 21:06','未接来电'],['ski','周三 19:28','语音通话 · 12:08']].map(([id,time,desc])=>`<button class="social-chat-row" ${act('call','与'+getName(id)+'通话',`data-id="${id}"`)}>${portrait(id)}<span class="social-chat-info"><span class="social-chat-title">${esc(getName(id))}</span><span class="social-chat-snippet">${desc}</span></span><span class="social-chat-tail"><time>${time}</time>${hi('phone')}</span></button>`).join('')}`}
  function callPage() {return `<div class="social-call-page">${portrait(active)}<h2>${esc(current().name)}</h2><p id="socialCallStatus">等待对方接听…</p><div class="social-call-controls"><button ${act('mute-call','麦克风开关')}>${hi('mic')}</button><button class="hang-up" ${act('hangup','挂断通话')}>${hi('phone')}</button><button ${act('video-call','视频通话，开发中')} disabled aria-disabled="true" title="视频通话开发中">${hi('video')}</button></div></div>`}
  function miniapps() {return `<div class="social-section-label">最近使用</div><div class="social-group">${menu('天气小助手','weather','cloud','今天也要有好心情','#71a5bb')}${menu('随手记','notepad','box','灵感不丢失','#c29b6b')}${menu('一起做计划','planner','check','给生活留一点余地','#79a894')}</div><p class="social-contact-count">这些是本地界面示例</p>`}
  function files() {return [['folder','周末旅行计划.md','2.4 KB · 今天'],['image','沿途的风景.png','1.2 MB · 昨天'],['box','我的阅读清单.txt','1.8 KB · 周三']].map(([ico,name,note])=>`<button class="social-file" style="width:100%;text-align:left" ${act('file-detail',name,`data-name="${name}"`)}>${hi(ico)}<span><strong>${name}</strong><p>${note}</p></span></button>`).join('')}
  function search() {return `<div class="social-search-page">${searchBar('搜索联系人、群聊或聊天内容',searchQuery)}<div id="socialResults">${searchResults(searchQuery)}</div></div>`}
  function searchResults(q) {
    if(!q)return '<div class="social-search-empty">搜索朋友的名字，或一段聊天里的话。</div>';
    const list=data.contacts.filter(c=>(c.name+' '+(data.threads[c.id]||[]).map(m=>m.text).join(' ')).toLowerCase().includes(q.toLowerCase()));
    return list.length?'<div class="social-section-label">联系人与对话</div>'+list.map(c=>contactRow(c,'chat')).join(''):'<div class="social-search-empty">没有找到相关内容</div>';
  }
  const renderers={'chat-info':()=>window.SocialFeatures?.chatInfo()||'','chat-search':()=>window.SocialFeatures?.chatSearch()||'',services:()=>window.SocialFeatures?.services()||'',wallet:()=>window.SocialFeatures?.wallet()||'','wallet-records':()=>window.SocialFeatures?.records()||'',cashier:()=>window.SocialFeatures?.cashier()||'',scan:()=>window.SocialFeatures?.scan()||'',inbox,contacts,discover,moments,me,contact:contactDetail,requests,groups,calls,favorites,albums,settings,compose,search,call:callPage,miniapps,files,subscriptions:()=>'<div class="social-section-label">我的订阅</div>'+contactRow(findContact('book'),'chat')};
  function renderPage(resetScroll=true) {
    if(page==='chat')return;
    const el=$('#socialPage'),old=el.scrollTop;
    el.innerHTML=window.ChatInteractions?.moduleMarkup(page)??(renderers[page]||inbox)();
    $('#chatPlane').classList.toggle('moments-scrolled',page==='moments'&&el.scrollTop>130);
    if(!resetScroll)el.scrollTop=old;
    window.ChatInteractions?.paint();
    if(page==='call'){clearInterval(callTimer);callStarted=Date.now();callTimer=setInterval(()=>{const label=$('#socialCallStatus');if(!label){clearInterval(callTimer);return}const sec=Math.floor((Date.now()-callStarted)/1000);label.textContent=sec<3?'等待对方接听…':'界面演示 · '+String(Math.floor((sec-3)/60)).padStart(2,'0')+':'+String((sec-3)%60).padStart(2,'0')},1000)}
  }
  function title() {
    if(window.SKIVU_HOSTED&&page==='inbox')return window.SocialUnread?.title(state.mode==='qq'?'消息':'微信')||(state.mode==='qq'?'消息':'微信');
    if(page==='channels')return '频道';
    if(window.SKIVU_HOSTED&&state.mode==='qq'&&page==='chat-info')return '聊天设置';
    const names={'chat-info':'聊天信息','chat-search':'查找聊天记录',services:'服务',wallet:'钱包','wallet-records':'零钱明细',cashier:'收付款',scan:'扫一扫',inbox:state.mode==='qq'?'消息':'微信',contacts:state.mode==='qq'?'联系人':'通讯录',discover:state.mode==='qq'?'动态':'发现',moments:state.mode==='qq'?'好友动态':'朋友圈',me:state.mode==='qq'?'个人主页':'我',contact:current().name,requests:'新的朋友',groups:'群聊',calls:'通话记录',favorites:'收藏',albums:'相册',settings:'设置',compose:state.mode==='qq'?'写说说':'发表动态',search:'搜索',call:'语音通话',miniapps:'小程序',subscriptions:'订阅',files:'文件'};
    return names[page]||'消息';
  }
  function tabMarkup() {
    const items=state.mode==='qq'?[['inbox','消息','chat'],['channels','频道','hash'],['contacts','联系人','user'],['discover','动态','qq-zone']]:[['inbox','微信','chat'],['contacts','通讯录','address-book'],['discover','发现','compass'],['me','我','user']];
    return items.map(([id,name,ico])=>`<button class="social-tab ${page===id||(page==='moments'&&id==='discover')?'active':''}" ${act('tab',name,`data-page="${id}"`)} ${page===id?'aria-current="page"':''}><span class="social-tab-icon">${hi(ico)}${window.SKIVU_HOSTED&&['inbox','channels'].includes(id)?window.SocialUnread?.badge(window.SocialUnread.total(id))||'':''}</span><span>${name}</span>${!window.SKIVU_HOSTED&&id==='inbox'&&data.contacts.some(c=>c.unread)?'<i class="tab-dot"></i>':''}</button>`).join('');
  }
  function sync() {
    const enabled=state.mode!=='skivu',chat=page==='chat'||!enabled;
    const native=enabled&&nativeView,rootPage=['inbox','channels','contacts','discover','me'].includes(page);
    $('#chatPlane').classList.toggle('social-shell',enabled);
    $('#chatPlane').classList.toggle('social-chat',chat);
    $('#chatPlane').classList.toggle('native-style',native);
    if(native){$('#chatPlane').style.setProperty('--message-size',(Number(state.nativeFont)||16)+'px');$('#fontSize').value=Number(state.nativeFont)||16;$('#fontOutput').value=Number(state.nativeFont)||16}else $('#chatPlane').style.removeProperty('--message-size');
    $('#phone').classList.toggle('native-preview',native);
    $('#chatPlane').dataset.page=page;
    window.SocialUnread?.visibility(page);
    $('#socialPage').hidden=chat;$('#socialTabs').hidden=chat||(native&&!rootPage);
    $('#socialBack').hidden=!enabled||rootPage;
    $('#socialSearch').hidden=!enabled||chat||!['inbox','contacts'].includes(page)||(native&&!(state.mode==='wx'&&page==='inbox'));
    $('#socialTopAction').hidden=!enabled||(chat?!native:!['inbox','moments','me','contacts'].includes(page))||(native&&page==='me'&&state.mode==='wx');
    $('#socialQQProfile').hidden=!enabled||state.mode!=='qq'||page!=='inbox';
    $('#socialQQProfile').innerHTML=portrait('self');
    if(enabled&&!chat){$('#roleTitle').textContent=title();$('#roleTitle').classList.remove('typing')}
    const topAction=chat?(state.mode==='qq'?'menu':'more'):page==='moments'?'camera':page==='me'?'settings':native&&state.mode==='wx'?'plus-circle':'plus';$('#socialTopAction').innerHTML=hi(topAction);$('#socialTopAction').setAttribute('aria-label',chat?'聊天信息':page==='moments'?'发表动态':page==='me'?'个人设置':'添加好友或群聊');
    if(native&&chat&&state.mode==='qq'&&!stream)$('#roleTitle').innerHTML=esc(data.hostGroupName||current().name)+'<small class="native-online"><span style="color:#00ce78">●</span> '+(data.hostGroupName?(data.hostGroupKind==='channel'?'频道':'群聊'):'当前对话')+'</small>';
    $('#nativeToggle').setAttribute('aria-checked',String(nativeView));
    $('#evidenceNote').textContent=!enabled?'Skivu 原版对照':state.mode==='wx'&&['inbox','chat'].includes(page)?'微信 · 已按当前官方宣传图校准基础布局':state.mode==='qq'&&page==='chat'?'QQ · 已按当前官方宣传图校准聊天布局':'此页参考开源模块结构，当前安卓细节待核对';
    $('#modeNoteTitle').textContent=!enabled?'保留原有玻璃基底':state.mode==='wx'?'微信 · Android':'QQ · Android';
    $('#modeNote').textContent=!enabled?'左右面板与 Skivu 原版对照。':native?'原版导航、列表和输入区。Skivu 两侧面板可从下方按钮打开，或在屏幕边缘拖动。':'保留 Skivu 能力的对照模式，可调整玻璃、模型及消息信息。';
    $('#socialTabs').innerHTML=tabMarkup();
    $$('[data-social-page-choice]').forEach(el=>el.classList.toggle('active',el.dataset.socialPageChoice===page));
    if(enabled&&!chat)renderPage(false);
    decorateChat();
  }
  function decorateChat() {
    if(state.mode==='skivu')return;
    $$('#messages .message').forEach((el,i)=>{const face=el.querySelector('.avatar'),id=el.classList.contains('user')?'self':messages[i]?.authorId||active;if(face)face.innerHTML=portrait(id);const name=el.querySelector('.sender-name');if(name&&messages[i]?.authorId)name.textContent=data.contacts.find(r=>r.id===id)?.name||'群成员'});
    const date=$('#messages .date-separator'),firstTime=messages[0]?.time||'09:41';if(nativeView&&date)date.textContent=/^\d\d:\d\d$/.test(firstTime)?'今天 '+firstTime:firstTime;
    $('#sendButton').innerHTML=nativeView?(stream?'停止':'发送'):icon(stream?'stop':'arrow-up');
    window.SharedChatAppearance?.paint();
    const tools=$('.qq-tools');
    if(!tools.dataset.nativeTools){tools.innerHTML=[['voice','语音','mic'],['image','图片','image'],['camera-preview','拍照','camera'],['files','文件','folder'],['emoji','表情','smile'],['attachments','更多','plus-circle']].map(([action,label,ico])=>`<button data-social="chat-tool" data-tool="${action}" aria-label="QQ ${label}">${hi(ico)}</button>`).join('');tools.dataset.nativeTools='1'}
    window.QqChat?.paint();
    window.ChatInteractions?.paint();
  }
  function go(target,{id=null,replace=false}={}) {
    if(!routeNames.has(target)&&target!=='chat'&&target!=='channels')return;
    if(target==='compose'&&page!=='compose'){draftText='';draftImages=[]}
    if(!replace&&page!==target)trail.push({page,active});
    if(trail.length>25)trail.shift();
    if(id&&data.contacts.some(c=>c.id===id)&&id!==active){stopStream();flushThread();active=id;messages=structuredClone(data.threads[id]||[]);state.role=current().name;state.avatar=current().avatar||null;renderMessages()}
    page=target;data.lastPage=page;keep();sync();renderPage(true);setDrawer('none');closeSheet();
    if(page==='chat'){current().unread=0;keep();applyState();bottom()}
  }
  function back(){const prior=trail.pop();if(prior)go(prior.page,{id:prior.active,replace:true});else go(state.mode==='qq'&&data.hostGroupKind==='channel'?'channels':'inbox',{replace:true})}
  function locateMessage(index){
    const chat=trail.findLastIndex(entry=>entry.page==='chat');
    trail=chat>=0?trail.slice(0,chat):[];
    go('chat',{replace:true});
    requestAnimationFrame(()=>{const m=messages[index];if(m)document.querySelector(`[data-message-id="${m.id}"]`)?.scrollIntoView({block:'center',behavior:'smooth'})});
  }
  function openChat(id){if(window.SKIVU_HOSTED){window.SkivuHost?.chooseRole(id);return}flushThread();go('chat',{id});current().unread=0;keep()}
  function modelSheetAction(label,action,extra='') {return `<button class="sheet-item" ${act(action,label,extra)}>${esc(label)}${hi('right')}</button>`}
  function profileEditor() {showSheet('编辑个人资料',`<form class="social-form" id="socialProfileForm"><button type="button" class="social-form-portrait" data-social="upload-profile-avatar">${portrait('self','big')}<span>更换头像</span></button><label>名字<input name="name" maxlength="24" value="${esc(data.profile.name)}" required></label><label>账号<input name="account" maxlength="36" value="${esc(data.profile.account)}" required></label><label>个性签名<textarea name="bio" maxlength="100">${esc(data.profile.bio)}</textarea></label><label>地区<input name="city" maxlength="30" value="${esc(data.profile.city)}"></label><button class="social-primary" type="submit">保存资料</button></form>`)}
  function newGroup(){showSheet('发起群聊',`<form id="socialGroupForm" class="social-form"><label>群聊名称<input name="name" placeholder="给这个群取个名字" maxlength="30" required></label>${data.contacts.filter(c=>!c.groupChat&&!c.official).map(c=>`<label class="social-selection-row">${portrait(c.id)}${esc(c.name)}<input type="checkbox" name="members" value="${c.id}"></label>`).join('')}<button class="social-primary" type="submit">创建群聊</button></form>`)}
  function commentEditor(post){showSheet('评论',`<form id="socialCommentForm" class="social-form" data-post="${post.id}"><label>回复 ${esc(getName(post.author))}<textarea name="text" maxlength="300" placeholder="说点什么…" required></textarea></label><button type="submit" class="social-primary">发送评论</button></form>`)}
  function addPhotos(){showSheet('添加图片',`<div class="social-photo-grid">${artKeys.map(key=>`<button ${act('choose-art','选择图片 '+key,`data-art="${key}"`)}>${art(key)}</button>`).join('')}</div>${modelSheetAction('从本机选择图片','upload-post-image')}<p class="sheet-caption">图片只保存在这个本地原型中。</p>`)}
  const coreSave=save,coreApply=applyState,coreRender=renderMessages,coreMode=changeMode;
  save=function(){coreSave();flushThread()};
  renderMessages=function(){coreRender();decorateChat()};
  applyState=function(){coreApply();sync()};
  changeMode=function(mode){flushThread();coreMode(mode);sync()};
  document.addEventListener('click',event=>{
    if(state.mode==='skivu')return;
    const base=event.target.closest('[data-action]');if(!base||!$('#chatPlane').contains(base))return;
    const action=base.dataset.action;
    if(action==='edit-role'){
      event.preventDefault();event.stopImmediatePropagation();
      if(page==='chat')go('contact');else if(page==='me')profileEditor();else if(state.mode==='qq')go('me');
    } else if(action==='call'){
      event.preventDefault();event.stopImmediatePropagation();go('call');
    } else if(action==='message-more'){
      event.preventDefault();event.stopImmediatePropagation();const index=Number(base.dataset.index);
      showSheet('消息操作',item('复制内容','copy-message','','copy',`data-index="${index}"`)+modelSheetAction('收藏这条消息','favorite-message',`data-index="${index}"`)+item('删除本轮对话','delete-round','','close',`data-index="${index}"`));
    }
  },true);
  document.addEventListener('click',event=>{
    const control=event.target.closest('[data-social],[data-social-page-choice]');if(!control)return;
    const action=control.dataset.social;
    if(control.dataset.socialPageChoice){if(state.mode==='skivu')changeMode('wx');go(control.dataset.socialPageChoice);return}
    const id=control.dataset.id,post=data.posts.find(p=>p.id===control.dataset.post);
    if(action==='tab'){trail=[];go(control.dataset.page,{replace:true});return}
    if(action==='chat'){openChat(id||active);return}
    if(action==='contact'){go('contact',{id});return}
    if(action==='back'){back();return}
    if(routeNames.has(action)){if(action==='call'&&id&&id!==active)go('contact',{id});go(action);return}
    switch(action){
      case 'top-action':if(page==='chat')showSheet('聊天信息',contactRow(current())+modelSheetAction('查找聊天内容','search')+modelSheetAction('收藏','favorites')+modelSheetAction(data.quiet?'关闭消息免打扰':'消息免打扰','chat-mute')+modelSheetAction('语音通话','call'));else if(page==='moments')go('compose');else if(page==='me')go('settings');else showSheet('添加',modelSheetAction('发起群聊','new-group')+modelSheetAction('添加朋友','requests')+modelSheetAction('扫一扫','scan'));break;
      case 'chat-mute':data.quiet=!data.quiet;keep();closeSheet();toast(data.quiet?'已开启消息免打扰':'已关闭消息免打扰');break;
      case 'remark':showSheet('备注和标签',`<form id="socialRemarkForm" class="social-form"><label>备注名<input name="name" maxlength="24" required value="${esc(current().name)}"></label><button type="submit" class="social-primary">完成</button></form>`);break;
      case 'account-info':showSheet('账号与安全',`<div class="social-details-pair"><span>微信号</span><small>${esc(data.profile.account)}</small></div><p class="sheet-caption">本地演示资料，不连接微信账号。</p>`);break;
      case 'notifications':showSheet('新消息通知',`<div class="social-details-pair"><span>接收新消息通知</span><button class="switch" role="switch" aria-label="接收新消息通知" aria-checked="${!!data.notifications}" data-social="toggle-notifications"></button></div>`);break;
      case 'toggle-notifications':data.notifications=!data.notifications;keep();control.setAttribute('aria-checked',String(data.notifications));break;
      case 'chat-settings':case 'general':showSheet(control.getAttribute('aria-label'),modelSheetAction('字体大小','font')+modelSheetAction('聊天背景与外观','appearance'));break;
      case 'youth':case 'care':case 'help':showSheet(control.getAttribute('aria-label'),'<p class="sheet-caption">本地界面预览，未接入真实平台服务。</p>');break;
      case 'chat-tool':if(control.dataset.tool==='files'){go('files');break}if(control.dataset.tool==='camera-preview'){showSheet('拍照','<p class="sheet-caption">此 HTML 只预览相机入口，不调用摄像头。</p>');break}if(control.dataset.tool==='emoji'){$('#messageInput').value+='☺️';applyDraftState();break}showSheet(control.dataset.tool==='voice'?'语音输入':'更多功能',modelSheetAction('图片与相册','albums')+modelSheetAction('语音通话','call')+modelSheetAction('文件','files'));break;
      case 'post-menu':postMenu=postMenu===control.dataset.post?null:control.dataset.post;renderPage(false);break;
      case 'services':case 'cards':case 'shopping':case 'games':case 'shake':case 'read':showSheet(control.getAttribute('aria-label'),'<p class="sheet-caption">此入口为本地页面结构预览，未连接真实平台服务。</p>');break;
      case 'qq-profile':go('me');break;
      case 'filter':contactFilter=control.dataset.filter;renderPage();break;
      case 'like':if(post){post.likes=post.likes.includes('self')?post.likes.filter(id=>id!=='self'):[...post.likes,'self'];postMenu=null;keep();renderPage(false)}break;
      case 'comment':if(post){postMenu=null;commentEditor(post)}break;
      case 'photo':if(post){const image=post.images[Number(control.dataset.image)];showSheet('生活碎片',`<div class="social-gallery-view">${image.startsWith('data:image/')?`<img src="${image}" alt="动态图片">`:art(image)}</div>`)}break;
      case 'art-photo':showSheet('相册',`<div class="social-gallery-view">${art(control.dataset.art)}</div>`);break;
      case 'publish':draftText=$('#socialPostText').value.trim();if(!draftText&&!draftImages.length){toast('写点什么，或选一张图片');break}if(data.posts.length>=100){toast('本地示例最多保留100条动态');break}data.posts.unshift({id:'local-'+Date.now(),author:'self',text:draftText,images:[...draftImages],time:'刚刚',likes:[],comments:[]});keep();go('moments',{replace:true});break;
      case 'add-photo':draftText=$('#socialPostText').value;addPhotos();break;
      case 'choose-art':if(draftImages.length<9)draftImages.push(control.dataset.art);closeSheet();renderPage(false);break;
      case 'remove-draft-image':draftText=$('#socialPostText').value;draftImages.splice(Number(control.dataset.index),1);$('#socialDraftImages').innerHTML=composeImages();break;
      case 'upload-post-image':uploadTarget='post';$('#socialPostFile').click();break;
      case 'upload-profile-avatar':uploadTarget='profile';$('#socialPostFile').click();break;
      case 'delete-post':showSheet('删除这条动态？',modelSheetAction('确认删除本地动态','confirm-delete-post',`data-post="${control.dataset.post}"`)+item('取消','close-sheet'));break;
      case 'confirm-delete-post':data.posts=data.posts.filter(p=>p.id!==control.dataset.post);keep();closeSheet();renderPage(false);break;
      case 'accept':{const request=data.requests.find(r=>r.id===id);if(request&&!request.accepted){request.accepted=true;data.contacts.push({...request,group:'我的朋友',unread:0,time:'刚刚',snippet:'我们已经成为朋友了。'});data.threads[id]=[{id:Date.now(),role:'assistant',text:'我们已经成为朋友了，开始聊天吧。',time:'刚刚'}];keep();renderPage()}break}
      case 'new-group':newGroup();break;
      case 'edit-profile':profileEditor();break;
      case 'edit-role':editRole();break;
      case 'appearance':settingsSheet();break;
      case 'favorite-message':{const m=messages[Number(control.dataset.index)];if(m&&!data.favorites.includes(m.text)){data.favorites.unshift(m.text);keep()}closeSheet();toast('已收藏到“我 → 收藏”');break}
      case 'toggle-option':data[control.dataset.key]=!data[control.dataset.key];keep();renderPage(false);break;
      case 'tags':showSheet('我的标签',modelSheetAction('我的朋友 · '+data.contacts.filter(c=>!c.groupChat&&!c.official).length,'contacts')+modelSheetAction('周末计划 · 1','groups'));break;
      case 'bio':showSheet(current().name,`<p class="sheet-caption" style="font-size:14px">${esc(current().bio)}</p>`);break;
      case 'privacy':showSheet('可见范围','<p class="sheet-caption">当前内容只在此浏览器的本地原型中保存，不同步到真实社交平台或 App。</p>'+modelSheetAction('朋友可见','close-social-sheet'));break;
      case 'location':showSheet('所在位置','<div class="social-map">'+hi('pin')+'</div><p class="sheet-caption">位置示例：沿河步道。未读取设备位置。</p>');break;
      case 'scan':showSheet('扫一扫',`<div class="social-map" style="background:#e8eef3">${hi('qr')}</div><p class="sheet-caption">扫码界面预览，不调用相机。</p>`);break;
      case 'video':showSheet('视频动态',`<div class="social-gallery-view">${art('coast')}</div><p class="sheet-caption">沿河散步的一天 · 视频封面示例</p>`);break;
      case 'nearby':showSheet('附近','<div class="social-map">'+hi('pin')+'</div><p class="sheet-caption">林间书店 · 沿河步道 · 云边公园</p>');break;
      case 'music':showSheet('一起听歌',`<div class="social-collection-card"><p>午后的风 · 轻音乐歌单</p><small>适合慢慢走路的时候听</small></div>`);break;
      case 'stickers':showSheet('表情',`<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:20px;padding:20px 0;font-size:26px">${['☺️','🌿','☁️','🌷','🤍','✨','🍃','🌙','🎧','☕'].map(emoji=>`<button ${act('sticker-select',emoji,`data-value="${emoji}"`)}>${emoji}</button>`).join('')}</div>`);break;
      case 'sticker-select':closeSheet();openChat(active);$('#messageInput').value+=control.dataset.value;applyDraftState();break;
      case 'status':showSheet('设置状态',modelSheetAction('记录生活中','set-status')+modelSheetAction('忙里偷闲','set-status')+modelSheetAction('听歌中','set-status'));break;
      case 'set-status':data.profile.status=control.textContent.trim();keep();closeSheet();renderPage(false);break;
      case 'font':showSheet('消息字号', [13,14,15,16,18].map(size=>modelSheetAction(size+' px','set-font',`data-size="${size}"`)).join(''));break;
      case 'set-font':state.font=Number(control.dataset.size);state.nativeFont=state.font;applyState();save();closeSheet();break;
      case 'about':showSheet('关于此界面','<p class="sheet-caption">Skivu 微信式 / QQ式社交界面设计稿。联系人、聊天、动态、点赞、评论和资料均为本地演示；未连接真实平台。</p>');break;
      case 'visitors':showSheet('最近访客',data.contacts.filter(c=>!c.groupChat&&!c.official).slice(0,3).map(c=>contactRow(c)).join(''));break;
      case 'file-detail':showSheet(control.dataset.name,'<p class="sheet-caption">周末不赶路。\n带上一本书，和一点期待。\n\n此处为本地文件内容预览，不读取手机文件。</p>');break;
      case 'weather':showSheet('天气小助手','<div class="social-weather">杭州<h2>24°</h2><p>晴转多云 · 适合散步</p><small>界面示例天气，非实时数据</small></div>');break;
      case 'notepad':showSheet('随手记','<form class="social-form" id="socialNoteForm"><label>今天的灵感<textarea name="text" placeholder="记下来吧…">'+esc(data.note||'')+'</textarea></label><button class="social-primary">保存笔记</button></form>');break;
      case 'planner':showSheet('一起做计划','<div class="social-details-pair"><span>周六 · 沿河散步</span><small>10:00</small></div><div class="social-details-pair"><span>周日 · 林间书店</span><small>14:00</small></div>');break;
      case 'mute-call':control.classList.toggle('active');control.style.background=control.classList.contains('active')?'#ffffff69':'#ffffff2b';break;
      case 'video-call':toast('视频通话开发中');break;
      case 'hangup':clearInterval(callTimer);back();break;
      case 'close-social-sheet':closeSheet();break;
    }
  });
  document.addEventListener('input',event=>{
    if(event.target.matches('[data-social-search]')){
      const value=event.target.value;
      $('#socialResults').innerHTML=page==='inbox'?inboxRows(value):page==='contacts'?contactsRows(value):searchResults(value);
      if(page==='search')searchQuery=value;
    }
    if(event.target.id==='socialPostText')draftText=event.target.value;
  });
  document.addEventListener('submit',event=>{
    const form=event.target;if(!['socialProfileForm','socialCommentForm','socialGroupForm','socialNoteForm','socialRemarkForm'].includes(form.id))return;
    event.preventDefault();const values=new FormData(form);
    if(form.id==='socialProfileForm'){const name=String(values.get('name')).trim(),account=String(values.get('account')).trim();if(!name||!account)return;data.profile={...data.profile,name,account,bio:String(values.get('bio')).trim(),city:String(values.get('city')).trim()};keep();closeSheet();sync();renderPage(false)}
    if(form.id==='socialCommentForm'){const text=String(values.get('text')).trim(),post=data.posts.find(p=>p.id===form.dataset.post);if(!text||!post)return;post.comments.push({name:data.profile.name,text});keep();closeSheet();renderPage(false)}
    if(form.id==='socialGroupForm'){const name=String(values.get('name')).trim(),members=values.getAll('members');if(!name||!members.length){toast('请命名并至少选择一位朋友');return}const id='group-'+Date.now();data.contacts.push({id,name,groupChat:true,group:'群聊',bio:'一起分享生活与计划。',snippet:'群聊已创建',time:'刚刚',unread:0,members});data.threads[id]=[{id:Date.now(),role:'assistant',text:'群聊已创建。一起聊点什么吧。',time:'刚刚'}];keep();closeSheet();openChat(id)}
    if(form.id==='socialNoteForm'){data.note=String(values.get('text')).slice(0,2000);keep();closeSheet();toast('已保存在本地')}
    if(form.id==='socialRemarkForm'){const name=String(values.get('name')).trim();if(!name)return;current().name=name;state.role=name;keep();closeSheet();sync()}
  });
  const file=document.createElement('input');file.type='file';file.accept='image/png,image/jpeg,image/webp';file.id='socialPostFile';file.hidden=true;document.body.append(file);
  $('#nativeToggle').addEventListener('click',()=>{nativeView=!nativeView;state.nativeView=nativeView;applyState();save()});
  $('#fontSize').addEventListener('input',event=>{if(nativeView){state.nativeFont=Number(event.target.value);applyState();save()}},true);
  addEventListener('message',event=>{if(event.origin!==location.origin||event.source!==parent||!event.data||event.data.type!=='skivu-preview-drawer')return;if(['left','right','none'].includes(event.data.side))setDrawer(event.data.side)});
  $('#socialPage').addEventListener('scroll',()=>{$('#chatPlane').classList.toggle('moments-scrolled',page==='moments'&&$('#socialPage').scrollTop>130)},{passive:true});
  file.addEventListener('change',()=>{const image=file.files[0];if(!image)return;if(!['image/png','image/jpeg','image/webp'].includes(image.type)||image.size>(window.SKIVU_HOSTED?100:700)*1024){toast(window.SKIVU_HOSTED?'请选择100KB以内的PNG、JPG或WebP图片':'请选择700KB以内的PNG、JPG或WebP图片');file.value='';return}const reader=new FileReader();reader.onload=()=>{if(uploadTarget==='profile'){data.profile.avatar=reader.result;keep();const button=document.querySelector('.social-form-portrait');if(button)button.innerHTML=portrait('self','big')+'<span>更换头像</span>'}else{if(draftImages.length<9)draftImages.push(reader.result);closeSheet();renderPage(false)}file.value=''};reader.readAsDataURL(image)});
  $('#resetPreview').onclick=()=>{stopStream();const mode=state.mode;data=initialData();active='ski';nativeView=true;state={...defaults,mode,nativeView:true};messages=structuredClone(data.threads.ski);trail=[];page='inbox';draftText='';draftImages=[];postMenu=null;$('#messageInput').value='';renderMessages();renderFolders();applyState();save();setDrawer('none');closeSheet();toast('已恢复社交模式示例')};
  messages=structuredClone(data.threads[active]||seed);state.role=current().name;state.avatar=current().avatar||null;
  renderMessages();renderFolders();applyState();
  window.SocialPreview={go:target=>go(target),switchTab:target=>{trail=[];go(target,{replace:true})},sync,flushThread,portrait,currentRole:current,page:()=>page,showRole:id=>go('contact',{id}),back:()=>back(),locate:locateMessage,postDraft:()=>({text:$('#socialPostText')?.value.trim()||'',images:[...draftImages]}),
    hostApply(snapshot,{changed=false,view}={}){
      const wasGenerating=!!stream;
      const sameMessages=messages.length===snapshot.messages.length&&messages.every((m,i)=>{const n=snapshot.messages[i];return m.id===n.id&&m.text===n.text&&m.thought===n.thought&&m.authorId===n.authorId&&m.contextNotice===n.contextNotice});
      const oldFollow=$('#messages').scrollHeight-$('#messages').scrollTop-$('#messages').clientHeight<100;
      if(!data.hostReady){data.posts=[];data.requests=[];data.favorites=[];try{const saved=JSON.parse(localStorage.getItem('skivu.host.social.v1')||'null');if(saved&&saved.profile&&typeof saved.profile==='object'){data.profile={...data.profile,...saved.profile}}}catch{}data.hostReady=true}
      if(snapshot.posts)data.posts=snapshot.posts;
      if(snapshot.favorites)data.favorites=snapshot.favorites;
      if(snapshot.ack==='publishPost'){draftText='';draftImages=[];page='moments';trail=[];closeSheet()}
      data.contacts=snapshot.roles.map(r=>({...r,group:'我的朋友',unread:0}));
      data.hostSelectedRoleId=snapshot.selectedRoleId;
      data.threads={[snapshot.selectedRoleId]:snapshot.messages};
      if(changed||page!=='contact'||!data.contacts.some(r=>r.id===active))active=snapshot.selectedRoleId;
      data.hostGroupName=snapshot.chatInfo?.groupMembers?.length?snapshot.chatInfo.title+' ('+(snapshot.chatInfo.groupMembers.length+1)+')':'';
      data.hostGroupKind=snapshot.chatInfo?.groupKind;
      data.hostGroups=(snapshot.chats||[]).filter(c=>c.groupMembers?.length&&c.groupKind!=='channel');
      $('#chatPlane').classList.toggle('is-group-chat',!!data.hostGroupName);
      messages=snapshot.messages;state.role=data.hostGroupName||data.contacts.find(r=>r.id===snapshot.selectedRoleId)?.name||'';
      state.avatar=data.contacts.find(r=>r.id===snapshot.selectedRoleId)?.avatar||null;
      state.mode=snapshot.mode==='qq'?'qq':'wx';state.nativeView=true;nativeView=true;
      state.model=snapshot.model||'选择模型';stream=snapshot.streaming?{host:true}:null;
      data.profile.name=snapshot.userLabel||data.profile.name;
      data.profile.avatar=snapshot.userAvatar||null;
      const profileAvatar=document.querySelector('.social-form-portrait[data-social="upload-profile-avatar"]');
      if(profileAvatar)profileAvatar.innerHTML=portrait('self','big')+'<span>更换头像</span>';
      if(view||changed){page=view||'chat';trail=[];closeSheet()}
      if(snapshot.delta&&page==='chat'&&$('#messages .message').length===messages.length){
        const m=messages.at(-1),el=$('#messages .message:last-child .bubble');if(el)el.textContent=m.text||'正在思考…';
      }else if(changed||!sameMessages||!$('#messages .date-separator'))renderMessages();
      applyState();
      $('#sendButton').setAttribute('aria-label',snapshot.streaming?'停止生成':'发送消息');
      if(changed||view==='chat'||snapshot.ack==='send'||(oldFollow&&(snapshot.streaming||wasGenerating)))bottom();
    }};
  window.SocialPreview.artImage=key=>key.startsWith('data:image/')?`<img src="${esc(key)}" alt="本地选择的图片">`:art(key);
})();
