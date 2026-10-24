/* Hosted navigation owns horizontal swipes; it never opens host drawers. */
(() => {
  const root = $('#chatPlane');
  let state = null, gesture = null, deck = null, suppressClickUntil = 0;
  const scrolls = new Map();
  const tabs = mode => mode === 'qq'
    ? ['inbox', 'channels', 'contacts', 'discover']
    : ['inbox', 'contacts', 'discover', 'me'];
  const pageElement = () => $('#socialPage');
  const reducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  function excluded(target) {
    const blocked = target.closest('input,textarea,select,a,[contenteditable=true],pre,code,.sheet,.wx-chat-panel,.qq-chat-panel,.interaction-screen,.social-post-images,.social-photo-grid,.companion-sticker-grid');
    const button = target.closest('button');
    return blocked || (button && !button.matches('.social-chat-row,.social-contact-row,.social-channel-row'))
      || document.querySelector('#sheetVeil.open,.interaction-screen')
      || (window.getSelection?.()?.isCollapsed === false);
  }
  function valid(value) {
    return value && value.chat === state?.selectedId && value.mode === state?.mode
      && value.page === SocialPreview.page();
  }
  function cleanCard(card) {
    card.removeAttribute('id');
    card.querySelectorAll('[id]').forEach(el => el.removeAttribute('id'));
    card.hidden = false;
    card.classList.add('social-card');
    card.setAttribute('aria-hidden', 'true');
    card.inert = true;
    return card;
  }
  function discard() {
    if (!deck) return;
    clearTimeout(deck.timer);
    deck.surface.style.visibility = deck.visibility;
    deck.element.remove();
    deck = null;
  }
  function beginDeck(target) {
    const surface = pageElement();
    if (state?.mode !== 'wx' || !document.createElement || surface.hidden) return false;
    const box = surface.getBoundingClientRect(), bounds = root.getBoundingClientRect();
    const padding = parseFloat(window.getComputedStyle(surface).paddingTop) || 0;
    if (box.width <= 0 || box.height <= padding) return false;
    scrolls.set(SocialPreview.page(), surface.scrollTop);
    const element = document.createElement('div');
    element.className = 'social-card-deck';
    element.setAttribute('aria-hidden', 'true');
    element.inert = true;
    Object.assign(element.style, {left: (box.left - bounds.left) + 'px', top: (box.top - bounds.top + padding) + 'px',
      width: box.width + 'px', height: (box.height - padding) + 'px'});
    const current = cleanCard(surface.cloneNode(true));
    current.setAttribute('data-card-page', SocialPreview.page());
    element.append(current);
    root.append(element);
    current.scrollTop = surface.scrollTop;
    deck = {element, current, surface, visibility: surface.style.visibility, width: box.width,
      page: SocialPreview.page(), mode: state.mode, chat: state.selectedId, phase: 'dragging', target: null,
      incoming: null, offset: 0, timer: null, queued: null};
    surface.style.visibility = 'hidden';
    selectCard(target);
    paint(0);
    return true;
  }
  function selectCard(target) {
    if (!deck || deck.target === target) return;
    deck.incoming?.remove();
    deck.incoming = null;
    deck.target = target;
    if (!target) return;
    const incoming = document.createElement('div');
    incoming.className = 'social-page';
    incoming.innerHTML = SocialPreview.previewTab(target);
    cleanCard(incoming);
    incoming.setAttribute('data-card-page', target);
    deck.element.append(incoming);
    incoming.scrollTop = scrolls.get(target) || 0;
    deck.incoming = incoming;
  }
  function paint(offset) {
    if (!deck) return;
    deck.offset = offset;
    const distance = deck.width + 12, progress = Math.min(1, Math.abs(offset) / distance);
    const rounding = Math.sin(progress * Math.PI) * 12;
    deck.current.style.transform = 'translate3d(' + offset + 'px,0,0) scale(' + (1 - .025 * progress) + ')';
    deck.current.style.borderRadius = rounding + 'px';
    if (deck.incoming) {
      const direction = tabs('wx').indexOf(deck.target) > tabs('wx').indexOf(deck.page) ? 1 : -1;
      deck.incoming.style.transform = 'translate3d(' + (offset + direction * distance) + 'px,0,0) scale(' + (.975 + .025 * progress) + ')';
      deck.incoming.style.borderRadius = rounding + 'px';
    }
  }
  function settle(commit) {
    if (!deck) return;
    const active = deck;
    active.phase = 'settling';
    const target = commit ? active.target : null;
    const finish = () => {
      if (deck !== active) return;
      const allowed = valid(active), queued = active.queued;
      // Commit under the end frame so the old tab cannot flash through.
      if (allowed && target) {
        SocialPreview.switchTab(target, {animate: false});
        active.surface.scrollTop = scrolls.get(target) || 0;
      }
      discard();
      if (allowed && queued && queued !== SocialPreview.page()) navigate(queued);
    };
    if (reducedMotion()) { finish(); return; }
    active.element.classList.add('is-settling');
    active.current.getBoundingClientRect();
    const direction = target && tabs('wx').indexOf(target) > tabs('wx').indexOf(active.page) ? -1 : 1;
    paint(target ? direction * (active.width + 12) : 0);
    active.current.addEventListener('transitionend', event => {
      if (event.target === active.current && event.propertyName === 'transform') finish();
    });
    active.timer = setTimeout(finish, 310);
  }
  function navigate(target) {
    const roots = tabs('wx');
    if (state?.mode !== 'wx' || !roots.includes(SocialPreview.page()) || !roots.includes(target)) {
      gesture = null; discard(); return false;
    }
    if (deck?.phase === 'settling') { deck.queued = target; return true; }
    gesture = null; discard();
    if (target === SocialPreview.page()) return true;
    if (!beginDeck(target)) return false;
    settle(true);
    return true;
  }
  function start(x, y, target) {
    gesture = null;
    if (!state || deck?.phase === 'settling' || excluded(target)) return;
    const page = SocialPreview.page();
    if (!tabs(state.mode).includes(page) && page !== 'chat') return;
    const box = root.getBoundingClientRect(), height = Math.min(144, box.height * .4);
    // Reserved for the passive Flutter edge control; vertical scroll remains free.
    if (x >= box.right - 24 && y >= box.top + (box.height - height) / 2 && y <= box.top + (box.height + height) / 2) return;
    gesture = {x, y, page, chat: state.selectedId, mode: state.mode, at: Date.now(), direction: null};
  }
  function move(x, y, event) {
    if (!gesture) return;
    if (!valid(gesture)) { gesture = null; discard(); return; }
    const dx = x - gesture.x, dy = y - gesture.y;
    if (!gesture.direction) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx) * .65) { gesture = null; return; }
      if (Math.abs(dx) > 20 && Math.abs(dx) > Math.abs(dy) * 1.8) gesture.direction = 'horizontal';
    }
    if (gesture.direction !== 'horizontal') return;
    if (event.cancelable) event.preventDefault();
    if (gesture.mode !== 'wx' || gesture.page === 'chat') return;
    const pages = tabs('wx'), target = pages[pages.indexOf(gesture.page) + (dx < 0 ? 1 : -1)] || null;
    if (!deck && !beginDeck(target)) return;
    selectCard(target);
    paint(target ? Math.max(-deck.width, Math.min(deck.width, dx)) : Math.max(-28, Math.min(28, dx * .18)));
  }
  function end(x, y) {
    const g = gesture; gesture = null;
    if (!g || g.direction !== 'horizontal') return;
    suppressClickUntil = Date.now() + 350;
    if (!valid(g)) { discard(); return; }
    const dx = x - g.x, dy = y - g.y;
    const commit = Math.abs(dx) >= 64 && Math.abs(dx) >= Math.abs(dy) * 1.8;
    if (deck) {
      const pages = tabs('wx'), target = pages[pages.indexOf(g.page) + (dx < 0 ? 1 : -1)] || null;
      selectCard(target);
      settle(commit && !!target);
      return;
    }
    if (!commit || Date.now() - g.at > 900) return;
    if (g.page === 'chat') { if (dx > 0) SocialPreview.back(); return; }
    const pages = tabs(g.mode), next = pages[pages.indexOf(g.page) + (dx < 0 ? 1 : -1)];
    if (next) SocialPreview.switchTab(next);
  }
  function cancel() {
    if (gesture?.direction === 'horizontal') suppressClickUntil = Date.now() + 350;
    gesture = null;
    if (deck?.phase === 'dragging') settle(false);
  }
  function consumeClick(event) {
    if (Date.now() >= suppressClickUntil || !root.contains(event.target)) return false;
    event.preventDefault(); event.stopImmediatePropagation(); return true;
  }
  root.addEventListener('touchstart', event => {
    if (event.touches.length !== 1) { cancel(); return; }
    const p = event.touches[0]; start(p.clientX, p.clientY, event.target);
  }, {passive: true});
  root.addEventListener('touchmove', event => {
    if (event.touches.length !== 1) { cancel(); return; }
    const p = event.touches[0]; move(p.clientX, p.clientY, event);
  }, {passive: false});
  root.addEventListener('touchend', event => {
    if (event.touches.length || event.changedTouches.length !== 1) { cancel(); return; }
    const p = event.changedTouches[0]; end(p.clientX, p.clientY);
  }, {passive: true});
  root.addEventListener('touchcancel', cancel, {passive: true});
  root.addEventListener('click', event => {
    if (Date.now() < suppressClickUntil) { event.preventDefault(); event.stopImmediatePropagation(); }
  }, true);
  window.addEventListener?.('resize', () => { gesture = null; discard(); });
  window.SocialNavigation = {navigate, consumeClick, update(value) {
    if (state && (state.mode !== value.mode || state.selectedId !== value.selectedId)) {
      gesture = null; discard(); scrolls.clear();
    } else if ((gesture && !valid(gesture)) || (deck && !valid(deck))) {
      gesture = null; discard();
    }
    state = value;
  }};
})();
