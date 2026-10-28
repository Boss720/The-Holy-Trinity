/* Trinity dashboard: Overview, Board (kanban), Settings modal, Autopilot drawer.
 * Plain ES2019, no libraries. Only uses window.Trinity (docs/dashboard-gui.md section 4).
 * Every DOM write uses textContent / createElement: state data is untrusted. */
(function () {
  'use strict';

  var T = window.Trinity;
  if (!T || typeof T.addView !== 'function') {
    if (window.console) { console.error('board.js: window.Trinity is missing'); }
    return;
  }

  var AGENTS = ['codex', 'antigravity', 'claude'];
  var COLUMNS = ['queued', 'running', 'done', 'ready', 'failed', 'stalled', 'merged'];
  var NONTERMINAL = { queued: 1, running: 1, done: 1, ready: 1, failed: 1, stalled: 1 };
  var CANCEL_SHOW_MAX = 30;
  var FILTER_KEY = 'trinity.board.repo';

  var DEFAULTS = {
    slots: { codex: 2, antigravity: 1, claude: 1 },
    base: '',
    test: '',
    autoMerge: false,
    maxRounds: 3,
    deadlineMinutes: 120,
    models: { codex: '', antigravity: '', claude: '' },
    autopilot: {
      enabled: false, approval: true, maxTasksPerHour: 6,
      maxConsecutiveFailures: 3, cleanRunsBeforeAutoMerge: 10
    }
  };

  /* ---------- small helpers ---------- */

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) { n.className = cls; }
    if (text !== undefined && text !== null && text !== '') { n.textContent = String(text); }
    return n;
  }
  function clear(n) { while (n.firstChild) { n.removeChild(n.firstChild); } }
  function btn(label, cls, onClick) {
    var b = el('button', cls, label);
    b.type = 'button';
    if (onClick) { b.addEventListener('click', onClick); }
    return b;
  }
  function str(v) { return v === undefined || v === null ? '' : String(v); }
  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
  function arr(v) { return Array.isArray(v) ? v : []; }
  function clone(o) { return JSON.parse(JSON.stringify(o)); }
  function safeCls(s) { return /^[a-z][a-z0-9-]*$/.test(s) ? s : 'other'; }
  function agentCls(a) { return AGENTS.indexOf(a) >= 0 ? a : 'other'; }
  function basename(p) {
    var parts = str(p).replace(/[\\\/]+$/, '').split(/[\\\/]/);
    return parts[parts.length - 1] || str(p);
  }
  function repoName(r) { return str(r.name) || basename(r.path); }
  function parseTime(s) {
    if (!s) { return NaN; }
    return Date.parse(String(s).replace(' ', 'T'));
  }
  function ageText(s) {
    var t = parseTime(s);
    if (isNaN(t)) { return ''; }
    var m = Math.max(0, Math.floor((Date.now() - t) / 60000));
    if (m < 1) { return '<1m'; }
    if (m < 60) { return m + 'm'; }
    var h = Math.floor(m / 60);
    if (h < 24) { return h + 'h ' + (m % 60) + 'm'; }
    return Math.floor(h / 24) + 'd ' + (h % 24) + 'h';
  }
  function pad2(n) { return (n < 10 ? '0' : '') + n; }
  function clockText(s) {
    var t = parseTime(s);
    if (isNaN(t)) { return str(s); }
    var d = new Date(t);
    var hms = pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
    var now = new Date();
    if (d.toDateString() === now.toDateString()) { return hms; }
    return pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' ' + hms.slice(0, 5);
  }
  function getIn(o, path) {
    var cur = o;
    for (var i = 0; i < path.length; i++) {
      if (!isObj(cur)) { return undefined; }
      cur = cur[path[i]];
    }
    return cur;
  }
  function setIn(o, path, v) {
    var cur = o;
    for (var i = 0; i < path.length - 1; i++) {
      if (!isObj(cur[path[i]])) { cur[path[i]] = {}; }
      cur = cur[path[i]];
    }
    cur[path[path.length - 1]] = v;
  }
  function deepMerge(base, over) {
    if (!isObj(over)) { return base; }
    Object.keys(over).forEach(function (k) {
      if (isObj(over[k]) && isObj(base[k])) { deepMerge(base[k], over[k]); }
      else { base[k] = over[k]; }
    });
    return base;
  }
  function lsGet(k) { try { return window.localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { window.localStorage.setItem(k, v); } catch (e) { /* ignore */ } }

  function getRepos() {
    var s = T.getState && T.getState();
    return s && Array.isArray(s.repos) ? s.repos : [];
  }
  function findRepo(path) {
    var repos = getRepos();
    for (var i = 0; i < repos.length; i++) { if (str(repos[i].path) === path) { return repos[i]; } }
    return null;
  }
  function getAvailability() {
    var s = T.getState && T.getState();
    return s && isObj(s.availability) ? s.availability : {};
  }

  /* Normalised task state ('running' covers started/working). Returns '' when unknown. */
  function taskCol(t) {
    var s = str(t.state).toLowerCase();
    if (s === 'started' || s === 'working') { s = 'running'; }
    if (COLUMNS.indexOf(s) >= 0 || s === 'cancelled') { return s; }
    return '';
  }

  function effConfig(repo) {
    var cfg = clone(DEFAULTS);
    if (repo && isObj(repo.config)) { deepMerge(cfg, clone(repo.config)); }
    return cfg;
  }

  /* Run an action through the shell. Never rejects; resolves {ok, res}. */
  function run(body) {
    var p;
    try { p = Promise.resolve(T.action(body)); } catch (e) { p = Promise.reject(e); }
    return p.then(function (res) { return { ok: true, res: res }; }, function (err) {
      var m = err && err.message ? err.message : str(err);
      if (!/cancel|declin|abort|dismiss/i.test(m)) { T.toast(m || 'Action failed', 'error'); }
      return { ok: false, err: err };
    });
  }

  /* Rebuild `node` only when `sig` changed; keep focus (data-fkey) and scroll. */
  function patch(node, sig, build) {
    if (node.__sig === sig) { return false; }
    var ae = document.activeElement;
    var fkey = null;
    if (ae && ae !== document.body && node.contains(ae) && ae.getAttribute) { fkey = ae.getAttribute('data-fkey'); }
    var st = node.scrollTop;
    clear(node);
    build(node);
    node.__sig = sig;
    node.scrollTop = st;
    if (fkey) {
      var all = node.querySelectorAll('[data-fkey]');
      for (var i = 0; i < all.length; i++) {
        if (all[i].getAttribute('data-fkey') === fkey) { all[i].focus(); break; }
      }
    }
    return true;
  }

  /* ---------- floating menu / popover ---------- */

  var floating = null; // { el, anchor }

  function closeFloat(restore) {
    if (!floating) { return; }
    var f = floating;
    floating = null;
    if (f.el.parentNode) { f.el.parentNode.removeChild(f.el); }
    if (restore && f.anchor && f.anchor.isConnected && f.anchor.focus) { f.anchor.focus(); }
  }
  function showFloat(node, anchor) {
    closeFloat(false);
    node.style.position = 'fixed';
    node.style.visibility = 'hidden';
    node.style.left = '0px';
    node.style.top = '0px';
    document.body.appendChild(node);
    var r = anchor.getBoundingClientRect();
    var w = node.offsetWidth;
    var h = node.offsetHeight;
    var left = Math.min(Math.max(8, r.left), Math.max(8, window.innerWidth - w - 8));
    var top = r.bottom + 4;
    if (top + h > window.innerHeight - 8) { top = Math.max(8, r.top - h - 4); }
    node.style.left = left + 'px';
    node.style.top = top + 'px';
    node.style.visibility = '';
    floating = { el: node, anchor: anchor };
  }
  document.addEventListener('pointerdown', function (e) {
    if (!floating) { return; }
    if (floating.el.contains(e.target)) { return; }
    if (floating.anchor && floating.anchor.contains && floating.anchor.contains(e.target)) { return; }
    closeFloat(false);
  }, true);

  /* ================================================================
   * OVERVIEW
   * ================================================================ */

  var ov = { root: null, grid: null, cards: {} };

  function slotInfo(repo) {
    var out = [];
    var slots = isObj(repo.slots) ? repo.slots : null;
    var cfg = isObj(repo.config) && isObj(repo.config.slots) ? repo.config.slots : null;
    AGENTS.forEach(function (a) {
      var used = null;
      var max = null;
      if (slots && isObj(slots[a])) {
        used = Number(slots[a].used);
        max = Number(slots[a].max);
      }
      if (used === null || isNaN(used)) {
        used = arr(repo.tasks).filter(function (t) { return taskCol(t) === 'running' && t.agent === a; }).length;
      }
      if (max === null || isNaN(max)) { max = cfg && cfg[a] !== undefined ? Number(cfg[a]) : null; }
      out.push({ agent: a, used: used, max: max });
    });
    return out;
  }

  function newestCodexLimits(repo) {
    var best = null;
    var bestT = -Infinity;
    arr(repo.tasks).forEach(function (t) {
      if (t.agent !== 'codex' || taskCol(t) !== 'running' || !arr(t.rateLimits).length) { return; }
      var ts = parseTime(t.started || t.updated || t.lastActivity);
      if (isNaN(ts)) { ts = 0; }
      if (ts >= bestT) { bestT = ts; best = t; }
    });
    if (!best) { return []; }
    return best.rateLimits.map(function (l) {
      var pct = Number(l && l.usedPercent);
      var resets = '';
      if (l && l.resetsAt) {
        var d = new Date(typeof l.resetsAt === 'number' && l.resetsAt < 1e12 ? l.resetsAt * 1000 : (isNaN(Number(l.resetsAt)) ? parseTime(l.resetsAt) : Number(l.resetsAt)));
        resets = isNaN(d.getTime()) ? str(l.resetsAt) : pad2(d.getHours()) + ':' + pad2(d.getMinutes());
      }
      return { name: str(l && l.name) || 'limit', pct: isNaN(pct) ? 0 : Math.max(0, Math.min(100, Math.round(pct))), resets: resets };
    });
  }

  function overviewVM(repo, avail) {
    var running = arr(repo.tasks).filter(function (t) { return taskCol(t) === 'running'; }).length;
    var ap = isObj(repo.autopilot) ? repo.autopilot : null;
    var sch = isObj(repo.scheduler) ? repo.scheduler : null;
    return {
      path: str(repo.path),
      name: repoName(repo),
      branch: str(repo.branch),
      running: running,
      slots: slotInfo(repo),
      avail: AGENTS.map(function (a) {
        var x = isObj(avail[a]) ? avail[a] : null;
        return { agent: a, known: !!x, ok: x ? x.available !== false : true, detail: x ? str(x.detail) : '' };
      }),
      limits: newestCodexLimits(repo),
      sched: sch ? { alive: !!sch.alive, now: str(sch.now), next: str(sch.next) } : null,
      ap: ap ? {
        enabled: !!ap.enabled, paused: !!ap.paused, pauseReason: str(ap.pauseReason),
        limitBreach: str(ap.limitBreach)
      } : null,
      hasConfig: isObj(repo.config)
    };
  }

  function buildOverviewCard(card, vm) {
    var head = el('div', 'tb-ov-head');
    head.appendChild(el('h3', 'tb-ov-name', vm.name));
    if (vm.branch) { head.appendChild(el('span', 'tb-chip tb-chip-branch', vm.branch)); }
    head.appendChild(el('span', 'tb-chip tb-chip-run', vm.running + ' running'));
    card.appendChild(head);
    card.title = vm.path;

    if (vm.ap && (vm.ap.paused || vm.ap.limitBreach)) {
      var bn = el('div', 'tb-banner ' + (vm.ap.limitBreach ? 'tb-banner-bad' : 'tb-banner-warn'));
      bn.setAttribute('role', 'alert');
      var msg = vm.ap.limitBreach ? ('Limit breached: ' + vm.ap.limitBreach) : 'Paused';
      if (vm.ap.paused && vm.ap.pauseReason) { msg += (vm.ap.limitBreach ? ' | paused: ' : ': ') + vm.ap.pauseReason; }
      bn.appendChild(el('span', 'tb-banner-text', msg));
      if (vm.ap.paused) {
        var ub = btn('Unpause', 'tb-btn tb-btn-sm', function () {
          run({ action: 'unpause', repo: vm.path, task: '', confirm: true });
        });
        ub.setAttribute('data-fkey', 'unpause');
        bn.appendChild(ub);
      }
      card.appendChild(bn);
    }

    var slots = el('div', 'tb-ov-slots');
    slots.appendChild(el('span', 'tb-label', 'Slots'));
    slots.appendChild(el('span', 'tb-ov-slots-text', vm.slots.map(function (s) {
      return s.used + (s.max === null ? '' : '/' + s.max) + ' ' + s.agent;
    }).join(', ')));
    card.appendChild(slots);

    var av = el('div', 'tb-ov-avail');
    av.appendChild(el('span', 'tb-label', 'Agents'));
    vm.avail.forEach(function (a) {
      var item = el('span', 'tb-avail');
      var dot = el('span', 'tb-dot ' + (!a.known ? 'tb-dot-unk' : (a.ok ? 'tb-dot-ok' : 'tb-dot-bad')));
      item.appendChild(dot);
      item.appendChild(el('span', '', a.agent));
      item.title = a.agent + ': ' + (a.known ? (a.ok ? 'available' : 'unavailable') : 'unknown') + (a.detail ? ' (' + a.detail + ')' : '');
      av.appendChild(item);
    });
    card.appendChild(av);

    if (vm.limits.length) {
      var rl = el('div', 'tb-ov-limits');
      rl.appendChild(el('span', 'tb-label', 'Codex limits'));
      vm.limits.forEach(function (l) {
        var row = el('div', 'tb-rl');
        row.appendChild(el('span', 'tb-rl-name', l.name + ' ' + l.pct + '%' + (l.resets ? ' (resets ' + l.resets + ')' : '')));
        var track = el('div', 'tb-rl-track');
        var fill = el('div', 'tb-rl-fill' + (l.pct >= 95 ? ' tb-rl-bad' : (l.pct >= 80 ? ' tb-rl-warn' : '')));
        fill.style.width = l.pct + '%';
        track.appendChild(fill);
        track.setAttribute('role', 'progressbar');
        track.setAttribute('aria-valuemin', '0');
        track.setAttribute('aria-valuemax', '100');
        track.setAttribute('aria-valuenow', String(l.pct));
        track.setAttribute('aria-label', l.name + ' usage');
        row.appendChild(track);
        rl.appendChild(row);
      });
      card.appendChild(rl);
    }

    var foot = el('div', 'tb-ov-foot');
    if (vm.sched) {
      var sc = el('span', 'tb-chip ' + (vm.sched.alive ? 'tb-chip-ok' : 'tb-chip-muted'), vm.sched.alive ? 'scheduler alive' : 'scheduler off');
      sc.title = vm.sched.alive ? ('now: ' + (vm.sched.now || '-') + ' | next: ' + (vm.sched.next || '-')) : 'scheduler is not running';
      foot.appendChild(sc);
    }
    if (vm.ap) {
      var sw = el('label', 'tb-switch');
      var cb = el('input');
      cb.type = 'checkbox';
      cb.checked = vm.ap.enabled;
      cb.setAttribute('role', 'switch');
      cb.setAttribute('data-fkey', 'ap-toggle');
      cb.addEventListener('change', function () {
        var want = cb.checked;
        cb.checked = vm.ap.enabled; // the next poll flips it once the server agrees
        run({ action: 'autopilot', repo: vm.path, task: '', enabled: want, confirm: true });
      });
      sw.appendChild(cb);
      sw.appendChild(el('span', 'tb-switch-track'));
      sw.appendChild(el('span', 'tb-switch-text', 'Autopilot ' + (vm.ap.enabled ? 'on' : 'off')));
      foot.appendChild(sw);
    }
    var spacer = el('span', 'tb-grow');
    foot.appendChild(spacer);
    if (vm.hasConfig) {
      var sb = btn('Settings', 'tb-btn tb-btn-sm', function () { openSettings(vm.path); });
      sb.setAttribute('data-fkey', 'settings');
      foot.appendChild(sb);
    }
    if (vm.ap) {
      var ab = btn('Autopilot', 'tb-btn tb-btn-sm', function () { openAutopilot(vm.path); });
      ab.setAttribute('data-fkey', 'autopilot');
      foot.appendChild(ab);
    }
    card.appendChild(foot);
  }

  function renderOverview(container, state) {
    if (!ov.root) {
      ov.root = el('div', 'tb-root tb-ov');
      ov.grid = el('div', 'tb-ov-grid');
      ov.root.appendChild(ov.grid);
    }
    if (ov.root.parentNode !== container) { container.appendChild(ov.root); }
    var repos = state && Array.isArray(state.repos) ? state.repos : [];
    var avail = state && isObj(state.availability) ? state.availability : {};
    var seen = {};
    var ref = ov.grid.firstChild;
    var empty = ov.grid.querySelector('.tb-empty-all');
    if (empty) { ov.grid.removeChild(empty); ref = ov.grid.firstChild; }
    repos.forEach(function (repo) {
      var vm = overviewVM(repo, avail);
      var key = vm.path || vm.name;
      seen[key] = true;
      var card = ov.cards[key];
      if (!card) { card = el('section', 'tb-ov-card'); ov.cards[key] = card; }
      patch(card, JSON.stringify(vm), function (n) { buildOverviewCard(n, vm); });
      if (ref === card) { ref = ref.nextSibling; } else { ov.grid.insertBefore(card, ref); }
    });
    Object.keys(ov.cards).forEach(function (k) {
      if (!seen[k]) {
        var c = ov.cards[k];
        if (c.parentNode) { c.parentNode.removeChild(c); }
        delete ov.cards[k];
      }
    });
    if (!repos.length) { ov.grid.appendChild(el('p', 'tb-empty-all', 'No repos yet.')); }
  }

  /* ================================================================
   * BOARD
   * ================================================================ */

  var bd = {
    root: null, select: null, count: null, colsWrap: null, cols: {}, cards: {},
    filter: lsGet(FILTER_KEY) || 'all', repoSig: null,
    drag: null, insertBefore: null, pending: null, cancelOpen: false
  };

  function collectEntries(repos, filter) {
    var showRepo = filter === 'all' && repos.length > 1;
    var byCol = { queued: [], running: [], done: [], ready: [], failed: [], stalled: [], merged: [], cancelled: [] };
    repos.forEach(function (repo) {
      var path = str(repo.path);
      if (filter !== 'all' && path !== filter) { return; }
      var rn = repoName(repo);
      var queue = arr(repo.queue);
      queue.forEach(function (q, i) {
        if (!isObj(q)) { return; }
        byCol.queued.push({
          key: path + '|queued|' + str(q.task), col: 'queued', path: path, repoName: rn, showRepo: showRepo,
          task: str(q.task), agent: str(q.agent), model: str(q.model), age: ageText(q.addedAt),
          status: '', waiting: str(q.waiting), overlaps: arr(q.overlaps).map(str),
          queueIdx: i, queueLen: queue.length, scope: str(q.scope), addedAt: str(q.addedAt),
          addedBy: str(q.addedBy), promptFile: str(q.promptFile), base: str(q.base), prompt: str(q.prompt),
          draggable: true
        });
      });
      arr(repo.tasks).forEach(function (t) {
        if (!isObj(t)) { return; }
        var col = taskCol(t);
        if (!col) { return; }
        byCol[col].push({
          key: path + '|' + col + '|' + str(t.task), col: col, path: path, repoName: rn, showRepo: showRepo,
          task: str(t.task), agent: str(t.agent), model: str(t.model),
          age: ageText(t.started || t.updated || t.lastActivity), status: str(t.status),
          waiting: '', overlaps: [], queueIdx: -1, queueLen: 0, scope: str(t.scope),
          draggable: !!NONTERMINAL[col]
        });
      });
    });
    byCol.cancelled = byCol.cancelled.slice(0, CANCEL_SHOW_MAX);
    return byCol;
  }

  /* ----- drop rules ----- */
  function planDrop(d, target) {
    if (target === 'running') {
      if (d.col === 'queued') { return { ok: true, kind: 'start-now' }; }
      return { ok: false, msg: d.col === 'running' ? 'Already running' : 'Only queued tasks can be started' };
    }
    if (target === 'cancelled') {
      if (d.col === 'queued') { return { ok: true, kind: 'queue-remove' }; }
      if (NONTERMINAL[d.col]) { return { ok: true, kind: 'cancel' }; }
      return { ok: false, msg: 'Already finished: cannot cancel a ' + d.col + ' task' };
    }
    if (target === 'merged') {
      if (d.col === 'done' || d.col === 'ready') { return { ok: true, kind: 'merge' }; }
      return { ok: false, msg: 'Only done or ready tasks can be merged' };
    }
    if (target === 'queued') {
      if (d.col === 'queued') { return { ok: true, kind: 'queue-move' }; }
      return { ok: false, msg: 'Tasks cannot be moved back into the queue' };
    }
    if (d.col === target) { return { ok: false, msg: 'Already in ' + target } }
    return { ok: false, msg: 'Cannot move a ' + d.col + ' task to ' + target + ' by hand' };
  }

  function performKind(kind, d, index) {
    var body = { action: kind, repo: d.path, task: d.task, confirm: true };
    if (kind === 'queue-move') { body.index = index; }
    return run(body);
  }

  function queuedCardsDom() {
    var out = [];
    var kids = bd.cols.queued.body.children;
    for (var i = 0; i < kids.length; i++) { if (kids[i].__vm) { out.push(kids[i]); } }
    return out;
  }

  /* Position (0-based, in the repo's queue without the dragged item) for the current insert marker. */
  function dropIndex(d, beforeKey) {
    var cards = queuedCardsDom();
    var pos = 0;
    var reached = false;
    cards.forEach(function (c) {
      if (c.__vm.key === beforeKey) { reached = true; }
      if (reached) { return; }
      if (c.__vm.path === d.path && c.__vm.key !== d.key) { pos++; }
    });
    if (!beforeKey) {
      pos = cards.filter(function (c) { return c.__vm.path === d.path && c.__vm.key !== d.key; }).length;
    }
    return pos;
  }

  function handleDrop(d, target, beforeKey) {
    var plan = planDrop(d, target);
    if (!plan.ok) { T.toast(plan.msg, 'warn'); return; }
    if (plan.kind === 'queue-move') {
      var idx = dropIndex(d, beforeKey);
      if (idx === d.queueIdx) { return; }
      performKind('queue-move', d, idx);
      return;
    }
    performKind(plan.kind, d);
  }

  function clearInsertMarks() {
    var marked = bd.root.querySelectorAll('.tb-ins-before, .tb-ins-end');
    for (var i = 0; i < marked.length; i++) { marked[i].classList.remove('tb-ins-before'); marked[i].classList.remove('tb-ins-end'); }
  }
  function endDrag() {
    var d = bd.drag;
    bd.drag = null;
    bd.insertBefore = null;
    clearInsertMarks();
    bd.root.classList.remove('tb-dragging');
    var cs = bd.root.querySelectorAll('.tb-col, .tb-card');
    for (var i = 0; i < cs.length; i++) {
      cs[i].classList.remove('tb-drop-ok'); cs[i].classList.remove('tb-drop-no');
      cs[i].classList.remove('tb-over'); cs[i].classList.remove('tb-dragging-card');
    }
    if (d && bd.pending) {
      var p = bd.pending;
      bd.pending = null;
      renderBoard(p.container, p.state);
    }
  }

  function createColumn(name) {
    var col = el('div', 'tb-col tb-col-' + name);
    col.setAttribute('data-col', name);
    var head = el('div', 'tb-col-head');
    var title = el('h3', 'tb-col-title', name);
    var count = el('span', 'tb-col-count', '0');
    head.appendChild(title);
    head.appendChild(count);
    var body = el('div', 'tb-col-body');
    body.setAttribute('role', 'list');
    body.setAttribute('aria-label', name + ' tasks');
    var empty = el('p', 'tb-col-empty', name === 'cancelled' ? 'Drop here to cancel' : 'Nothing here');
    col.appendChild(head);
    col.appendChild(empty);
    col.appendChild(body);

    col.addEventListener('dragover', function (e) {
      var d = bd.drag;
      if (!d) { return; }
      e.preventDefault();
      if (e.dataTransfer) { e.dataTransfer.dropEffect = 'move'; }
      col.classList.add('tb-over');
      if (name === 'queued' && d.col === 'queued') {
        var cards = queuedCardsDom().filter(function (c) { return c.__vm.key !== d.key; });
        var before = null;
        for (var i = 0; i < cards.length; i++) {
          var r = cards[i].getBoundingClientRect();
          if (e.clientY < r.top + r.height / 2) { before = cards[i]; break; }
        }
        var key = before ? before.__vm.key : null;
        if (key !== bd.insertBefore || !bd.root.querySelector('.tb-ins-before, .tb-ins-end')) {
          clearInsertMarks();
          bd.insertBefore = key;
          if (before) { before.classList.add('tb-ins-before'); } else { body.classList.add('tb-ins-end'); }
        }
      }
    });
    col.addEventListener('dragleave', function (e) {
      if (!col.contains(e.relatedTarget)) { col.classList.remove('tb-over'); }
    });
    col.addEventListener('drop', function (e) {
      var d = bd.drag;
      if (!d) { return; }
      e.preventDefault();
      var before = bd.insertBefore;
      var snapshot = d;
      endDrag();
      handleDrop(snapshot, name, before);
    });
    return { name: name, col: col, head: head, count: count, body: body, empty: empty };
  }

  function cardMenuItems(vm) {
    var items = [];
    var open = function () { T.openTask(vm.path, vm.task, 'log'); };
    if (vm.col === 'queued') {
      items.push({ label: 'Start now', run: function () { performKind('start-now', vm); } });
      items.push({ label: 'Move up', disabled: vm.queueIdx <= 0, run: function () { performKind('queue-move', vm, vm.queueIdx - 1); } });
      items.push({ label: 'Move down', disabled: vm.queueIdx >= vm.queueLen - 1, run: function () { performKind('queue-move', vm, vm.queueIdx + 1); } });
      items.push({ label: 'Show details', run: function () { openQueuePopover(vm, bd.cards[vm.key]); } });
      items.push({ label: 'Cancel (remove from queue)', run: function () { performKind('queue-remove', vm); } });
      return items;
    }
    if (vm.col === 'done' || vm.col === 'ready') {
      items.push({ label: 'Merge', run: function () { performKind('merge', vm); } });
    }
    items.push({ label: 'Open log', run: open });
    if (NONTERMINAL[vm.col]) { items.push({ label: 'Cancel', run: function () { performKind('cancel', vm); } }); }
    return items;
  }

  function openCardMenu(anchor, vm) {
    if (floating && floating.anchor === anchor) { closeFloat(true); return; }
    var m = el('div', 'tb-menu');
    m.setAttribute('role', 'menu');
    var btns = [];
    cardMenuItems(vm).forEach(function (it) {
      var b = el('button', 'tb-menu-item', it.label);
      b.type = 'button';
      b.setAttribute('role', 'menuitem');
      b.disabled = !!it.disabled;
      b.addEventListener('click', function () { closeFloat(true); it.run(); });
      m.appendChild(b);
      if (!it.disabled) { btns.push(b); }
    });
    m.addEventListener('keydown', function (e) {
      var i = btns.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); btns[(i + 1) % btns.length].focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); btns[(i - 1 + btns.length) % btns.length].focus(); }
      else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeFloat(true); }
      else if (e.key === 'Tab') { closeFloat(false); }
    });
    showFloat(m, anchor);
    if (btns.length) { btns[0].focus(); }
  }

  function openQueuePopover(vm, anchor) {
    if (!anchor) { return; }
    var pop = el('div', 'tb-pop');
    pop.setAttribute('role', 'dialog');
    pop.setAttribute('aria-label', 'Queued task ' + vm.task);
    pop.tabIndex = -1;
    pop.appendChild(el('h4', 'tb-pop-title', vm.task));
    var rows = [
      ['Agent', vm.agent], ['Model', vm.model], ['Scope', vm.scope], ['Base', vm.base],
      ['Prompt file', vm.promptFile], ['Added', vm.addedAt + (vm.addedBy ? ' by ' + vm.addedBy : '')],
      ['Waiting', vm.waiting || 'about to start'],
      ['Overlaps', vm.overlaps.join(', ')]
    ];
    var dl = el('dl', 'tb-pop-dl');
    rows.forEach(function (r) {
      if (!r[1] || !String(r[1]).trim()) { return; }
      dl.appendChild(el('dt', '', r[0]));
      dl.appendChild(el('dd', '', r[1]));
    });
    pop.appendChild(dl);
    if (vm.prompt) {
      pop.appendChild(el('div', 'tb-label', 'Prompt'));
      pop.appendChild(el('pre', 'tb-pop-pre', vm.prompt));
    }
    var close = btn('Close', 'tb-btn tb-btn-sm', function () { closeFloat(true); });
    pop.appendChild(close);
    pop.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeFloat(true); }
    });
    showFloat(pop, anchor);
    close.focus();
  }

  function buildCard(card, vm) {
    card.__vm = vm;
    var top = el('div', 'tb-card-top');
    var title = el('span', 'tb-card-title', vm.task);
    title.title = vm.task;
    top.appendChild(title);
    var mb = btn(String.fromCharCode(8942), 'tb-card-menu');
    mb.setAttribute('aria-label', 'Actions for ' + vm.task);
    mb.setAttribute('aria-haspopup', 'menu');
    mb.setAttribute('data-fkey', 'menu');
    mb.addEventListener('click', function (e) { e.stopPropagation(); openCardMenu(mb, vm); });
    mb.addEventListener('keydown', function (e) { e.stopPropagation(); });
    top.appendChild(mb);
    card.appendChild(top);

    var meta = el('div', 'tb-card-meta');
    if (vm.agent) { meta.appendChild(el('span', 'tb-agent tb-agent-' + agentCls(vm.agent), vm.agent)); }
    if (vm.showRepo) { meta.appendChild(el('span', 'tb-chip tb-chip-repo', vm.repoName)); }
    if (vm.model) { meta.appendChild(el('span', 'tb-card-model', vm.model)); }
    if (vm.age) { meta.appendChild(el('span', 'tb-card-age', vm.age)); }
    card.appendChild(meta);

    if (vm.col === 'queued') {
      card.appendChild(el('div', 'tb-waiting', vm.waiting ? 'waiting: ' + vm.waiting : 'about to start'));
      if (vm.overlaps.length) {
        var ob = el('div', 'tb-overlap', 'overlap: ' + vm.overlaps.join(', '));
        ob.title = 'Scope overlaps with: ' + vm.overlaps.join(', ');
        card.appendChild(ob);
      }
    } else if (vm.status && vm.col !== 'merged' && vm.col !== 'cancelled') {
      card.appendChild(el('div', 'tb-card-status tb-card-status-' + safeCls(vm.col), vm.status));
    }
  }

  function createCard(key) {
    var card = el('div', 'tb-card');
    card.setAttribute('role', 'listitem');
    card.tabIndex = 0;
    card.addEventListener('click', function (e) {
      var vm = card.__vm;
      if (!vm || e.target.closest('.tb-card-menu')) { return; }
      if (vm.col === 'queued') { openQueuePopover(vm, card); return; }
      T.openTask(vm.path, vm.task, 'log');
    });
    card.addEventListener('keydown', function (e) {
      if (e.target !== card) { return; }
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); card.click(); }
    });
    card.addEventListener('dragstart', function (e) {
      var vm = card.__vm;
      if (!vm || !vm.draggable) { e.preventDefault(); return; }
      closeFloat(false);
      bd.drag = { key: vm.key, col: vm.col, path: vm.path, task: vm.task, agent: vm.agent, queueIdx: vm.queueIdx, queueLen: vm.queueLen };
      bd.insertBefore = null;
      if (e.dataTransfer) { e.dataTransfer.effectAllowed = 'move'; try { e.dataTransfer.setData('text/plain', vm.task); } catch (x) { /* ignore */ } }
      window.setTimeout(function () {
        if (!bd.drag) { return; }
        card.classList.add('tb-dragging-card');
        bd.root.classList.add('tb-dragging');
        COLUMNS.concat(['cancelled']).forEach(function (n) {
          var c = bd.cols[n].col;
          c.classList.add(planDrop(bd.drag, n).ok ? 'tb-drop-ok' : 'tb-drop-no');
        });
      }, 0);
    });
    card.addEventListener('dragend', function () { endDrag(); });
    return card;
  }

  function syncColumn(colName, list, keep) {
    var c = bd.cols[colName];
    var ref = c.body.firstChild;
    list.forEach(function (vm) {
      keep[vm.key] = true;
      var card = bd.cards[vm.key];
      if (!card) { card = createCard(vm.key); bd.cards[vm.key] = card; }
      card.draggable = !!vm.draggable;
      card.setAttribute('aria-label', vm.task + ', ' + vm.col);
      patch(card, JSON.stringify(vm), function (n) { buildCard(n, vm); });
      if (ref === card) { ref = ref.nextSibling; } else { c.body.insertBefore(card, ref); }
    });
    while (ref) {
      var nxt = ref.nextSibling;
      c.body.removeChild(ref);
      ref = nxt;
    }
    c.count.textContent = String(list.length);
    c.empty.hidden = list.length > 0;
  }

  function mountBoard() {
    bd.root = el('div', 'tb-root tb-board');
    var bar = el('div', 'tb-toolbar');
    var lab = el('label', 'tb-label', 'Repo');
    bd.select = el('select', 'tb-select');
    bd.select.setAttribute('aria-label', 'Filter board by repo');
    bd.select.setAttribute('data-fkey', 'repo-filter');
    lab.appendChild(document.createTextNode(' '));
    lab.appendChild(bd.select);
    bar.appendChild(lab);
    bd.count = el('span', 'tb-toolbar-count', '');
    bar.appendChild(bd.count);
    bar.appendChild(el('span', 'tb-hint', 'Drag cards between columns, or use the card menu.'));
    bd.select.addEventListener('change', function () {
      bd.filter = bd.select.value || 'all';
      lsSet(FILTER_KEY, bd.filter);
      var s = T.getState && T.getState();
      if (s) { renderBoard(bd.root.parentNode, s); }
    });
    bd.root.appendChild(bar);
    bd.colsWrap = el('div', 'tb-cols');
    COLUMNS.forEach(function (n) {
      bd.cols[n] = createColumn(n);
      bd.colsWrap.appendChild(bd.cols[n].col);
    });
    var cc = createColumn('cancelled');
    bd.cols.cancelled = cc;
    var toggle = btn('Show', 'tb-btn tb-btn-sm tb-cancel-toggle', function () {
      bd.cancelOpen = !bd.cancelOpen;
      cc.col.classList.toggle('tb-open', bd.cancelOpen);
      toggle.textContent = bd.cancelOpen ? 'Hide' : 'Show';
      toggle.setAttribute('aria-expanded', bd.cancelOpen ? 'true' : 'false');
    });
    toggle.setAttribute('aria-expanded', 'false');
    toggle.setAttribute('aria-label', 'Show or hide cancelled tasks');
    cc.head.appendChild(toggle);
    cc.col.classList.add('tb-col-cancel');
    bd.colsWrap.appendChild(cc.col);
    bd.root.appendChild(bd.colsWrap);
  }

  function syncRepoSelect(repos) {
    var sig = JSON.stringify(repos.map(function (r) { return [str(r.path), repoName(r)]; }));
    if (sig !== bd.repoSig) {
      bd.repoSig = sig;
      clear(bd.select);
      var o = el('option', '', 'All repos');
      o.value = 'all';
      bd.select.appendChild(o);
      repos.forEach(function (r) {
        var op = el('option', '', repoName(r));
        op.value = str(r.path);
        bd.select.appendChild(op);
      });
    }
    var ok = bd.filter === 'all' || repos.some(function (r) { return str(r.path) === bd.filter; });
    if (!ok) { bd.filter = 'all'; }
    if (bd.select.value !== bd.filter) { bd.select.value = bd.filter; }
  }

  function renderBoard(container, state) {
    if (!bd.root) { mountBoard(); }
    if (container && bd.root.parentNode !== container) { container.appendChild(bd.root); }
    if (bd.drag) { bd.pending = { container: container, state: state }; return; }
    var repos = state && Array.isArray(state.repos) ? state.repos : [];
    syncRepoSelect(repos);
    var byCol = collectEntries(repos, bd.filter);
    var keep = {};
    var total = 0;
    COLUMNS.concat(['cancelled']).forEach(function (n) {
      var list = byCol[n];
      if (n === 'cancelled') {
        // cancelled cards only exist in the DOM while the zone is open, to keep the page light
        syncColumn(n, bd.cancelOpen ? list : [], keep);
        bd.cols[n].count.textContent = String(list.length);
        bd.cols[n].empty.hidden = bd.cancelOpen && list.length > 0;
      } else {
        syncColumn(n, list, keep);
        total += list.length;
      }
    });
    Object.keys(bd.cards).forEach(function (k) {
      if (!keep[k]) { delete bd.cards[k]; }
    });
    if (floating && floating.anchor && !floating.anchor.isConnected) { closeFloat(false); }
    bd.count.textContent = total + ' task' + (total === 1 ? '' : 's');
  }

  /* ================================================================
   * SETTINGS MODAL
   * ================================================================ */

  var layer = { settings: null, drawer: null };

  function focusables(root) {
    var list = root.querySelectorAll('button, input, select, textarea, [href], [tabindex]:not([tabindex="-1"])');
    return Array.prototype.filter.call(list, function (n) { return !n.disabled && n.offsetParent !== null; });
  }

  function openSettings(path) {
    path = str(path);
    if (layer.settings && layer.settings.path === path) { layer.settings.focus(); return; }
    if (layer.settings) { layer.settings.close(); }
    var repo = findRepo(path);
    var cfg = effConfig(repo);
    var ap = repo && isObj(repo.autopilot) ? repo.autopilot : {};
    var returnFocus = document.activeElement;
    var fields = [];

    var ovl = el('div', 'tb-modal-ov');
    var dlg = el('div', 'tb-modal');
    dlg.setAttribute('role', 'dialog');
    dlg.setAttribute('aria-modal', 'true');
    var titleId = 'tb-settings-title';
    dlg.setAttribute('aria-labelledby', titleId);
    var hd = el('div', 'tb-modal-head');
    var h = el('h2', 'tb-modal-title', 'Settings: ' + (repo ? repoName(repo) : basename(path)));
    h.id = titleId;
    hd.appendChild(h);
    var x = btn(String.fromCharCode(215), 'tb-icon-btn', function () { api.close(); });
    x.setAttribute('aria-label', 'Close settings');
    hd.appendChild(x);
    dlg.appendChild(hd);
    var bodyEl = el('form', 'tb-modal-body');
    bodyEl.noValidate = true;
    bodyEl.addEventListener('submit', function (e) { e.preventDefault(); save(); });

    function group(title) {
      var fs = el('fieldset', 'tb-fieldset');
      fs.appendChild(el('legend', '', title));
      bodyEl.appendChild(fs);
      return fs;
    }
    var idn = 0;
    function addField(fs, spec) {
      var id = 'tb-f-' + (++idn);
      var row = el('div', 'tb-field');
      var lab = el('label', 'tb-field-label', spec.label);
      lab.setAttribute('for', id);
      row.appendChild(lab);
      var wrap = el('div', 'tb-field-ctl');
      var input = el('input');
      input.id = id;
      var initial = getIn(cfg, spec.p);
      var f = { spec: spec, input: input, initial: initial, err: el('div', 'tb-field-err') };
      f.err.setAttribute('role', 'alert');
      if (spec.t === 'range') {
        input.type = 'range'; input.min = String(spec.min); input.max = String(spec.max); input.step = '1';
        input.value = String(initial);
        var out = el('output', 'tb-range-out', String(initial));
        out.setAttribute('for', id);
        input.addEventListener('input', function () { out.textContent = input.value; validateAll(); });
        wrap.appendChild(input); wrap.appendChild(out);
      } else if (spec.t === 'number') {
        input.type = 'number'; input.min = String(spec.min); input.max = String(spec.max); input.step = '1';
        input.value = String(initial);
        input.addEventListener('input', validateAll);
        wrap.appendChild(input);
      } else if (spec.t === 'bool') {
        input.type = 'checkbox';
        input.checked = !!initial;
        input.addEventListener('change', validateAll);
        wrap.appendChild(input);
      } else {
        input.type = 'text';
        input.value = str(initial);
        input.placeholder = spec.ph || '';
        input.autocomplete = 'off';
        input.spellcheck = false;
        input.addEventListener('input', validateAll);
        wrap.appendChild(input);
      }
      if (spec.hint) { wrap.appendChild(el('div', 'tb-field-hint', spec.hint)); }
      wrap.appendChild(f.err);
      row.appendChild(wrap);
      fs.appendChild(row);
      fields.push(f);
      return f;
    }

    var g1 = group('Slots per agent');
    AGENTS.forEach(function (a) { addField(g1, { p: ['slots', a], t: 'range', min: 0, max: 8, label: a }); });
    var g2 = group('Runs');
    addField(g2, { p: ['base'], t: 'text', label: 'Base branch', ph: '(default)' });
    addField(g2, { p: ['test'], t: 'text', label: 'Test command', ph: '(from AGENTS.md)' });
    addField(g2, { p: ['maxRounds'], t: 'range', min: 1, max: 10, label: 'Max rounds' });
    addField(g2, { p: ['deadlineMinutes'], t: 'number', min: 5, max: 1440, label: 'Deadline (minutes)' });
    var g3 = group('Model per agent');
    AGENTS.forEach(function (a) { addField(g3, { p: ['models', a], t: 'text', label: a, ph: '(default)' }); });
    var g4 = group('Autopilot');
    var allowed = !!ap.autoMergeAllowed;
    var need = cfg.autopilot.cleanRunsBeforeAutoMerge;
    var have = Number(ap.cleanRuns) || 0;
    var am = addField(g4, {
      p: ['autoMerge'], t: 'bool', label: 'Auto-merge',
      hint: allowed || cfg.autoMerge ? 'Takes effect only when approval mode is off.' : ('needs ' + need + ' clean runs, have ' + have)
    });
    if (!allowed && !cfg.autoMerge) { am.input.disabled = true; am.input.title = 'needs ' + need + ' clean runs, have ' + have; }
    addField(g4, { p: ['autopilot', 'approval'], t: 'bool', label: 'Approval mode', hint: 'On: autopilot marks tasks ready and waits for you to merge.' });
    addField(g4, { p: ['autopilot', 'maxTasksPerHour'], t: 'number', min: 1, max: 60, label: 'Max tasks per hour' });
    addField(g4, { p: ['autopilot', 'maxConsecutiveFailures'], t: 'number', min: 1, max: 20, label: 'Max consecutive failures' });
    dlg.appendChild(bodyEl);

    var ft = el('div', 'tb-modal-foot');
    var status = el('span', 'tb-modal-status');
    var cancelB = btn('Cancel', 'tb-btn', function () { api.close(); });
    var saveB = btn('Save', 'tb-btn tb-btn-primary', function () { save(); });
    ft.appendChild(status); ft.appendChild(cancelB); ft.appendChild(saveB);
    dlg.appendChild(ft);
    ovl.appendChild(dlg);

    function readField(f) {
      var s = f.spec;
      if (s.t === 'bool') { return { v: !!f.input.checked }; }
      if (s.t === 'text') { return { v: f.input.value.trim() }; }
      var raw = f.input.value.trim();
      var n = Number(raw);
      if (raw === '' || !isFinite(n) || Math.floor(n) !== n || n < s.min || n > s.max) {
        return { err: 'Enter a whole number from ' + s.min + ' to ' + s.max };
      }
      return { v: n };
    }
    function validateAll() {
      var bad = 0;
      fields.forEach(function (f) {
        var r = readField(f);
        f.err.textContent = r.err || '';
        f.input.setAttribute('aria-invalid', r.err ? 'true' : 'false');
        if (r.err) { bad++; }
      });
      saveB.disabled = bad > 0;
      status.textContent = bad ? (bad + ' value' + (bad === 1 ? '' : 's') + ' out of range') : '';
      return bad === 0;
    }
    function save() {
      if (!validateAll()) { return; }
      var patchObj = {};
      var n = 0;
      fields.forEach(function (f) {
        var v = readField(f).v;
        var init = f.initial;
        if (f.spec.t === 'text') { init = str(init); }
        if (f.spec.t === 'bool') { init = !!init; }
        if (v !== init) { setIn(patchObj, f.spec.p, v); n++; }
      });
      if (!n) { T.toast('No changes to save', 'warn'); return; }
      saveB.disabled = true;
      run({ action: 'settings-save', repo: path, task: '', config: patchObj, confirm: true }).then(function (r) {
        if (r.ok) { api.close(); } else { validateAll(); }
      });
    }
    dlg.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { if (floating) { return; } e.preventDefault(); e.stopPropagation(); api.close(); return; }
      if (e.key !== 'Tab') { return; }
      var f = focusables(dlg);
      if (!f.length) { return; }
      var first = f[0];
      var last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });
    ovl.addEventListener('mousedown', function (e) { if (e.target === ovl) { api.close(); } });

    var api = {
      path: path,
      focus: function () { var f = focusables(dlg); if (f.length) { f[0].focus(); } },
      close: function () {
        if (layer.settings !== api) { return; }
        layer.settings = null;
        if (ovl.parentNode) { ovl.parentNode.removeChild(ovl); }
        if (returnFocus && returnFocus.isConnected && returnFocus.focus) { returnFocus.focus(); }
      }
    };
    layer.settings = api;
    document.body.appendChild(ovl);
    validateAll();
    api.focus();
  }

  /* ================================================================
   * AUTOPILOT DRAWER
   * ================================================================ */

  function autopilotVM(repo) {
    var ap = isObj(repo.autopilot) ? repo.autopilot : {};
    var cfg = effConfig(repo);
    var sch = isObj(repo.scheduler) ? repo.scheduler : {};
    var queue = arr(repo.queue);
    var decisions = arr(ap.decisions).slice(0, 20).map(function (d) {
      return { at: str(d && d.at), task: str(d && d.task), action: str(d && d.action), reason: str(d && d.reason), round: d && d.round !== undefined ? str(d.round) : '' };
    });
    var hourAgo = Date.now() - 3600000;
    var startedHour = decisions.filter(function (d) { return d.action === 'started' && parseTime(d.at) >= hourAgo; }).length;
    var failRun = 0;
    for (var i = 0; i < decisions.length; i++) {
      if (decisions[i].action === 'failed') { failRun++; } else if (decisions[i].action === 'merged' || decisions[i].action === 'ready' || decisions[i].action === 'started') { break; }
    }
    var rounds = [];
    if (isObj(ap.roundsUsed)) {
      Object.keys(ap.roundsUsed).forEach(function (k) { rounds.push([k, Number(ap.roundsUsed[k]) || 0]); });
    }
    return {
      path: str(repo.path), name: repoName(repo),
      enabled: !!ap.enabled, paused: !!ap.paused, pauseReason: str(ap.pauseReason), limitBreach: str(ap.limitBreach),
      approval: cfg.autopilot.approval, autoMerge: !!cfg.autoMerge, autoMergeAllowed: !!ap.autoMergeAllowed,
      cleanRuns: Number(ap.cleanRuns) || 0, cleanNeed: cfg.autopilot.cleanRunsBeforeAutoMerge,
      maxPerHour: cfg.autopilot.maxTasksPerHour, maxFail: cfg.autopilot.maxConsecutiveFailures,
      maxRounds: cfg.maxRounds, startedHour: startedHour, failRun: failRun,
      alive: sch.alive === undefined ? null : !!sch.alive,
      now: str(sch.now), next: str(sch.next) || (queue.length ? str(queue[0].task) : ''),
      rounds: rounds, decisions: decisions
    };
  }

  function kvRow(dl, k, v, cls) {
    dl.appendChild(el('dt', '', k));
    dl.appendChild(el('dd', cls || '', v));
  }

  function buildDrawerBody(n, vm) {
    var chips = el('div', 'tb-dr-chips');
    chips.appendChild(el('span', 'tb-chip ' + (vm.enabled ? 'tb-chip-ok' : 'tb-chip-muted'), vm.enabled ? 'autopilot on' : 'autopilot off'));
    chips.appendChild(el('span', 'tb-chip tb-chip-muted', vm.approval ? 'approval mode' : (vm.autoMerge && vm.autoMergeAllowed ? 'auto-merge' : 'approval mode (auto-merge locked)')));
    if (vm.alive !== null) { chips.appendChild(el('span', 'tb-chip ' + (vm.alive ? 'tb-chip-ok' : 'tb-chip-muted'), vm.alive ? 'scheduler alive' : 'scheduler off')); }
    if (vm.paused) { chips.appendChild(el('span', 'tb-chip tb-chip-warn', 'paused')); }
    n.appendChild(chips);

    var s1 = el('section', 'tb-dr-sec');
    s1.appendChild(el('h3', 'tb-dr-h', 'Now'));
    var dl = el('dl', 'tb-kv');
    kvRow(dl, 'Doing', vm.now || '-');
    kvRow(dl, 'Next queued', vm.next || '-');
    s1.appendChild(dl);
    n.appendChild(s1);

    var s2 = el('section', 'tb-dr-sec');
    s2.appendChild(el('h3', 'tb-dr-h', 'Rounds used'));
    if (vm.rounds.length) {
      var rl = el('ul', 'tb-rounds');
      vm.rounds.forEach(function (r) {
        var li = el('li', r[1] >= vm.maxRounds ? 'tb-rounds-full' : '');
        li.appendChild(el('span', 'tb-rounds-task', r[0]));
        li.appendChild(el('span', 'tb-rounds-n', r[1] + ' / ' + vm.maxRounds));
        rl.appendChild(li);
      });
      s2.appendChild(rl);
    } else { s2.appendChild(el('p', 'tb-muted', 'No task has been resumed yet.')); }
    n.appendChild(s2);

    var s3 = el('section', 'tb-dr-sec');
    s3.appendChild(el('h3', 'tb-dr-h', 'Limits'));
    var dl2 = el('dl', 'tb-kv');
    kvRow(dl2, 'Tasks per hour', 'max ' + vm.maxPerHour + ' (started in last hour: ' + vm.startedHour + ')');
    kvRow(dl2, 'Consecutive failures', 'max ' + vm.maxFail + ' (current: ' + vm.failRun + ')');
    kvRow(dl2, 'Max rounds per task', String(vm.maxRounds));
    kvRow(dl2, 'Approval mode', vm.approval ? 'on' : 'off');
    kvRow(dl2, 'Clean runs for auto-merge', vm.cleanRuns + ' of ' + vm.cleanNeed);
    s3.appendChild(dl2);
    s3.appendChild(el('p', 'tb-muted tb-small', 'Counts are derived from the last 20 decisions.'));
    n.appendChild(s3);

    var s4 = el('section', 'tb-dr-sec');
    s4.appendChild(el('h3', 'tb-dr-h', 'Last decisions (' + vm.decisions.length + ')'));
    if (vm.decisions.length) {
      var ul = el('ul', 'tb-decisions');
      vm.decisions.forEach(function (d) {
        var li = el('li', 'tb-dec');
        var line = el('div', 'tb-dec-line');
        line.appendChild(el('span', 'tb-dec-time', clockText(d.at)));
        line.appendChild(el('span', 'tb-act tb-act-' + safeCls(d.action), d.action || '?'));
        if (d.task) { line.appendChild(el('span', 'tb-dec-task', d.task)); }
        if (d.round) { line.appendChild(el('span', 'tb-dec-round', 'round ' + d.round)); }
        li.appendChild(line);
        if (d.reason) { li.appendChild(el('div', 'tb-dec-reason', d.reason)); }
        ul.appendChild(li);
      });
      s4.appendChild(ul);
    } else { s4.appendChild(el('p', 'tb-muted', 'No decisions yet.')); }
    n.appendChild(s4);
  }

  function openAutopilot(path) {
    path = str(path);
    if (layer.drawer && layer.drawer.path === path) { layer.drawer.focus(); return; }
    if (layer.drawer) { layer.drawer.close(false); }
    var returnFocus = document.activeElement;

    var dr = el('aside', 'tb-drawer');
    dr.setAttribute('role', 'dialog');
    dr.setAttribute('aria-labelledby', 'tb-drawer-title');
    var hd = el('div', 'tb-drawer-head');
    var title = el('h2', 'tb-drawer-title', 'Autopilot');
    title.id = 'tb-drawer-title';
    hd.appendChild(title);
    var x = btn(String.fromCharCode(215), 'tb-icon-btn', function () { api.close(true); });
    x.setAttribute('aria-label', 'Close autopilot panel');
    hd.appendChild(x);
    var banner = el('div', 'tb-drawer-banner');
    var body = el('div', 'tb-drawer-body');
    body.tabIndex = 0;
    var foot = el('div', 'tb-drawer-foot');
    dr.appendChild(hd); dr.appendChild(banner); dr.appendChild(body); dr.appendChild(foot);

    function update() {
      var repo = findRepo(path);
      if (!repo) {
        patch(banner, 'x', function () {});
        patch(body, 'missing', function (n) { n.appendChild(el('p', 'tb-muted', 'This repo is not in the current state.')); });
        return;
      }
      var vm = autopilotVM(repo);
      title.textContent = 'Autopilot: ' + vm.name;
      patch(banner, JSON.stringify([vm.limitBreach, vm.paused, vm.pauseReason]), function (n) {
        if (vm.limitBreach) {
          var b = el('div', 'tb-banner tb-banner-bad', 'Limit breached: ' + vm.limitBreach);
          b.setAttribute('role', 'alert');
          n.appendChild(b);
        }
        if (vm.paused) {
          n.appendChild(el('div', 'tb-banner tb-banner-warn', 'Paused: ' + (vm.pauseReason || 'no reason given')));
        }
      });
      patch(body, JSON.stringify(vm), function (n) { buildDrawerBody(n, vm); });
      patch(foot, String(vm.paused), function (n) {
        var stop = btn('STOP autopilot', 'tb-btn-stop', function () {
          run({ action: 'pause', repo: path, task: '', reason: 'user' });
        });
        stop.setAttribute('data-fkey', 'stop');
        n.appendChild(stop);
        if (vm.paused) {
          var un = btn('Unpause', 'tb-btn', function () { run({ action: 'unpause', repo: path, task: '', confirm: true }); });
          un.setAttribute('data-fkey', 'unpause');
          n.appendChild(un);
        }
      });
    }

    dr.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { if (floating) { return; } e.preventDefault(); e.stopPropagation(); api.close(true); }
    });
    var unsub = typeof T.onState === 'function' ? T.onState(update) : null;
    var api = {
      path: path,
      focus: function () { x.focus(); },
      close: function (restore) {
        if (layer.drawer !== api) { return; }
        layer.drawer = null;
        if (typeof unsub === 'function') { unsub(); }
        if (dr.parentNode) { dr.parentNode.removeChild(dr); }
        if (restore && returnFocus && returnFocus.isConnected && returnFocus.focus) { returnFocus.focus(); }
      }
    };
    layer.drawer = api;
    document.body.appendChild(dr);
    update();
    x.focus();
  }

  /* Escape for the drawer when focus is elsewhere on the page. */
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape' || e.defaultPrevented) { return; }
    if (floating) { closeFloat(true); return; }
    if (layer.settings) { layer.settings.close(); return; }
    if (layer.drawer && layer.drawer.focus && layer.drawer.path !== undefined) {
      var d = document.querySelector('.tb-drawer');
      if (d && d.contains(document.activeElement)) { layer.drawer.close(true); }
    }
  });

  /* ---------- register ---------- */

  window.TrinityBoard = { openAutopilot: openAutopilot, openSettings: openSettings };
  T.addView('overview', 'Overview', renderOverview);
  T.addView('board', 'Board', renderBoard);
}());
