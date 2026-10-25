'use strict';

// Zip-bomb guard: check declared uncompressed sizes from the central directory before inflating anything.

const JSZip = require('jszip');

const MAX_ENTRY = 256 * 1024 * 1024;
const MAX_TOTAL = 1024 * 1024 * 1024;

async function loadZipSafe(buf, limits = {}) {
  const maxEntry = limits.maxEntry ?? MAX_ENTRY;
  const maxTotal = limits.maxTotal ?? MAX_TOTAL;
  const zip = await JSZip.loadAsync(buf);
  let total = 0;
  for (const f of Object.values(zip.files)) {
    const size = (f._data && f._data.uncompressedSize) || 0;
    if (size > maxEntry) throw new Error(`Archive entry too large to process: ${f.name}`);
    total += size;
    if (total > maxTotal) throw new Error('Archive expands too large to process');
  }
  return zip;
}

module.exports = { loadZipSafe };
