/* Hosted social navigation owns horizontal swipes; it never opens host drawers. */
(() => {
  const root = $('#chatPlane');
  let state = null, gesture = null, suppressClickUntil = 0;
  const tabs = mode => mode === 'qq'
    ? ['inbox', 'channels', 'contacts', 'discover']
    : ['inbox', 'contacts', 'discover', 'me'];
  function excluded(target) {
    const blocked = target.closest('input,textarea,select,a,[contenteditable=true],pre,code,.sheet,.wx-chat-panel,.qq-chat-panel,.interaction-screen,.social-post-images,.social-photo-grid,.companion-sticker-grid');
    const button = target.closest('button');
    return blocked || (button && !button.matches('.social-chat-row,.social-contact-row,.social-channel-row'))
      || document.querySelector('#sheetVeil.open,.interaction-screen')
      || (window.getSelection?.()?.isCollapsed === false);
  }
  function start(x, y, target) {
    gesture = null;
    if (!state || excluded(target)) return;
    const page = SocialPreview.page();
    if (!tabs(state.mode).includes(page) && page !== 'chat') return;
    const box = root.getBoundingClientRect(), height = Math.min(144, box.height * .4);
    // Reserved for the passive Flutter edge control. Vertical scrolling still
    // reaches the WebView; horizontal pulls here must not also change a tab.
    if (x >= box.right - 24 && y >= box.top + (box.height - height) / 2 && y <= box.top + (box.height + height) / 2) return;
    gesture = {x, y, page, chat: state.selectedId, mode: state.mode, at: Date.now(), direction: null};
  }
  function move(x, y, event) {
    if (!gesture) return;
    const dx = x - gesture.x, dy = y - gesture.y;
    if (!gesture.direction) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx) * .65) { gesture = null; return; }
      if (Math.abs(dx) > 20 && Math.abs(dx) > Math.abs(dy) * 1.8) gesture.direction = 'horizontal';
    }
    if (gesture?.direction === 'horizontal' && event.cancelable) event.preventDefault();
  }
  function end(x, y) {
    const g = gesture; gesture = null;
    if (!g || g.direction !== 'horizontal' || Date.now() - g.at > 900
        || g.chat !== state?.selectedId || g.mode !== state?.mode || g.page !== SocialPreview.page()) return;
    const dx = x - g.x, dy = y - g.y;
    if (Math.abs(dx) < 64 || Math.abs(dx) < Math.abs(dy) * 1.8) return;
    if (g.page === 'chat') {
      if (dx > 0) { SocialPreview.back(); suppressClickUntil = Date.now() + 350; }
      return;
    }
    const pages = tabs(g.mode), next = pages[pages.indexOf(g.page) + (dx < 0 ? 1 : -1)];
    if (next) { SocialPreview.switchTab(next); suppressClickUntil = Date.now() + 350; }
  }
  root.addEventListener('touchstart', event => {
    if (event.touches.length !== 1) { gesture = null; return; }
    const p = event.touches[0]; start(p.clientX, p.clientY, event.target);
  }, {passive: true});
  root.addEventListener('touchmove', event => {
    if (event.touches.length !== 1) { gesture = null; return; }
    const p = event.touches[0]; move(p.clientX, p.clientY, event);
  }, {passive: false});
  root.addEventListener('touchend', event => {
    if (event.touches.length || event.changedTouches.length !== 1) { gesture = null; return; }
    const p = event.changedTouches[0]; end(p.clientX, p.clientY);
  }, {passive: true});
  root.addEventListener('touchcancel', () => { gesture = null; }, {passive: true});
  root.addEventListener('click', event => {
    if (Date.now() < suppressClickUntil) { event.preventDefault(); event.stopImmediatePropagation(); }
  }, true);
  window.SocialNavigation = {update(value) {
    if (state && (state.mode !== value.mode || state.selectedId !== value.selectedId)) gesture = null;
    state = value;
  }};
})();
