'use strict';

const { PDFDocument, PDFName, PDFDict, PDFRef, PDFString, PDFHexString } = require('pdf-lib');

const INFO_KEYS = ['Title', 'Author', 'Subject', 'Keywords', 'Creator', 'Producer', 'CreationDate', 'ModDate'];
const DROP_KEYS = ['Metadata', 'PieceInfo', 'Thumb'];

function textOf(obj) {
  if (obj instanceof PDFString || obj instanceof PDFHexString) return obj.decodeText();
  return '';
}

async function strip(buf) {
  if (buf.subarray(0, 5).toString('latin1') !== '%PDF-') throw new Error('Not a valid PDF file');
  let doc;
  try {
    doc = await PDFDocument.load(buf, { updateMetadata: false });
  } catch (e) {
    if (/encrypt/i.test(e.message)) throw new Error('PDF is password protected; unlock it first');
    throw e;
  }
  const ctx = doc.context;
  const removed = [];

  const infoRef = ctx.trailerInfo.Info;
  if (infoRef) {
    const info = ctx.lookupMaybe(infoRef, PDFDict);
    if (info) {
      for (const key of INFO_KEYS) {
        const v = textOf(info.get(PDFName.of(key)));
        if (v && (key === 'Author' || key === 'Creator' || key === 'Producer' || key === 'Title')) {
          removed.push(`${key} "${v.length > 40 ? v.slice(0, 40) + '...' : v}"`);
        } else if (info.has(PDFName.of(key))) {
          removed.push(key);
        }
      }
    }
    if (infoRef instanceof PDFRef) ctx.delete(infoRef);
    delete ctx.trailerInfo.Info;
  }
  delete ctx.trailerInfo.ID;

  const dropFrom = (dict) => {
    for (const key of DROP_KEYS) {
      const name = PDFName.of(key);
      const val = dict.get(name);
      if (val === undefined) continue;
      if (val instanceof PDFRef) ctx.delete(val);
      dict.delete(name);
      removed.push(key === 'Metadata' ? 'XMP' : key === 'Thumb' ? 'Page thumbnails' : 'Application data');
    }
  };
  dropFrom(doc.catalog);
  for (const page of doc.getPages()) dropFrom(page.node);

  const data = Buffer.from(await doc.save({ useObjectStreams: false, updateFieldAppearances: false }));
  return { data, removed: [...new Set(removed)] };
}

module.exports = { strip };
