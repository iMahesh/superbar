/* Superbar site: a working model of the bar, plus small demos of single features.
   The rules here are ports of the app's own: ClickResolver, SearchRanker, AppVisibility,
   EdgeReveal timings, and WorkArea.fit. Everything runs in the browser. */
(() => {
  'use strict';

  // Set this to the repository's URL to show a "View on GitHub" button in the hero.
  const REPO_URL = '';

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const el = (tag, attrs = {}, ...kids) => {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') node.className = v;
      else if (k === 'html') node.innerHTML = v;
      else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat()) if (kid != null && kid !== false) node.append(kid);
    return node;
  };
  const icon = (id, cls = '') => {
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    if (cls) s.setAttribute('class', cls);
    s.setAttribute('aria-hidden', 'true');
    const u = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    u.setAttribute('href', '#' + id);
    s.append(u);
    return s;
  };
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

  if (REPO_URL) { const a = $('#repo-link'); a.href = REPO_URL; a.hidden = false; }

  // ---------------------------------------------------------------- Rules (ports)

  /** ClickResolver.resolve */
  function resolveClick(s) {
    if (!s.running) return 'launch';
    if (s.hidden) return 'unhide';
    const total = s.visible + s.minimized;
    if (s.active) {
      if (total >= 2) return 'pick';
      if (s.visible === 1) return 'minimize';
      if (s.minimized === 1) return 'restore';
      return 'reopen';
    }
    if (s.visible > 0) return 'focus';
    if (s.minimized > 0) return 'restore';
    return 'reopen';
  }

  /** SearchRanker: prefix, then word start, then contains; then shorter names, then A to Z. */
  const fold = s => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const words = name => name.replace(/([a-z])([A-Z])/g, '$1 $2').split(/[^A-Za-z0-9]+/).filter(Boolean);
  function matchKind(name, query) {
    const q = fold(query.trim());
    if (!q) return null;
    const n = fold(name);
    if (n.startsWith(q)) return 0;
    if (words(name).some(w => fold(w).startsWith(q))) return 1;
    if (n.includes(q)) return 2;
    return null;
  }
  function rank(items, query) {
    return items.map(it => ({ it, k: matchKind(it.name, query) }))
      .filter(x => x.k != null)
      .sort((a, b) => a.k - b.k || a.it.name.length - b.it.name.length || a.it.name.localeCompare(b.it.name))
      .map(x => ({ ...x.it, kind: x.k }));
  }
  const KIND = ['starts with', 'word starts', 'contains'];

  /** AppVisibility.isShown, with window state known. */
  const isShown = app => app.pinned || (app.running && app.windows.length > 0);

  // ---------------------------------------------------------------- The live demo

  const stage = $('#stage');
  const scaler = $('#stage-scaler');
  const desktop = $('#desktop');
  const bar = $('#bar');
  const layer = $('#layer');
  const toastEl = $('#toast');
  const W = 1100, H = 640;
  let scale = 1;

  function fit() {
    scale = scaler.clientWidth / W;
    stage.style.transform = `scale(${scale})`;
    scaler.style.height = `${H * scale}px`;
  }
  new ResizeObserver(fit).observe(scaler);
  fit();

  /** An element's box in stage coordinates. */
  function box(node) {
    const r = node.getBoundingClientRect(), s = stage.getBoundingClientRect();
    return { x: (r.left - s.left) / scale, y: (r.top - s.top) / scale, w: r.width / scale, h: r.height / scale };
  }

  let seq = 0, cascade = 0;
  const KINDS = { finder: 'folder', browser: 'web', mail: 'mail', notes: 'note', terminal: 'term', music: 'lines', photos: 'lines', calc: 'lines', maps: 'lines' };
  function makeWindow(app, title, extra = {}) {
    const i = cascade++ % 7;
    return { id: 'w' + (++seq), app: app.id, title, min: false, minAt: 0, x: 70 + i * 44, y: 34 + i * 30, w: 560, h: 360, kind: KINDS[app.id] || 'lines', ...extra };
  }

  const apps = [
    { id: 'finder', name: 'Finder', icon: 'app-finder', glow: '#5aa8ff', pinned: true, running: true, windows: [] },
    { id: 'browser', name: 'Browser', icon: 'app-browser', glow: '#2fd3b8', pinned: true, running: true, windows: [] },
    { id: 'mail', name: 'Mail', icon: 'app-mail', glow: '#ff8a6b', pinned: true, running: true, windows: [] },
    { id: 'notes', name: 'Notes', icon: 'app-notes', glow: '#ffd75e', pinned: true, running: false, windows: [] },
    { id: 'music', name: 'Music', icon: 'app-music', glow: '#b48cff', pinned: true, running: false, windows: [] },
    { id: 'terminal', name: 'Terminal', icon: 'app-terminal', glow: '#7ee787', pinned: false, running: true, windows: [] },
    { id: 'photos', name: 'Photos', icon: 'app-photos', glow: '#ffb347', pinned: false, running: false, windows: [] },
    { id: 'calc', name: 'Calculator', icon: 'app-calc', glow: '#fb923c', pinned: false, running: false, windows: [] },
    { id: 'maps', name: 'Maps', icon: 'app-maps', glow: '#60d394', pinned: false, running: false, windows: [] },
  ];
  const byId = id => apps.find(a => a.id === id);
  const order = ['finder', 'browser', 'mail', 'notes', 'music']; // pinned order; unpinned follow in launch order
  let launchOrder = ['terminal'];

  const state = { z: [], active: null, desktopHidden: null, tray: { trash: true, wifi: true, sound: true, battery: true },
                  wifi: true, volume: 62, muted: false, small: false,
                  calMonth: null, calSel: null, transient: null, hover: null };

  // Starting windows.
  (() => {
    const b = byId('browser'), m = byId('mail'), t = byId('terminal');
    const w1 = makeWindow(b, 'Superbar — Release notes', { x: 120, y: 40, w: 600, h: 380 });
    const w2 = makeWindow(b, 'Weather in Lisbon', { x: 200, y: 90, w: 560, h: 360, min: true, minAt: 1 });
    const w3 = makeWindow(m, 'Inbox — 3 unread', { x: 430, y: 120, w: 560, h: 360 });
    const w4 = makeWindow(t, 'zsh — 80×24', { x: 60, y: 200, w: 520, h: 300 });
    b.windows.push(w1, w2); m.windows.push(w3); t.windows.push(w4);
    state.z = [w3.id, w1.id, w4.id, w2.id];
    state.active = 'mail';
  })();

  const allWindows = () => apps.flatMap(a => a.windows);
  const win = id => allWindows().find(w => w.id === id);
  const appOf = w => byId(w.app);
  const visibleWindows = app => app.windows.filter(w => !w.min && !(state.desktopHidden || []).includes(w.id));
  const frontWindow = () => state.z.map(win).find(w => w && !w.min && !(state.desktopHidden || []).includes(w.id));

  function barApps() {
    const ids = [...order, ...launchOrder.filter(id => !order.includes(id))];
    return ids.map(byId).filter(isShown);
  }

  // ----- toast
  let toastTimer;
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 2600);
  }

  // ----- window actions
  function raise(w) {
    w.min = false;
    state.z = [w.id, ...state.z.filter(id => id !== w.id)];
    state.active = w.app;
  }
  function endShowDesktop() { state.desktopHidden = null; }
  function focusApp(app) {
    endShowDesktop();
    const w = state.z.map(win).find(x => x && x.app === app.id && !x.min);
    if (w) raise(w); else state.active = app.id;
  }
  function restoreRecent(app) {
    endShowDesktop();
    const w = app.windows.filter(x => x.min).sort((a, b) => b.minAt - a.minAt)[0];
    if (w) raise(w);
  }
  function minimize(w) {
    w.min = true; w.minAt = Date.now();
    const next = frontWindow();
    state.active = next ? next.app : null;
  }
  function closeWindow(w) {
    const app = appOf(w);
    app.windows = app.windows.filter(x => x.id !== w.id);
    state.z = state.z.filter(id => id !== w.id);
    if (state.active === app.id && !visibleWindows(app).length) {
      const next = frontWindow();
      state.active = next ? next.app : app.id;
    }
  }
  const TITLES = { finder: 'Home', browser: 'New Tab', mail: 'New Message', notes: 'Shopping list', music: 'Library', terminal: 'zsh — 80×24', photos: 'Library', calc: 'Calculator', maps: 'Lisbon' };
  function newWindow(app, title) {
    endShowDesktop();
    if (!app.running) {
      app.running = true;
      if (!order.includes(app.id) && !launchOrder.includes(app.id)) launchOrder.push(app.id);
    }
    const w = makeWindow(app, title || TITLES[app.id] || app.name);
    app.windows.push(w);
    raise(w);
    return w;
  }
  function launch(app) {
    newWindow(app);
    toast(`${app.name} opens`);
  }
  function quit(app) {
    app.windows.forEach(w => { state.z = state.z.filter(id => id !== w.id); });
    app.windows = [];
    app.running = false;
    launchOrder = launchOrder.filter(id => id !== app.id);
    if (state.active === app.id) { const n = frontWindow(); state.active = n ? n.app : null; }
  }

  /** A left click on an app button, decided from the state at mouse-down, as in the app. */
  function clickApp(app, btn, shift) {
    closeTransient();
    if (shift) { newWindow(app); render(); return; }
    const vis = visibleWindows(app).length;
    const action = resolveClick({ running: app.running, active: app.running && isFront(app), hidden: false,
                                  visible: vis, minimized: app.windows.filter(w => w.min).length });
    switch (action) {
      case 'launch': launch(app); break;
      case 'focus': focusApp(app); break;
      case 'restore': restoreRecent(app); break;
      case 'minimize': minimize(visibleWindows(app)[0]); break;
      case 'pick': render(); showPreview(app, btn, true); return;
      case 'reopen': newWindow(app); break;
    }
    render();
  }
  /** "Active" means in front: its window is the front one, or it was activated with none. */
  function isFront(app) {
    const f = frontWindow();
    return f ? f.app === app.id : state.active === app.id;
  }

  // ----- rendering: desktop
  function windowBody(w) {
    switch (w.kind) {
      case 'web': return el('div', {}, el('div', { class: 'wb-url' }, w.title.includes('Weather') ? 'weather.example' : 'superbar.example/notes'), el('div', { class: 'wb-hero' }), el('div', { class: 'wb-lines' }, el('span', { style: 'width:90%' }), el('span', { style: 'width:75%' }), el('span', { style: 'width:82%' })));
      case 'mail': return el('div', { class: 'wb-mail' }, el('div', { class: 'list' }, el('span'), el('span'), el('span'), el('span')), el('div', { class: 'wb-lines' }, el('span', { style: 'width:60%' }), el('span', { style: 'width:95%' }), el('span', { style: 'width:88%' }), el('span', { style: 'width:70%' })));
      case 'term': return el('div', { class: 'wb-term', html: 'you@mac ~ % ./build.sh --open<br>Building Superbar…<br>Installed ~/Applications/Superbar.app<br>you@mac ~ % <span class="cursor">▍</span>' });
      case 'note': return el('div', { class: 'wb-note' }, el('span', { style: 'width:50%' }), el('span', { style: 'width:80%' }), el('span', { style: 'width:70%' }));
      case 'folder': return el('div', { class: 'wb-folder' }, ...Array.from({ length: 8 }, () => el('i')));
      case 'trash': return el('div', { class: 'wb-empty' }, 'Trash is empty');
      default: return el('div', { class: 'wb-lines' }, el('span', { style: 'width:70%' }), el('span', { style: 'width:90%' }), el('span', { style: 'width:60%' }));
    }
  }
  function renderDesktop() {
    desktop.classList.toggle('small', state.small);
    const front = frontWindow();
    const existing = new Map($$('.win', desktop).map(n => [n.dataset.id, n]));
    const ids = new Set();
    // Back to front so later windows stack on top.
    [...state.z].reverse().forEach((id, i) => {
      const w = win(id); if (!w) return;
      ids.add(id);
      let node = existing.get(id);
      if (!node) {
        node = el('div', { class: 'win', 'data-id': id },
          el('div', { class: 'win-bar' },
            el('div', { class: 'win-dots' },
              el('button', { class: 'd-close', 'aria-label': 'Close window', onclick: e => { e.stopPropagation(); closeWindow(win(id)); render(); } }),
              el('button', { class: 'd-min', 'aria-label': 'Minimize window', onclick: e => { e.stopPropagation(); minimize(win(id)); render(); } }),
              el('button', { class: 'd-full', 'aria-label': 'Full screen', onclick: e => { e.stopPropagation(); toast('In full screen, Superbar slides away. See the demo below.'); } })),
            el('div', { class: 'win-title' })),
          el('div', { class: 'win-body' }, windowBody(w)));
        node.addEventListener('pointerdown', () => { const x = win(id); if (x) { endShowDesktop(); raise(x); closeTransient(); render(); } });
        dragBy($('.win-bar', node), id);
        desktop.append(node);
      }
      $('.win-title', node).textContent = w.title;
      node.style.cssText = `left:${w.x}px;top:${w.y}px;width:${w.w}px;height:${w.h}px;z-index:${i + 1}`;
      const hidden = w.min || (state.desktopHidden || []).includes(id);
      node.classList.toggle('min', hidden);
      node.classList.toggle('inactive', !front || front.id !== id);
      node.setAttribute('aria-hidden', hidden ? 'true' : 'false');
    });
    for (const [id, node] of existing) if (!ids.has(id)) node.remove();
  }
  function dragBy(handle, id) {
    handle.addEventListener('pointerdown', e => {
      if (e.target.closest('button')) return;
      const w = win(id); if (!w) return;
      const sx = e.clientX, sy = e.clientY, ox = w.x, oy = w.y;
      handle.setPointerCapture(e.pointerId);
      const move = ev => {
        w.x = clamp(ox + (ev.clientX - sx) / scale, -w.w + 80, W - 80);
        w.y = clamp(oy + (ev.clientY - sy) / scale, 0, H - 70);
        const n = desktop.querySelector(`[data-id="${id}"]`);
        if (n) { n.style.left = w.x + 'px'; n.style.top = w.y + 'px'; }
      };
      const up = () => { handle.removeEventListener('pointermove', move); handle.removeEventListener('pointerup', up); };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', up);
    });
  }

  // ----- rendering: bar
  function trayIcon(key) {
    if (key === 'wifi') return state.wifi ? 'i-wifi' : 'i-wifi-off';
    if (key === 'sound') return state.muted || state.volume === 0 ? 'i-mute' : state.volume < 40 ? 'i-sound-low' : 'i-sound';
    return { trash: 'i-trash', battery: 'i-battery' }[key];
  }
  const TRAY_LABEL = { trash: () => 'Trash', wifi: () => state.wifi ? 'Wi-Fi: connected' : 'Wi-Fi: off', sound: () => state.muted ? 'Sound: muted' : `Volume ${state.volume}%`, battery: () => 'Battery 76%' };

  function renderBar() {
    bar.classList.toggle('small', state.small);
    const prev = new Set($$('.appbtn', bar).map(n => n.dataset.app));
    bar.replaceChildren();
    bar.append(
      el('button', { class: 'orb' + (state.transient?.kind === 'start' ? ' on' : ''), 'aria-label': 'Start', 'data-owner': 'start', onclick: () => toggleStart() }, icon('i-orb')),
      el('button', { class: 'mc', 'aria-label': 'Mission Control', title: 'Mission Control', onclick: () => missionControl() }, icon('i-mc')));
    const strip = el('div', { class: 'apps' });
    for (const app of barApps()) {
      const vis = visibleWindows(app).length, total = app.windows.length;
      const btn = el('button', {
        class: ['appbtn', total > 0 && app.running ? 'lit' : '', total > 0 && isFront(app) ? 'active' : '', total > 1 ? 'stack' : '',
                state.hover === app.id ? 'hot' : '', prev.size && !prev.has(app.id) ? 'enter' : ''].join(' '),
        'data-app': app.id, 'data-owner': 'app-' + app.id,
        'aria-label': `${app.name}, ${!app.running ? 'not running' : total === 1 ? '1 window' : total + ' windows'}`,
        title: app.name, style: `--glow:${app.glow}`,
      }, el('span', { class: 'frame' }), el('span', { class: 'glow' }), icon(app.icon));
      btn.addEventListener('click', e => clickApp(app, btn, e.shiftKey));
      btn.addEventListener('auxclick', e => { if (e.button === 1) { e.preventDefault(); newWindow(app); render(); } });
      btn.addEventListener('contextmenu', e => { e.preventDefault(); e.stopPropagation(); appMenu(app, btn); });
      btn.addEventListener('pointerenter', e => { if (e.pointerType === 'mouse') hoverIn(app, btn); });
      btn.addEventListener('pointerleave', e => { if (e.pointerType === 'mouse') hoverOut(); });
      strip.append(btn);
    }
    bar.append(strip, el('div', { class: 'spacer' }));
    const tray = el('div', { class: 'tray' });
    for (const key of ['trash', 'wifi', 'sound', 'battery']) {
      if (!state.tray[key]) continue;
      tray.append(el('button', { class: (key === 'battery' ? 'bat ' : '') + (state.transient?.kind === key ? 'on' : ''), 'data-owner': key, 'aria-label': TRAY_LABEL[key](), title: TRAY_LABEL[key](), onclick: e => trayClick(key, e.currentTarget) }, icon(trayIcon(key))));
    }
    const now = new Date();
    bar.append(tray,
      el('button', { class: 'clock' + (state.transient?.kind === 'calendar' ? ' on' : ''), 'data-owner': 'calendar', 'aria-label': 'Clock and calendar', onclick: e => toggleCalendar(e.currentTarget) },
        el('span', {}, now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })),
        el('span', {}, now.toLocaleDateString([], { month: 'numeric', day: 'numeric', year: '2-digit' }))),
      el('button', { class: 'showdesk' + (state.desktopHidden ? ' on' : ''), 'aria-label': 'Show desktop', title: 'Show desktop', onclick: () => showDesktop() }));
  }
  bar.addEventListener('contextmenu', e => {
    if (e.target.closest('.appbtn')) return;
    e.preventDefault();
    const b = box(bar);
    const r = stage.getBoundingClientRect();
    openMenu([
      ['Superbar Settings…', () => { closeTransient(); $('#f-settings').scrollIntoView({ behavior: 'smooth', block: 'center' }); }],
      null,
      ['Quit Superbar', () => toast('The demo keeps running. On a Mac, this quits Superbar.')],
    ], (e.clientX - r.left) / scale, b.y, 'bar');
  });

  function render() { renderDesktop(); renderBar(); }

  // ----- transient UI: one at a time
  function closeTransient() {
    if (!state.transient) return;
    state.transient.node?.remove();
    const kind = state.transient.kind;
    state.transient = null;
    clearTimeout(previewHide);
    if (kind !== 'preview' && kind !== 'menu') renderBar();
  }
  function openTransient(kind, node, owner) {
    closeTransient();
    layer.append(node);
    state.transient = { kind, node, owner };
  }
  stage.addEventListener('pointerdown', e => {
    if (!state.transient) return;
    if (e.target.closest('.pop')) return;
    const owner = e.target.closest('[data-owner]')?.dataset.owner;
    if (owner && owner === state.transient.owner) return; // its own button toggles it
    closeTransient();
  }, true);
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && state.transient) { closeTransient(); }
    if (e.key === 'Escape' && $('.mcov', layer)) { $('.mcov', layer).remove(); }
    if (e.key === 'Escape' && e.ctrlKey) { toggleStart(); e.preventDefault(); }
  });

  /** Place a popover above an anchor, centered or right-aligned, inside the stage. */
  function place(node, anchor, align = 'center') {
    node.style.visibility = 'hidden';
    layer.append(node);
    const w = node.offsetWidth, h = node.offsetHeight;
    const barTop = H - (state.small ? 30 : 40);
    let x = align === 'right' ? anchor.x + anchor.w - w : anchor.x + anchor.w / 2 - w / 2;
    x = clamp(x, 6, W - w - 6);
    node.style.left = x + 'px';
    node.style.top = (barTop - h - 6) + 'px';
    node.style.visibility = '';
  }

  // ----- previews
  let previewShow, previewHide;
  function hoverIn(app, btn) {
    state.hover = app.id;
    clearTimeout(previewHide); clearTimeout(previewShow);
    if (!app.running || !app.windows.length) return;
    if (state.transient?.kind === 'preview') { showPreview(app, btn); return; }
    if (state.transient) return;
    previewShow = setTimeout(() => showPreview(app, btn), 400);
  }
  function hoverOut() {
    state.hover = null;
    clearTimeout(previewShow);
    schedulePreviewHide();
  }
  function schedulePreviewHide() {
    clearTimeout(previewHide);
    previewHide = setTimeout(() => {
      if (state.transient?.kind === 'preview' && !state.transient.node.matches(':hover')) closeTransient();
    }, 300);
  }
  function thumbArt(w) {
    const colors = { web: 'linear-gradient(120deg,#1d6fe0,#7a3fd1)', mail: 'linear-gradient(90deg,rgba(255,255,255,.08) 34%,rgba(255,255,255,.03) 34%)', term: '#11141a', note: '#3b3522', folder: 'repeating-linear-gradient(90deg,#5aa2f0 0 26px,transparent 26px 34px)', trash: 'rgba(255,255,255,.04)', lines: 'rgba(255,255,255,.06)' };
    return el('div', { class: 't-pic' }, el('div', { class: 't-bar' }), el('div', { class: 't-art', style: `background:${colors[w.kind] || colors.lines}` }));
  }
  function showPreview(app, btn, pinned = false) {
    const list = [...app.windows.filter(w => !w.min), ...app.windows.filter(w => w.min)];
    if (!list.length) return;
    const node = el('div', { class: 'pop preview', role: 'dialog', 'aria-label': `${app.name} windows` });
    for (const w of list) {
      const t = el('div', { class: 'thumb', role: 'button', tabindex: '0', 'aria-label': `${w.title}${w.min ? ', minimized' : ''}` },
        el('div', { class: 't-title' }, icon(app.icon), el('span', {}, w.title)),
        thumbArt(w),
        w.min ? el('div', { class: 't-min' }, 'Minimized') : null,
        el('button', { class: 't-close', 'aria-label': `Close ${w.title}`, onclick: e => {
          e.stopPropagation(); closeWindow(w); render();
          if (app.windows.length) showPreview(app, $(`.appbtn[data-app="${app.id}"]`, bar) || btn, true); else closeTransient();
        } }, '×'));
      const go = () => { closeTransient(); endShowDesktop(); raise(w); render(); };
      t.addEventListener('click', go);
      t.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); } });
      node.append(t);
    }
    node.addEventListener('pointerenter', () => clearTimeout(previewHide));
    node.addEventListener('pointerleave', () => schedulePreviewHide());
    closeTransient();
    place(node, box(btn));
    state.transient = { kind: 'preview', node, owner: pinned ? 'app-' + app.id : null };
  }

  // ----- context menus
  function openMenu(items, x, barTop, owner) {
    const node = el('div', { class: 'pop menu', role: 'menu' });
    for (const item of items) {
      if (!item) { node.append(el('div', { class: 'sep' })); continue; }
      node.append(el('button', { role: 'menuitem', onclick: () => { closeTransient(); item[1](); render(); } }, item[0]));
    }
    closeTransient();
    node.style.visibility = 'hidden';
    layer.append(node);
    node.style.left = clamp(x, 6, W - node.offsetWidth - 6) + 'px';
    node.style.top = (barTop - node.offsetHeight - 4) + 'px';
    node.style.visibility = '';
    state.transient = { kind: 'menu', node, owner };
    node.querySelector('button')?.focus({ preventScroll: true });
  }
  function appMenu(app, btn) {
    const items = app.windows.map(w => [w.min ? `${w.title} (minimized)` : w.title, () => { endShowDesktop(); raise(w); }]);
    if (items.length) items.push(null);
    items.push([app.running ? 'Open New Window' : `Open ${app.name}`, () => app.running ? newWindow(app) : launch(app)]);
    if (app.id !== 'finder') items.push(app.pinned ? ['Unpin from Superbar', () => { app.pinned = false; const i = order.indexOf(app.id); if (i >= 0) order.splice(i, 1); if (app.running && !launchOrder.includes(app.id)) launchOrder.push(app.id); }]
                                                   : ['Pin to Superbar', () => { app.pinned = true; order.push(app.id); launchOrder = launchOrder.filter(id => id !== app.id); }]);
    if (app.windows.length === 1) items.push(['Close Window', () => closeWindow(app.windows[0])]);
    else if (app.windows.length > 1) items.push(['Close All Windows', () => [...app.windows].forEach(closeWindow)]);
    if (app.running && app.id !== 'finder') items.push(null, ['Quit', () => quit(app)]);
    const b = box(btn);
    openMenu(items, b.x, b.y, 'app-' + app.id);
  }

  // ----- Start menu
  const startApps = () => apps.map(a => ({ id: a.id, name: a.name, icon: a.icon }));
  const PLACES = [['Home', 'i-home'], ['Documents', 'i-doc'], ['Downloads', 'i-down'], ['Pictures', 'i-pic'], ['Music', 'i-note'], null, ['Applications', 'i-grid'], ['System Settings', 'i-gear']];
  function toggleStart() { state.transient?.kind === 'start' ? closeTransient() : openStart(); }
  function openStart(query = '') {
    let sel = 0, results = [];
    const list = el('div', { class: 'start-list', role: 'listbox', 'aria-label': 'Apps' });
    const input = el('input', { type: 'search', placeholder: 'Search apps', 'aria-label': 'Search apps', autocomplete: 'off', spellcheck: 'false' });
    const openItem = item => { closeTransient(); const app = byId(item.id); const vis = visibleWindows(app).length; if (vis) focusApp(app); else if (app.windows.length) restoreRecent(app); else launch(app); render(); };
    const draw = () => {
      const q = input.value;
      list.replaceChildren();
      if (!q.trim()) {
        results = startApps();
        list.append(el('div', { class: 'label' }, 'Pinned'));
      } else {
        results = rank(startApps(), q);
        if (!results.length) list.append(el('div', { class: 'label' }, 'No apps match'));
      }
      sel = clamp(sel, 0, Math.max(0, results.length - 1));
      results.forEach((r, i) => list.append(el('button', { class: 'start-item' + (q.trim() && i === sel ? ' sel' : ''), role: 'option', 'aria-selected': q.trim() && i === sel ? 'true' : 'false', onclick: () => openItem(r) },
        icon(r.icon), el('span', {}, r.name), q.trim() ? el('span', { class: 'kind' }, KIND[r.kind]) : null)));
    };
    input.addEventListener('input', () => { sel = 0; draw(); });
    input.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') { sel = Math.min(sel + 1, results.length - 1); draw(); e.preventDefault(); }
      if (e.key === 'ArrowUp') { sel = Math.max(sel - 1, 0); draw(); e.preventDefault(); }
      if (e.key === 'Enter' && input.value.trim() && results[sel]) openItem(results[sel]);
    });
    const right = el('div', { class: 'start-right' });
    for (const p of PLACES) {
      if (!p) { right.append(el('div', { class: 'sep' })); continue; }
      right.append(el('button', { class: 'place', onclick: () => {
        closeTransient();
        if (p[0] === 'System Settings') toast('Opens System Settings');
        else { const f = byId('finder'); newWindow(f, p[0]); }
        render();
      } }, icon(p[1]), el('span', {}, p[0])));
    }
    const powerMenu = () => {
      const m = el('div', { class: 'pop menu power-menu', role: 'menu' });
      for (const [label, msg] of [['Sleep', 'Your Mac would go to sleep.'], ['Restart', 'Your Mac would restart. Apps still ask to save first.'], ['Log Out', 'You would log out. Apps still ask to save first.'], ['Lock Screen', 'Your screen would lock.']]) {
        m.append(el('button', { role: 'menuitem', onclick: () => { closeTransient(); toast(msg); } }, label));
      }
      node.append(m);
    };
    right.append(el('div', { class: 'power' },
      el('button', { onclick: () => { closeTransient(); toast('Your Mac would shut down. Apps still ask to save first.'); } }, 'Shut Down'),
      el('button', { 'aria-label': 'More power options', onclick: e => { e.stopPropagation(); const m = $('.power-menu', node); m ? m.remove() : powerMenu(); } }, '›')));
    const node = el('div', { class: 'pop start' + (state.small ? ' small-bar' : ''), role: 'dialog', 'aria-label': 'Start menu' },
      el('div', { class: 'start-left' }, list, el('div', { class: 'start-search' }, el('label', {}, icon('i-search'), input))),
      right);
    openTransient('start', node, 'start');
    renderBar();
    input.value = query;
    draw();
    input.focus({ preventScroll: true });
    return input;
  }

  // ----- Mission Control
  function missionControl() {
    closeTransient();
    const list = state.z.map(win).filter(w => w && !w.min);
    const ov = el('div', { class: 'mcov', role: 'dialog', 'aria-label': 'Mission Control' });
    if (!list.length) ov.append(el('div', { class: 'mc-empty' }, 'No open windows. Click anywhere to go back.'));
    for (const w of list) {
      const app = appOf(w);
      ov.append(el('div', { class: 'mc-win', role: 'button', tabindex: '0', onclick: e => { e.stopPropagation(); ov.remove(); endShowDesktop(); raise(w); render(); } },
        el('div', { class: 'mc-pic' }, thumbArt(w), icon(app.icon)), el('div', {}, w.title)));
    }
    ov.addEventListener('click', () => ov.remove());
    layer.append(ov);
  }

  // ----- show desktop
  function showDesktop() {
    closeTransient();
    if (state.desktopHidden) { state.desktopHidden = null; const f = frontWindow(); state.active = f ? f.app : state.active; }
    else { state.desktopHidden = allWindows().filter(w => !w.min).map(w => w.id); state.active = 'finder'; }
    render();
  }

  // ----- tray
  function trayClick(key, btn) {
    if (key === 'trash') {
      closeTransient();
      const f = byId('finder');
      const existing = f.windows.find(w => w.title === 'Trash');
      if (existing) raise(existing); else newWindow(f, 'Trash').kind = 'trash';
      render();
      toast('Superbar asks Finder to open its Trash');
      return;
    }
    if (state.transient?.kind === key) { closeTransient(); return; }
    const node = el('div', { class: 'pop trayp', role: 'dialog' });
    const fill = () => {
      node.replaceChildren();
      if (key === 'wifi') {
        node.setAttribute('aria-label', 'Wi-Fi');
        node.append(
          el('div', { class: 'row' }, el('h4', {}, 'Wi-Fi'), el('div', { class: 'spacer' }),
            el('button', { class: 'toggle', role: 'switch', 'aria-checked': String(state.wifi), 'aria-label': 'Wi-Fi', onclick: () => { state.wifi = !state.wifi; fill(); renderBar(); } })),
          el('div', { class: 'row dim', style: 'margin-top:8px' }, icon(state.wifi ? 'i-wifi' : 'i-wifi-off'), el('span', {}, state.wifi ? 'Connected over Wi-Fi' : 'Wi-Fi is off')),
          el('div', { class: 'sep' }), el('button', { class: 'linkish', onclick: () => { closeTransient(); toast('Opens Wi-Fi settings'); } }, 'Wi-Fi Settings…'));
      } else if (key === 'sound') {
        node.setAttribute('aria-label', 'Sound');
        const pct = el('span', { class: 'dim', style: 'width:38px;text-align:right' }, state.muted ? 'Muted' : state.volume + '%');
        const slider = el('input', { class: 'slider', type: 'range', min: '0', max: '100', value: String(state.volume), 'aria-label': 'Volume' });
        slider.addEventListener('input', () => { state.volume = +slider.value; state.muted = false; pct.textContent = state.volume + '%'; renderBar(); muteBtn.replaceChildren(icon(trayIcon('sound'))); });
        const muteBtn = el('button', { class: 'iconbtn', 'aria-label': state.muted ? 'Unmute' : 'Mute', onclick: () => { state.muted = !state.muted; fill(); renderBar(); } }, icon(trayIcon('sound')));
        node.append(el('h4', {}, 'Sound'), el('div', { class: 'row', style: 'margin-top:10px' }, muteBtn, slider, pct),
          el('div', { class: 'sep' }), el('button', { class: 'linkish', onclick: () => { closeTransient(); toast('Opens Sound settings'); } }, 'Sound Settings…'));
      } else {
        node.setAttribute('aria-label', 'Battery');
        node.append(el('h4', {}, 'Battery'), el('div', { class: 'row', style: 'margin-top:6px' }, el('span', { class: 'big-num' }, '76%')),
          el('div', { class: 'dim' }, 'On battery · 5:12 left'),
          el('div', { class: 'sep' }), el('button', { class: 'linkish', onclick: () => { closeTransient(); toast('Opens Battery settings'); } }, 'Battery Settings…'));
      }
    };
    fill();
    closeTransient();
    place(node, box(btn));
    state.transient = { kind: key, node, owner: key };
    renderBar();
  }

  // ----- calendar
  const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const monthStart = d => new Date(d.getFullYear(), d.getMonth(), 1);
  const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  function toggleCalendar(btn) {
    if (state.transient?.kind === 'calendar') { closeTransient(); return; }
    state.calSel = startOfDay(new Date());
    state.calMonth = monthStart(state.calSel);
    const node = el('div', { class: 'pop cal', role: 'dialog', 'aria-label': 'Calendar' });
    const draw = () => {
      const sel = state.calSel, month = state.calMonth, today = startOfDay(new Date());
      node.replaceChildren();
      const date = el('input', { type: 'date', value: iso(sel), 'aria-label': 'Go to date' });
      date.addEventListener('change', () => { if (!date.value) return; const [y, m, d] = date.value.split('-').map(Number); state.calSel = new Date(y, m - 1, d); state.calMonth = monthStart(state.calSel); draw(); });
      const atToday = sameDay(sel, today) && month.getTime() === monthStart(today).getTime();
      const grid = el('div', { class: 'c-grid' });
      // By position: the letters repeat (T, S).
      for (let i = 0; i < 7; i++) grid.append(el('div', { class: 'c-wd', 'aria-hidden': 'true' }, new Date(2024, 0, 7 + i).toLocaleDateString([], { weekday: 'narrow' })));
      for (let i = 0; i < month.getDay(); i++) grid.append(el('div'));
      const days = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
      for (let d = 1; d <= days; d++) {
        const day = new Date(month.getFullYear(), month.getMonth(), d);
        grid.append(el('button', { class: 'c-day' + (sameDay(day, today) ? ' today' : '') + (sameDay(day, sel) ? ' picked' : ''),
          'aria-label': day.toLocaleDateString([], { dateStyle: 'full' }), 'aria-pressed': String(sameDay(day, sel)),
          onclick: () => { state.calSel = day; draw(); } }, el('span', {}, String(d))));
      }
      node.append(
        el('div', { class: 'c-date' }, sel.toLocaleDateString([], { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })),
        el('div', { class: 'c-tools' }, date, el('button', { class: 'today-btn', disabled: atToday, onclick: () => { state.calSel = today; state.calMonth = monthStart(today); draw(); } }, 'Today')),
        el('div', { class: 'sep' }),
        el('div', { class: 'c-head' },
          el('button', { 'aria-label': 'Previous month', onclick: () => { state.calMonth = new Date(month.getFullYear(), month.getMonth() - 1, 1); draw(); } }, icon('i-chev-l')),
          el('strong', {}, month.toLocaleDateString([], { month: 'long', year: 'numeric' })),
          el('button', { 'aria-label': 'Next month', onclick: () => { state.calMonth = new Date(month.getFullYear(), month.getMonth() + 1, 1); draw(); } }, icon('i-chev-r'))),
        grid);
    };
    draw();
    closeTransient();
    place(node, box(btn), 'right');
    state.transient = { kind: 'calendar', node, owner: 'calendar' };
    renderBar();
  }

  // Keep the clock current, on the minute.
  (function tick() {
    const now = new Date();
    setTimeout(() => { if (!state.transient || state.transient.kind !== 'calendar') renderBar(); else { const c = $('.clock', bar); if (c) c.firstChild.textContent = new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }); } tick(); }, (60 - now.getSeconds()) * 1000 + 50);
  })();

  render();

  // ----- "Things to try"
  const demoTop = () => $('#demo').scrollIntoView({ behavior: 'smooth', block: 'start' });
  const btnFor = id => $(`.appbtn[data-app="${id}"]`, bar);
  const later = (fn, ms = 450) => setTimeout(fn, ms);
  const TRY = {
    start: () => { demoTop(); later(() => { const input = openStart(''); let i = 0; const s = 'ter'; const t = setInterval(() => { input.value = s.slice(0, ++i); input.dispatchEvent(new Event('input')); if (i >= s.length) clearInterval(t); }, 160); }); },
    pick: () => { demoTop(); later(() => { const b = byId('browser'); if (!isFront(b)) { focusApp(b); render(); } later(() => showPreview(b, btnFor('browser'), true), 350); }); },
    minimize: () => { demoTop(); later(() => { const m = byId('mail'); if (!m.windows.length) newWindow(m); if (!isFront(m)) focusApp(m); render(); later(() => { toast('Mail is in front. Clicking it minimizes its window.'); later(() => { const mm = byId('mail'); if (visibleWindows(mm).length === 1) minimize(visibleWindows(mm)[0]); render(); }, 900); }, 300); }); },
    calendar: () => { demoTop(); later(() => toggleCalendar($('.clock', bar))); },
    close: () => { demoTop(); later(() => { const t = byId('terminal'); if (!t.windows.length) { newWindow(t); render(); toast('Terminal has a window again. Click this hint once more.'); return; } [...t.windows].forEach(closeWindow); render(); toast('Terminal isn’t pinned, so its button left with its last window.'); }); },
    hover: () => { demoTop(); later(() => { const b = byId('browser'); if (b.windows.length) showPreview(b, btnFor('browser'), true); }); },
    sound: () => { demoTop(); later(() => { if (!state.tray.sound) { state.tray.sound = true; syncSettings(); renderBar(); } trayClick('sound', $('[data-owner="sound"]', bar)); }); },
    trash: () => { demoTop(); later(() => { if (!state.tray.trash) { state.tray.trash = true; syncSettings(); renderBar(); } trayClick('trash'); }); },
    mc: () => { demoTop(); later(missionControl); },
  };
  $$('[data-try]').forEach(b => b.addEventListener('click', () => TRY[b.dataset.try]?.()));

  // ---------------------------------------------------------------- Settings demo (drives the bar above)
  function syncSettings() {
    $$('#settings-demo [data-tray]').forEach(i => { i.checked = state.tray[i.dataset.tray]; });
    $$('#settings-demo [data-size]').forEach(b => b.setAttribute('aria-checked', String((b.dataset.size === 'small') === state.small)));
  }
  $$('#settings-demo [data-tray]').forEach(i => i.addEventListener('change', () => { state.tray[i.dataset.tray] = i.checked; closeTransient(); renderBar(); }));
  $$('#settings-demo [data-size]').forEach(b => b.addEventListener('click', () => { state.small = b.dataset.size === 'small'; closeTransient(); syncSettings(); render(); }));

  // ---------------------------------------------------------------- Click rules demo
  (() => {
    const root = $('#click-demo');
    const s = { running: true, active: false, hidden: false, visible: 1, minimized: 0 };
    const TEXT = {
      launch: ['Launch the app', 'It isn’t running, so the click opens it.'],
      unhide: ['Unhide it', 'It was hidden with ⌘H, so it comes back as it was.'],
      pick: ['Show its windows to pick one', 'It’s in front with two or more windows, so you choose which one.'],
      minimize: ['Minimize its window', 'It’s already in front with one window, so a second click tucks it away.'],
      restore: ['Restore its last minimized window', 'Nothing of it is on screen, so the window you minimized last comes back.'],
      focus: ['Bring its window to the front', 'It’s running behind other apps, so its last-used window comes forward.'],
      reopen: ['Open a new window', 'It’s running with no windows at all, so it gets one.'],
    };
    const draw = () => {
      $$('input[data-k]', root).forEach(i => { i.checked = s[i.dataset.k]; i.disabled = i.dataset.k !== 'running' && !s.running; });
      $$('output[data-o]', root).forEach(o => { o.textContent = s[o.dataset.o]; });
      $$('.stepper button', root).forEach(b => { b.disabled = !s.running; });
      const a = resolveClick(s);
      $('#click-action').textContent = TEXT[a][0];
      $('#click-why').textContent = TEXT[a][1];
    };
    $$('input[data-k]', root).forEach(i => i.addEventListener('change', () => { s[i.dataset.k] = i.checked; draw(); }));
    $$('.stepper button', root).forEach(b => b.addEventListener('click', () => { const k = b.dataset.k; s[k] = clamp(s[k] + Number(b.dataset.d), 0, 4); draw(); }));
    draw();
  })();

  // ---------------------------------------------------------------- Visibility demo
  (() => {
    const barEl = $('#vis-bar'), out = $('#vis-readout');
    const t = { pinned: false, wins: [{ state: 'open' }] };
    const notes = { running: true, wins: 0 };
    let last = 'Terminal has one window, so it has a button.';
    const btn = (id, label, lit, count, gone) => el('div', { class: 'appbtn' + (lit ? ' lit' : '') + (gone ? ' gone' : ''), 'aria-label': label, role: 'img' },
      el('span', { class: 'frame' }), icon(id), count ? el('span', { class: 'count' }, String(count)) : null);
    const draw = () => {
      const tShown = t.pinned || t.wins.length > 0;
      barEl.replaceChildren(
        el('div', { class: 'orbmini' }, icon('i-orb')),
        btn('app-finder', 'Finder, pinned, no windows', false, 0, false),
        btn('app-notes', `Notes, pinned, ${notes.running ? 'running with no windows' : 'not running'}`, false, 0, false),
        btn('app-terminal', tShown ? `Terminal, ${t.wins.length} windows` : 'Terminal, no button', t.wins.length > 0, t.wins.length, !tShown));
      const kinds = t.wins.map(w => w.state);
      $('[data-v="minimize"]').disabled = !kinds.includes('open');
      $('[data-v="fullscreen"]').disabled = !kinds.includes('open');
      $('[data-v="close"]').disabled = !t.wins.length;
      $('[data-v="pin"]').textContent = t.pinned ? 'Unpin Terminal' : 'Pin Terminal';
      $('[data-v="notes"]').textContent = notes.running ? 'Quit Notes' : 'Open Notes, then close it';
      out.textContent = last;
    };
    $$('#vis-demo [data-v]').forEach(b => b.addEventListener('click', () => {
      const v = b.dataset.v;
      if (v === 'open') { t.wins.push({ state: 'open' }); last = 'A new Terminal window: the button shows, lit, with the count.'; }
      if (v === 'minimize') { t.wins.find(w => w.state === 'open').state = 'min'; last = 'Minimized windows still count, so the button stays.'; }
      if (v === 'fullscreen') { t.wins.find(w => w.state === 'open').state = 'fs'; last = 'A full-screen window on another Space still counts, so the button stays.'; }
      if (v === 'close') { t.wins.pop(); last = t.wins.length ? 'One fewer window. The button stays while any remain.' : t.pinned ? 'No windows left, but Terminal is pinned, so it keeps a plain button.' : 'Its last window closed and it isn’t pinned, so the button went.'; }
      if (v === 'pin') { t.pinned = !t.pinned; last = t.pinned ? 'Pinned: Terminal keeps its button even with no windows.' : (t.wins.length ? 'Unpinned: the button stays while it has windows.' : 'Unpinned with no windows: the button goes.'); }
      if (v === 'notes') { notes.running = !notes.running; last = notes.running ? 'Notes is running with no windows: a plain pinned button, not lit.' : 'Notes quit. It’s pinned, so its button stays.'; }
      draw();
    }));
    draw();
  })();

  // ---------------------------------------------------------------- Full screen demo (EdgeReveal timings)
  (() => {
    const screen = $('#fs-screen'), barEl = $('#fs-bar'), edge = $('#fs-edge'), app = $('#fs-app'), toggle = $('#fs-toggle'), out = $('#fs-readout');
    barEl.append(el('div', { class: 'orbmini' }, icon('i-orb')), ...['app-finder', 'app-browser', 'app-mail', 'app-terminal'].map(i => el('div', { class: 'appbtn lit' }, el('span', { class: 'frame' }), icon(i))));
    let fs = false, shown = true, showT, hideT;
    const set = (v, why) => { shown = v; barEl.classList.toggle('hidden', !v); out.textContent = why; };
    toggle.addEventListener('click', () => {
      fs = !fs;
      clearTimeout(showT); clearTimeout(hideT);
      toggle.setAttribute('aria-pressed', String(fs));
      toggle.textContent = fs ? 'Leave full screen' : 'Enter full screen';
      screen.classList.toggle('fs', fs);
      app.classList.toggle('on', fs);
      set(!fs, fs ? 'Full screen: the bar slid away. Rest the pointer on the bottom edge.' : 'Back on the desktop: the bar is showing.');
    });
    const reveal = () => { if (!fs) return; clearTimeout(hideT); clearTimeout(showT); showT = setTimeout(() => set(true, 'Revealed after 0.2 s on the edge. Move away and it hides 0.6 s later.'), 200); };
    const leave = e => { if (!fs) return; if (e.relatedTarget && (barEl.contains(e.relatedTarget) || e.relatedTarget === edge)) return; clearTimeout(showT); clearTimeout(hideT); hideT = setTimeout(() => set(false, 'Hidden again. The edge brings it back.'), 600); };
    edge.addEventListener('pointerenter', reveal);
    edge.addEventListener('click', reveal);
    barEl.addEventListener('pointerenter', () => { if (fs && shown) clearTimeout(hideT); });
    edge.addEventListener('pointerleave', leave);
    barEl.addEventListener('pointerleave', leave);
  })();

  // ---------------------------------------------------------------- Keep windows above (WorkArea.fit)
  (() => {
    const screenH = 280, menu = 14, barH = 34, bottom = screenH - barH, minH = 120;
    const winEl = $('#fit-window'), out = $('#fit-readout'), on = $('#fit-on');
    $('#fit-bar').append(el('div', { class: 'orbmini' }, icon('i-orb')), ...['app-finder', 'app-browser', 'app-calc'].map(i => el('div', { class: 'appbtn lit' }, el('span', { class: 'frame' }), icon(i))));
    let f = { top: 40, h: 150 };
    const apply = () => { winEl.style.top = f.top + 'px'; winEl.style.height = f.h + 'px'; };
    /** WorkArea.fit: move up if there's room, else keep the top and trim. Nil when it fits. */
    const fitFrame = r => {
      if (!(r.top < bottom && r.top + r.h > bottom + .5)) return null;
      const overlap = r.top + r.h - bottom;
      if (r.top - overlap >= menu) return { top: r.top - overlap, h: r.h };
      const top = Math.max(r.top, menu), h = bottom - top;
      return h >= minH ? { top, h } : null;
    };
    let timer;
    const openOrResize = (frame, said) => {
      clearTimeout(timer);
      f = frame; apply();
      out.textContent = said;
      if (!on.checked) { out.textContent = said + ' “Keep windows above” is off, so it stays under the bar.'; return; }
      timer = setTimeout(() => {
        const t = fitFrame(f);
        if (!t) return;
        const moved = t.h === f.h;
        f = t; apply();
        out.textContent = moved ? 'It had room above, so Superbar moved it up. Same size; the sheet tabs show.' : 'No room above, so Superbar kept its top and trimmed its bottom to end at the bar.';
      }, 700);
    };
    $$('#fit-demo [data-fit]').forEach(b => b.addEventListener('click', () => {
      const k = b.dataset.fit;
      if (k === 'low') openOrResize({ top: 120, h: 160 }, 'A window opens with its bottom under the bar…');
      if (k === 'zoom') openOrResize({ top: menu, h: screenH - menu }, 'The window is zoomed to the full height…');
      if (k === 'drag') { clearTimeout(timer); f = { top: Math.min(f.top + 60, screenH - 60), h: f.h }; apply(); out.textContent = 'You dragged it down. Moving a window is never fought, so it stays where you put it.'; }
    }));
    apply();
    out.textContent = 'This window fits. Try opening one low, or zooming it.';
  })();

  // ---------------------------------------------------------------- Two displays
  (() => {
    const mons = $$('#disp-demo .monitor');
    const list = [{ id: 'app-finder', n: 0 }, { id: 'app-browser', n: 2 }, { id: 'app-mail', n: 1 }, { id: 'app-terminal', n: 1 }];
    let fs = false, plugged = true;
    const draw = () => {
      mons.forEach((m, i) => {
        const strip = $('.mini-strip', m);
        strip.replaceChildren(el('div', { class: 'orbmini' }, icon('i-orb')));
        list.forEach(a => {
          const b = el('div', { class: 'appbtn' + (a.n ? ' lit' : ''), role: 'img', 'aria-label': `${a.n} windows` }, el('span', { class: 'frame' }), el('span', { class: 'glow' }), icon(a.id), a.n > 1 ? el('span', { class: 'count' }, String(a.n)) : null);
          b.addEventListener('pointerenter', () => b.classList.add('hot'));
          b.addEventListener('pointerleave', () => b.classList.remove('hot'));
          strip.append(b);
        });
        const scr = $('.monitor-screen', m);
        $('.fsapp', scr)?.remove();
        const isFs = i === 1 && fs;
        if (isFs) scr.prepend(el('div', { class: 'fsapp' }, 'Full screen'));
        strip.classList.toggle('hidden', isFs);
        m.classList.toggle('unplugged', i === 1 && !plugged);
      });
    };
    $('#disp-fs').addEventListener('click', e => { fs = !fs; e.currentTarget.setAttribute('aria-pressed', String(fs)); draw(); });
    $('#disp-plug').addEventListener('click', e => { plugged = !plugged; e.currentTarget.textContent = plugged ? 'Unplug External' : 'Plug in External'; draw(); });
    $('#disp-open').addEventListener('click', () => { list[2].n++; draw(); });
    draw();
  })();

  // ---------------------------------------------------------------- Copy buttons
  $$('.copy').forEach(b => b.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = 'Copied'; }
    catch { b.textContent = 'Select and copy'; }
    setTimeout(() => { b.textContent = 'Copy'; }, 1600);
  }));
})();
