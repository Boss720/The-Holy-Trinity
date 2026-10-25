'use strict';

const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('metastrip', {
  pickFiles: () => ipcRenderer.invoke('files:pick'),
  pickFolder: (title) => ipcRenderer.invoke('files:pickFolder', title),
  pathsForDrop: (fileList) => Array.from(fileList, (f) => webUtils.getPathForFile(f)).filter(Boolean),
  expand: (paths) => ipcRenderer.invoke('files:expand', paths),
  scan: (files) => ipcRenderer.invoke('files:scan', files),
  strip: (files, outDir) => ipcRenderer.invoke('files:strip', files, outDir),
  reveal: (p) => ipcRenderer.invoke('shell:reveal', p),
});
