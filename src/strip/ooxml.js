'use strict';

// Office Open XML (docx/xlsx/pptx): remove docProps/* (author, company, thumbnail, custom props)
// along with the relationships and content-type entries that point at them.

const { loadZipSafe } = require('./zipguard');

function xmlValue(xml, tag) {
  const m = xml.match(new RegExp(`<${tag}(?:\\s[^>]*)?>([^<]+)</${tag}>`));
  return m ? m[1].trim().replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>') : '';
}

async function strip(buf) {
  if (buf.length < 4 || buf[0] !== 0x50 || buf[1] !== 0x4b) throw new Error('Not a valid Office file');
  const zip = await loadZipSafe(buf);
  const removed = [];

  const core = zip.file('docProps/core.xml');
  if (core) {
    const xml = await core.async('string');
    const author = xmlValue(xml, 'dc:creator');
    const last = xmlValue(xml, 'cp:lastModifiedBy');
    if (author) removed.push(`Author "${author}"`);
    if (last && last !== author) removed.push(`Last modified by "${last}"`);
    if (xmlValue(xml, 'dc:title')) removed.push('Title');
    if (xmlValue(xml, 'dc:subject')) removed.push('Subject');
    if (xmlValue(xml, 'cp:keywords')) removed.push('Keywords');
    removed.push('Created / modified dates');
  }
  const app = zip.file('docProps/app.xml');
  if (app) {
    const xml = await app.async('string');
    const company = xmlValue(xml, 'Company');
    const manager = xmlValue(xml, 'Manager');
    if (company) removed.push(`Company "${company}"`);
    if (manager) removed.push(`Manager "${manager}"`);
    removed.push('Application info');
  }
  if (zip.file('docProps/custom.xml')) removed.push('Custom properties');
  if (zip.file(/^docProps\/thumbnail\./).length) removed.push('Thumbnail preview');

  for (const name of Object.keys(zip.files)) {
    if (name.startsWith('docProps/')) zip.remove(name);
  }

  const rels = zip.file('_rels/.rels');
  if (rels) {
    const xml = await rels.async('string');
    zip.file('_rels/.rels', xml.replace(/<Relationship\b[^>]*\bTarget="\/?docProps\/[^"]*"[^>]*\/>/g, ''));
  }
  const types = zip.file('[Content_Types].xml');
  if (types) {
    const xml = await types.async('string');
    zip.file('[Content_Types].xml', xml.replace(/<Override\b[^>]*\bPartName="\/docProps\/[^"]*"[^>]*\/>/g, ''));
  }

  const data = await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE', compressionOptions: { level: 6 } });
  return { data, removed };
}

module.exports = { strip };
