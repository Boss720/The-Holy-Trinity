'use strict';

// PNG: keep an allowlist of chunks needed to render; drop text, time, EXIF and unknown chunks.

const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const KEEP = new Set([
  'IHDR', 'PLTE', 'IDAT', 'IEND',
  'tRNS', 'gAMA', 'cHRM', 'sRGB', 'iCCP', 'sBIT', 'cICP', 'mDCV', 'cLLI',
  'bKGD', 'hIST', 'pHYs', 'sPLT',
  'acTL', 'fcTL', 'fdAT',
]);

const LABELS = {
  tEXt: 'Text comment',
  zTXt: 'Text comment',
  iTXt: 'Text / XMP',
  eXIf: 'EXIF',
  tIME: 'Modification time',
};

function strip(buf) {
  if (buf.length < 8 || !buf.subarray(0, 8).equals(SIG)) throw new Error('Not a valid PNG file');
  const kept = [SIG];
  const removed = [];
  let pos = 8;
  let sawEnd = false;
  while (pos + 12 <= buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('latin1', pos + 4, pos + 8);
    const end = pos + 12 + len;
    if (end > buf.length) throw new Error('Corrupt PNG: chunk overruns file');
    if (KEEP.has(type)) {
      kept.push(buf.subarray(pos, end));
    } else {
      removed.push(LABELS[type] || `Private chunk (${type})`);
    }
    pos = end;
    if (type === 'IEND') {
      sawEnd = true;
      break;
    }
  }
  if (!sawEnd) throw new Error('Corrupt PNG: missing IEND');
  if (pos < buf.length) removed.push(`Trailing data after image (${buf.length - pos} bytes)`);
  return { data: Buffer.concat(kept), removed: [...new Set(removed)] };
}

module.exports = { strip };
