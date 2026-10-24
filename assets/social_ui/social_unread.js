/* Real host-owned unread state; never persisted separately in the presenter. */
(() => {
  let snapshot=null, visibilityKey='';
  const count=value=>Number.isFinite(value)?Math.max(0,Math.min(1e9,Math.floor(value))):0;
  const label=value=>count(value)>99?'99+':String(count(value));
  function total(tab='inbox') {
    return (snapshot?.chats||[]).filter(c=>!c.muted&&(snapshot.mode!=='qq'||(tab==='channels'?c.groupKind==='channel':c.groupKind!=='channel'))).reduce((sum,c)=>sum+count(c.unread),0);
  }
  function badge(value,dot=false) {
    const n=count(value);
    return n?`<span class="social-unread-badge${dot?' is-dot':''}" aria-label="${n} 条未读消息">${dot?'':label(n)}</span>`:'';
  }
  function visibility(page) {
    if(!snapshot)return;
    const visible=page==='chat'&&document.visibilityState!=='hidden';
    const key=snapshot.selectedId+':'+visible;
    if(key===visibilityKey)return;
    visibilityKey=key;
    window.SkivuHost?.emit('chatVisibility',{visible});
  }
  window.SocialUnread={update(value){snapshot=value},total,badge,
    title(base,tab='inbox'){const n=total(tab);return base+(n?'('+label(n)+')':'')},visibility};
  document.addEventListener('visibilitychange',()=>visibility(window.SocialPreview?.page()));
  addEventListener('pagehide',()=>{if(snapshot)window.SkivuHost?.emit('chatVisibility',{visible:false});visibilityKey=''});
})();
