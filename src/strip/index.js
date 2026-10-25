'use strict';

const path = require('node:path');
const jpeg = require('./jpeg');
const png = require('./png');
const webp = require('./webp');
const pdf = require('./pdf');
const ooxml = require('./ooxml');

const HANDLERS = {
  jpg: jpeg.strip,
  jpeg: jpeg.strip,
  png: png.strip,
  webp: webp.strip,
  pdf: pdf.strip,
  docx: ooxml.strip,
  xlsx: ooxml.strip,
  pptx: ooxml.strip,
};

const SUPPORTED_EXTENSIONS = Object.keys(HANDLERS);

function extOf(file) {
  return path.extname(file).slice(1).toLowerCase();
}

function isSupported(file) {
  return extOf(file) in HANDLERS;
}

/** @returns {Promise<{data: Buffer, removed: string[]}>} */
async function stripBuffer(buf, ext) {
  const handler = HANDLERS[ext];
  if (!handler) throw new Error(`Unsupported file type: .${ext}`);
  return handler(buf);
}

module.exports = { stripBuffer, isSupported, extOf, SUPPORTED_EXTENSIONS };
