'use strict';

// OpenDocument: remove document properties, thumbnails, printer settings, and their manifest entries.

const JSZip = require('jszip');
const { loadZipSafe } = require("./zipguard");

async function strip(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 4 || buf[0] !== 0x50 || buf[1] !== 0x4b) {
    throw new Error('Not a valid OpenDocument file');
  }

  const zip = await loadZipSafe(buf);
  const mimetype = zip.file('mimetype');
  if (!mimetype || !(await mimetype.async('string')).startsWith('application/vnd.oasis.opendocument.')) {
    throw new Error('Not a valid OpenDocument file');
  }

  const removed = [];
  const labels = new Set();
  const names = Object.keys(zip.files);
  const removeNames = new Set();

  for (const name of names) {
    if (name === 'meta.xml') {
      removeNames.add(name);
      if (!labels.has('Document properties')) {
        labels.add('Document properties');
        removed.push('Document properties');
      }
    } else if (name.startsWith('Thumbnails/')) {
      removeNames.add(name);
      if (!labels.has('Thumbnail')) {
        labels.add('Thumbnail');
        removed.push('Thumbnail');
      }
    }
  }

  const manifest = zip.file('META-INF/manifest.xml');
  if (manifest && removeNames.size) {
    const xml = await manifest.async('string');
    // Namespace prefixes are not fixed by the spec, so match any prefix.
    const updated = xml.replace(/<([\w.-]+):file-entry(?=[\s/>])[^>]*(?:\/>|>[\s\S]*?<\/\1:file-entry\s*>)/g, (element) => {
      const openingTag = element.match(/^<[\w.-]+:file-entry[^>]*>/);
      const path = openingTag && openingTag[0].match(/\s[\w.-]+:full-path\s*=\s*(['"])(.*?)\1/);
      if (!path) return element;
      const value = path[2];
      return value === 'meta.xml' || value.startsWith('Thumbnails/') ? '' : element;
    });
    if (updated !== xml) zip.file('META-INF/manifest.xml', updated);
  }

  const settings = zip.file('settings.xml');
  if (settings) {
    const xml = await settings.async('string');
    const updated = xml.replace(/<([\w.-]+):config-item(?=[\s/>])(?=[^>]*\s[\w.-]+:name\s*=\s*(['"])(?:PrinterName|PrinterSetup)\2)[^>]*(?:\/>|>[\s\S]*?<\/\1:config-item\s*>)/g, '');
    if (updated !== xml) {
      zip.file('settings.xml', updated);
      if (!labels.has('Printer settings')) {
        labels.add('Printer settings');
        removed.push('Printer settings');
      }
    }
  }

  const output = new JSZip();
  const orderedNames = ['mimetype', ...names.filter((name) => name !== 'mimetype' && !removeNames.has(name))];
  for (const name of orderedNames) {
    const entry = zip.files[name];
    const data = await entry.async('nodebuffer');
    output.file(name, data, {
      date: entry.date,
      dir: entry.dir,
      unixPermissions: entry.unixPermissions,
      dosPermissions: entry.dosPermissions,
      comment: entry.comment,
      createFolders: false,
      compression: name === 'mimetype' ? 'STORE' : 'DEFLATE',
    });
  }

  const data = await output.generateAsync({
    type: 'nodebuffer',
    compression: 'DEFLATE',
    compressionOptions: { level: 6 },
  });
  return { data, removed };
}

module.exports = { strip };
