'use strict';

const { app, BrowserWindow, dialog, ipcMain, shell } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { stripBuffer, isSupported, extOf, SUPPORTED_EXTENSIONS } = require('./strip');

const MAX_BYTES = 512 * 1024 * 1024;
const MAX_EXPANDED = 5000;

let win = null;

function createWindow() {
  win = new BrowserWindow({
    width: 980,
    height: 700,
    minWidth: 720,
    minHeight: 520,
    backgroundColor: '#14161a',
    title: 'MetaStrip',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.setMenuBarVisibility(false);
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.on('closed', () => {
    win = null;
  });
}

async function expandPaths(inputs) {
  const out = [];
  const seen = new Set();
  async function walk(p, nested) {
    if (out.length >= MAX_EXPANDED) return;
    let st;
    try {
      // Inside a folder, never follow symlinks/junctions: one pointing at an ancestor would loop forever.
      st = nested ? await fs.lstat(p) : await fs.stat(p);
    } catch {
      return;
    }
    if (st.isSymbolicLink()) return;
    if (st.isDirectory()) {
      const entries = await fs.readdir(p);
      for (const name of entries.sort()) await walk(path.join(p, name), true);
    } else if (st.isFile() && isSupported(p) && !seen.has(p)) {
      seen.add(p);
      out.push(p);
    }
  }
  for (const p of inputs) await walk(p, false);
  return out;
}

async function uniqueWrite(dir, base, ext, data) {
  for (let n = 0; n < 1000; n++) {
    const name = `${base}_clean${n ? ` (${n + 1})` : ''}${ext}`;
    const target = path.join(dir, name);
    try {
      await fs.writeFile(target, data, { flag: 'wx' });
      return target;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
    }
  }
  throw new Error('Could not find a free output file name');
}

async function processOne(file, outDir, write) {
  const name = path.basename(file);
  const res = { path: file, name, ok: false };
  try {
    const st = await fs.stat(file);
    if (st.size > MAX_BYTES) throw new Error('File is larger than 512 MB');
    const ext = extOf(file);
    const input = await fs.readFile(file);
    const { data, removed } = await stripBuffer(input, ext);
    res.removed = removed;
    res.sizeBefore = input.length;
    res.sizeAfter = data.length;
    if (write) {
      const dir = outDir || path.dirname(file);
      const base = path.basename(file, path.extname(file));
      res.outPath = await uniqueWrite(dir, base, path.extname(file), data);
    }
    res.ok = true;
  } catch (e) {
    res.error = e.message || String(e);
  }
  return res;
}

ipcMain.handle('files:pick', async () => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Choose files',
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: 'Supported files', extensions: SUPPORTED_EXTENSIONS },
      { name: 'All files', extensions: ['*'] },
    ],
  });
  return r.canceled ? [] : expandPaths(r.filePaths);
});

ipcMain.handle('files:pickFolder', async (_e, title) => {
  const r = await dialog.showOpenDialog(win, {
    title: title || 'Choose folder',
    properties: ['openDirectory', 'createDirectory'],
  });
  return r.canceled ? null : r.filePaths[0];
});

ipcMain.handle('files:expand', (_e, inputs) => expandPaths(Array.isArray(inputs) ? inputs.filter((p) => typeof p === 'string') : []));

ipcMain.handle('files:scan', async (_e, files) => {
  const results = [];
  for (const f of files) results.push(await processOne(f, null, false));
  return results;
});

ipcMain.handle('files:strip', async (_e, files, outDir) => {
  const results = [];
  for (const f of files) results.push(await processOne(f, outDir || null, true));
  return results;
});

ipcMain.handle('shell:reveal', (_e, p) => {
  if (typeof p === 'string') shell.showItemInFolder(p);
});

const lock = app.requestSingleInstanceLock();
if (!lock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });
  app.whenReady().then(() => {
    createWindow();
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
  });
  app.on('window-all-closed', () => {
    app.quit();
  });
}
