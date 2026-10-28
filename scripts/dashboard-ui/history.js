/* Trinity dashboard: History view (table from /api/history, filters, sort, CSV export).
 * Plain ES2019, no libraries. Only uses window.Trinity. Fetches only while shown, at most once per 10 s. */
(function () {
  'use strict';

  var T = window.Trinity;
  if (!T || typeof T.addView !== 'function') {
    if (window.console) { console.error('history.js: window.Trinity is missing'); }
    return;
  }

  var MIN_GAP_MS = 10000;
  var AGENTS = ['all', 'codex', 'antigravity', 'claude'];
  var OUTCOMES = ['all', 'merged', 'cancelled', 'failed'];
  var COLS = [
    { id: 'task', label: 'Task', type: 's' },
    { id: 'repo', label: 'Repo', type: 's' },
    { id: 'agent', label: 'Agent', type: 's' },
    { id: 'outcome', label: 'Outcome', type: 's' },
    { id: 'started', label: 'Started', type: 's' },
    { id: 'durationSec', label: 'Duration', type: 'n' },
    { id: 'commits', label: 'Commits', type: 'n' },
    { id: 'model', label: 'Model', type: 's' },
    { id: 'tokens', label: 'Tokens', type: 'n' }
  ];

  var h = {
    root: null, repoSel: null, agentSel: null, outSel: null, status: null, tbody: null, thead: null,
    exportBtn: null, refreshBtn: null, wrap: null, container: null,
    items: [], loaded: false, error: '', inflight: false, lastFetch: 0, lastQuery: null, timer: null,
    sort: { id: 'started', dir: -1 }, repoSig: null, rowSig: null
  };

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) { n.className = cls; }
    if (text !== undefined && text !== null && text !== '') { n.textContent = String(text); }
    return n;
  }
  function str(v) { return v === undefined || v === null ? '' : String(v); }
  function basename(p) {
    var parts = str(p).replace(/[\\\/]+$/, '').split(/[\\\/]/);
    return parts[parts.length - 1] || str(p);
  }
  function tokensOf(it) {
    var t = it.tokens;
    if (t && typeof t === 'object') { return Number(t.total) || 0; }
    return Number(t) || 0;
  }
  function numOf(it, id) {
    if (id === 'tokens') { return tokensOf(it); }
    var n = Number(it[id]);
    return isNaN(n) ? -1 : n;
  }
  function textOf(it, id) {
    if (id === 'repo') { return basename(it.repo); }
    return str(it[id]);
  }
  function fmtDuration(sec) {
    var n = Number(sec);
    if (sec === null || sec === undefined || sec === '' || isNaN(n)) { return ''; }
    n = Math.round(n);
    if (n < 60) { return n + 's'; }
    var m = Math.floor(n / 60);
    if (m < 60) { return m + 'm ' + (n % 60) + 's'; }
    return Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
  }
  function fmtStarted(s) {
    var t = Date.parse(String(s).replace(' ', 'T'));
    if (isNaN(t)) { return str(s); }
    var d = new Date(t);
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  /* ----- CSV (RFC 4180) ----- */
  function csvCell(v) {
    var s = str(v);
    // Spreadsheet formula guard for free text (task names, models, repo paths are untrusted).
    if (typeof v === 'string' && /^[=+\-@\t\r]/.test(s)) { s = "'" + s; }
    if (/[",\r\n]/.test(s)) { s = '"' + s.replace(/"/g, '""') + '"'; }
    return s;
  }
  function buildCsv(items) {
    var lines = [COLS.map(function (c) { return csvCell(c.label); }).join(',')];
    items.forEach(function (it) {
      lines.push([
        it.task, it.repo, it.agent, it.outcome, it.started,
        it.durationSec === null || it.durationSec === undefined ? '' : it.durationSec,
        it.commits === null || it.commits === undefined ? '' : it.commits,
        it.model, tokensOf(it)
      ].map(csvCell).join(','));
    });
    return lines.join('\r\n') + '\r\n';
  }
  function stamp() {
    var d = new Date();
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate());
  }
  function exportCsv() {
    var text = buildCsv(sortedItems());
    var blob = new Blob([text], { type: 'text/csv;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = 'trinity-history-' + stamp() + '.csv';
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    window.setTimeout(function () {
      if (a.parentNode) { a.parentNode.removeChild(a); }
      URL.revokeObjectURL(url);
    }, 1000);
    T.toast('Exported ' + h.items.length + ' rows', 'ok');
  }
  window.TrinityHistoryCsv = buildCsv; // exposed for the harness check

  /* ----- sorting ----- */
  function sortedItems() {
    var col = null;
    COLS.forEach(function (c) { if (c.id === h.sort.id) { col = c; } });
    var dir = h.sort.dir;
    var list = h.items.slice();
    list.sort(function (a, b) {
      var r;
      if (col && col.type === 'n') { r = numOf(a, col.id) - numOf(b, col.id); }
      else {
        var x = textOf(a, h.sort.id).toLowerCase();
        var y = textOf(b, h.sort.id).toLowerCase();
        r = x < y ? -1 : (x > y ? 1 : 0);
      }
      return r * dir;
    });
    return list;
  }

  /* ----- UI ----- */
  function labelled(text, control) {
    var l = el('label', '', text);
    l.className = 'tb-label';
    l.appendChild(control);
    return l;
  }
  function makeSelect(values, aria) {
    var s = el('select', 'tb-select');
    s.setAttribute('aria-label', aria);
    values.forEach(function (v) {
      var o = el('option', '', v);
      o.value = v;
      s.appendChild(o);
    });
    return s;
  }

  function mount() {
    h.root = el('div', 'tb-root tb-hist');
    var bar = el('div', 'tb-hist-bar');
    h.repoSel = makeSelect(['all'], 'Filter history by repo');
    h.agentSel = makeSelect(AGENTS, 'Filter history by agent');
    h.outSel = makeSelect(OUTCOMES, 'Filter history by outcome');
    [h.repoSel, h.agentSel, h.outSel].forEach(function (s) { s.addEventListener('change', onFilter); });
    bar.appendChild(labelled('Repo', h.repoSel));
    bar.appendChild(labelled('Agent', h.agentSel));
    bar.appendChild(labelled('Outcome', h.outSel));
    h.refreshBtn = el('button', 'tb-btn', 'Refresh');
    h.refreshBtn.type = 'button';
    h.refreshBtn.addEventListener('click', function () { schedule(true); });
    h.exportBtn = el('button', 'tb-btn', 'Export CSV');
    h.exportBtn.type = 'button';
    h.exportBtn.addEventListener('click', exportCsv);
    bar.appendChild(h.refreshBtn);
    bar.appendChild(h.exportBtn);
    h.status = el('span', 'tb-hist-status', '');
    h.status.setAttribute('role', 'status');
    bar.appendChild(h.status);
    h.root.appendChild(bar);

    h.wrap = el('div', 'tb-table-wrap');
    var table = el('table', 'tb-table');
    h.thead = el('thead');
    var tr = el('tr');
    COLS.forEach(function (c) {
      var th = el('th', c.type === 'n' ? 'tb-num' : '');
      th.scope = 'col';
      var b = el('button', 'tb-th-btn');
      b.type = 'button';
      b.appendChild(el('span', '', c.label));
      var arrow = el('span', 'tb-sort', '');
      arrow.setAttribute('aria-hidden', 'true');
      b.appendChild(arrow);
      b.addEventListener('click', function () {
        if (h.sort.id === c.id) { h.sort.dir = -h.sort.dir; } else { h.sort = { id: c.id, dir: c.type === 'n' ? -1 : 1 }; }
        drawRows();
      });
      th.appendChild(b);
      th.__c = c;
      tr.appendChild(th);
    });
    h.thead.appendChild(tr);
    table.appendChild(h.thead);
    h.tbody = el('tbody');
    table.appendChild(h.tbody);
    h.wrap.appendChild(table);
    h.root.appendChild(h.wrap);
  }

  function syncRepos(state) {
    var repos = state && Array.isArray(state.repos) ? state.repos : [];
    var sig = JSON.stringify(repos.map(function (r) { return [r.path, r.name]; }));
    if (sig === h.repoSig) { return; }
    h.repoSig = sig;
    var cur = h.repoSel.value;
    while (h.repoSel.firstChild) { h.repoSel.removeChild(h.repoSel.firstChild); }
    var all = el('option', '', 'all');
    all.value = 'all';
    h.repoSel.appendChild(all);
    repos.forEach(function (r) {
      var o = el('option', '', str(r.name) || basename(r.path));
      o.value = str(r.path);
      h.repoSel.appendChild(o);
    });
    h.repoSel.value = cur;
    if (h.repoSel.value !== cur) { h.repoSel.value = 'all'; }
  }

  function drawRows() {
    var list = sortedItems();
    var sig = JSON.stringify([h.sort, list, h.loaded, h.error]);
    // header arrows
    var ths = h.thead.querySelectorAll('th');
    for (var i = 0; i < ths.length; i++) {
      var c = ths[i].__c;
      var active = c && c.id === h.sort.id;
      ths[i].setAttribute('aria-sort', active ? (h.sort.dir > 0 ? 'ascending' : 'descending') : 'none');
      ths[i].querySelector('.tb-sort').textContent = active ? (h.sort.dir > 0 ? String.fromCharCode(9650) : String.fromCharCode(9660)) : '';
    }
    h.exportBtn.disabled = !list.length;
    if (sig === h.rowSig) { return; }
    h.rowSig = sig;
    while (h.tbody.firstChild) { h.tbody.removeChild(h.tbody.firstChild); }
    if (!list.length) {
      var tr0 = el('tr');
      var td0 = el('td', 'tb-table-empty', h.loaded ? 'No finished tasks match these filters.' : 'Loading history...');
      td0.colSpan = COLS.length;
      tr0.appendChild(td0);
      h.tbody.appendChild(tr0);
      return;
    }
    list.forEach(function (it) {
      var tr = el('tr');
      tr.appendChild(el('td', 'tb-wrap', it.task));
      var repoTd = el('td', '', basename(it.repo));
      repoTd.title = str(it.repo);
      tr.appendChild(repoTd);
      tr.appendChild(el('td', '', it.agent));
      var oc = el('td');
      var outcome = str(it.outcome);
      oc.appendChild(el('span', 'tb-out' + (/^[a-z]+$/.test(outcome) ? ' tb-out-' + outcome : ''), outcome));
      tr.appendChild(oc);
      tr.appendChild(el('td', '', it.started ? fmtStarted(it.started) : ''));
      tr.appendChild(el('td', 'tb-num', fmtDuration(it.durationSec)));
      tr.appendChild(el('td', 'tb-num', it.commits === null || it.commits === undefined ? '' : it.commits));
      tr.appendChild(el('td', '', it.model));
      tr.appendChild(el('td', 'tb-num', tokensOf(it) ? tokensOf(it).toLocaleString('en-US') : ''));
      h.tbody.appendChild(tr);
    });
  }

  function setStatus(text, isErr) {
    h.status.textContent = text;
    h.status.className = 'tb-hist-status' + (isErr ? ' tb-hist-err' : '');
  }

  function query() {
    return 'repo=' + encodeURIComponent(h.repoSel.value || 'all') +
      '&agent=' + encodeURIComponent(h.agentSel.value || 'all') +
      '&outcome=' + encodeURIComponent(h.outSel.value || 'all');
  }

  function isShown() {
    return !!(h.root && h.root.isConnected && h.root.offsetParent !== null && !document.hidden);
  }

  function doFetch() {
    if (h.inflight || !isShown()) { return; }
    h.inflight = true;
    h.lastFetch = Date.now();
    var q = query();
    h.lastQuery = q;
    setStatus('Loading...', false);
    var p;
    try { p = fetch('/api/history?' + q, { method: 'GET', cache: 'no-store' }); } catch (e) { p = Promise.reject(e); }
    p.then(function (res) {
      if (!res.ok) { throw new Error('HTTP ' + res.status); }
      return res.json();
    }).then(function (data) {
      h.items = data && Array.isArray(data.items) ? data.items.filter(function (x) { return x && typeof x === 'object'; }) : [];
      h.loaded = true;
      h.error = '';
      setStatus(h.items.length + ' row' + (h.items.length === 1 ? '' : 's') + ', updated ' + new Date().toTimeString().slice(0, 8), false);
    }).catch(function (err) {
      h.loaded = true;
      h.error = err && err.message ? err.message : 'failed';
      setStatus('Could not load history: ' + h.error, true);
    }).then(function () {
      h.inflight = false;
      drawRows();
    });
  }

  /* Fetch now if the 10 s gap has passed, otherwise at the earliest allowed moment. */
  function schedule(force) {
    if (h.timer) { window.clearTimeout(h.timer); h.timer = null; }
    var wait = Math.max(0, h.lastFetch + MIN_GAP_MS - Date.now());
    if (wait === 0) { doFetch(); return; }
    if (force) { setStatus('Refreshing in ' + Math.ceil(wait / 1000) + 's (limited to one request per 10 s)', false); }
    h.timer = window.setTimeout(function () { h.timer = null; doFetch(); }, wait);
  }

  function onFilter() { schedule(true); }

  function render(container, state) {
    if (!h.root) { mount(); }
    if (h.root.parentNode !== container) { container.appendChild(h.root); }
    h.container = container;
    syncRepos(state);
    drawRows();
    if (h.inflight || h.timer) { return; }
    if (query() !== h.lastQuery || Date.now() - h.lastFetch >= MIN_GAP_MS) { schedule(false); }
  }

  T.addView('history', 'History', render);
}());
