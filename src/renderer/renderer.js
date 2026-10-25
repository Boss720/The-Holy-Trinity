'use strict';

const $ = (id) => document.getElementById(id);
const dropEl = $('drop');
const listWrap = $('list-wrap');
const listEl = $('list');
const countEl = $('count');
const runBtn = $('run');
const statusEl = $('status');
const pickFolderBtn = $('pick-folder');
const folderPathEl = $('folder-path');

/** @type {Map<string, {path:string,name:string,state:'scanning'|'ready'|'done'|'error',removed?:string[],error?:string,outPath?:string,sizeBefore?:number,sizeAfter?:number}>} */
const items = new Map();
let outFolder = null;
let busy = false;

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function dirOf(p) {
  const i = Math.max(p.lastIndexOf('\\'), p.lastIndexOf('/'));
  return i > 0 ? p.slice(0, i) : '';
}

function fmtSize(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function chipFor(label) {
  const c = el('span', 'chip', label);
  if (label.startsWith('GPS')) c.classList.add('gps');
  if (label.startsWith('(')) c.classList.add('note');
  return c;
}

function render() {
  const all = [...items.values()];
  document.body.classList.toggle('has-files', all.length > 0);
  listWrap.hidden = all.length === 0;
  countEl.textContent = `${all.length} file${all.length === 1 ? '' : 's'}`;
  listEl.replaceChildren();

  for (const it of all) {
    const row = el('li', 'row');
    row.append(el('div', 'name', it.name));

    const right = el('div', 'right');
    if (it.state === 'scanning') right.append(el('span', 'badge', 'Scanning...'));
    else if (it.state === 'done') {
      right.append(el('span', 'badge done', 'Cleaned'));
      const show = el('button', 'small', 'Show');
      show.addEventListener('click', () => window.metastrip.reveal(it.outPath));
      right.append(show);
    } else if (it.state === 'ready' && !busy) {
      const rm = el('button', 'small', 'Remove');
      rm.addEventListener('click', () => {
        items.delete(it.path);
        update();
      });
      right.append(rm);
    }
    row.append(right);

    row.append(el('div', 'dir', '‎' + dirOf(it.path)));

    const chips = el('div', 'chips');
    if (it.state === 'error') chips.append(Object.assign(el('span', 'chip err', it.error)));
    else if (it.removed) {
      if (it.removed.length === 0) chips.append(el('span', 'chip clean', 'No metadata found'));
      else {
        const prefix = it.state === 'done' ? 'Removed: ' : '';
        if (prefix) chips.append(el('span', 'chip note', prefix.trim()));
        for (const r of it.removed) chips.append(chipFor(r));
      }
      if (it.state === 'done' && it.sizeBefore !== undefined) {
        chips.append(el('span', 'chip note', `${fmtSize(it.sizeBefore)} -> ${fmtSize(it.sizeAfter)}`));
      }
    }
    row.append(chips);
    listEl.append(row);
  }
}

function setStatus(text, kind) {
  statusEl.textContent = text || '';
  statusEl.className = 'status' + (kind ? ' ' + kind : '');
}

function update() {
  render();
  const pending = [...items.values()].filter((i) => i.state === 'ready').length;
  const needFolder = document.querySelector('input[name=out]:checked').value === 'folder' && !outFolder;
  runBtn.disabled = busy || pending === 0 || needFolder;
  runBtn.textContent = pending > 0 ? `Strip metadata (${pending})` : 'Strip metadata';
}

async function addPaths(paths) {
  if (!paths.length) return;
  const files = await window.metastrip.expand(paths);
  const fresh = files.filter((f) => !items.has(f));
  if (!files.length) {
    setStatus('No supported files found.', 'bad');
    return;
  }
  setStatus('');
  for (const f of fresh) {
    items.set(f, { path: f, name: f.split(/[\\/]/).pop(), state: 'scanning' });
  }
  update();
  const results = await window.metastrip.scan(fresh);
  for (const r of results) {
    const it = items.get(r.path);
    if (!it) continue;
    if (r.ok) Object.assign(it, { state: 'ready', removed: r.removed });
    else Object.assign(it, { state: 'error', error: r.error });
  }
  update();
}

dropEl.addEventListener('click', async () => addPaths(await window.metastrip.pickFiles()));
dropEl.addEventListener('keydown', async (e) => {
  if (e.key === 'Enter' || e.key === ' ') {
    e.preventDefault();
    addPaths(await window.metastrip.pickFiles());
  }
});

for (const t of ['dragenter', 'dragover']) {
  window.addEventListener(t, (e) => {
    e.preventDefault();
    dropEl.classList.add('over');
  });
}
for (const t of ['dragleave', 'drop']) {
  window.addEventListener(t, (e) => {
    e.preventDefault();
    if (t === 'drop' || e.relatedTarget === null) dropEl.classList.remove('over');
  });
}
window.addEventListener('drop', (e) => {
  addPaths(window.metastrip.pathsForDrop(e.dataTransfer.files));
});

$('clear').addEventListener('click', () => {
  if (busy) return;
  items.clear();
  setStatus('');
  update();
});

for (const r of document.querySelectorAll('input[name=out]')) {
  r.addEventListener('change', () => {
    const folder = document.querySelector('input[name=out]:checked').value === 'folder';
    pickFolderBtn.hidden = !folder;
    folderPathEl.hidden = !folder;
    update();
  });
}

pickFolderBtn.addEventListener('click', async () => {
  const p = await window.metastrip.pickFolder('Choose output folder');
  if (p) {
    outFolder = p;
    folderPathEl.textContent = '‎' + p;
    update();
  }
});

runBtn.addEventListener('click', async () => {
  const pending = [...items.values()].filter((i) => i.state === 'ready');
  if (!pending.length) return;
  const useFolder = document.querySelector('input[name=out]:checked').value === 'folder';
  busy = true;
  setStatus('Working...');
  update();
  const results = await window.metastrip.strip(pending.map((i) => i.path), useFolder ? outFolder : null);
  let ok = 0;
  let bad = 0;
  for (const r of results) {
    const it = items.get(r.path);
    if (!it) continue;
    if (r.ok) {
      Object.assign(it, { state: 'done', removed: r.removed, outPath: r.outPath, sizeBefore: r.sizeBefore, sizeAfter: r.sizeAfter });
      ok++;
    } else {
      Object.assign(it, { state: 'error', error: r.error });
      bad++;
    }
  }
  busy = false;
  setStatus(bad ? `${ok} cleaned, ${bad} failed.` : `${ok} file${ok === 1 ? '' : 's'} cleaned.`, bad ? 'bad' : 'ok');
  update();
});

update();
