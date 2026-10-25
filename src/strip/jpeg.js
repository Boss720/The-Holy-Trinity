'use strict';

// JPEG: drop every APPn (except JFIF/Adobe/ICC), COM, and trailing bytes after EOI.
// EXIF orientation is re-written into a minimal EXIF block so images do not rotate.

const SOI = 0xd8;
const EOI = 0xd9;
const SOS = 0xda;

function readTiff(buf, base) {
  // buf[base..] is a TIFF header. Returns { orientation, gps } or null.
  if (buf.length < base + 8) return null;
  const le = buf[base] === 0x49 && buf[base + 1] === 0x49;
  const be = buf[base] === 0x4d && buf[base + 1] === 0x4d;
  if (!le && !be) return null;
  const u16 = (o) => (le ? buf.readUInt16LE(o) : buf.readUInt16BE(o));
  const u32 = (o) => (le ? buf.readUInt32LE(o) : buf.readUInt32BE(o));
  const out = { orientation: 1, gps: false, camera: false };
  try {
    const ifd = base + u32(base + 4);
    const count = u16(ifd);
    for (let i = 0; i < count; i++) {
      const e = ifd + 2 + i * 12;
      const tag = u16(e);
      if (tag === 0x0112) out.orientation = u16(e + 8);
      else if (tag === 0x8825) out.gps = true;
      else if (tag === 0x010f || tag === 0x0110) out.camera = true;
    }
  } catch {
    // truncated EXIF: report what we have
  }
  return out;
}

function minimalExif(orientation) {
  const b = Buffer.alloc(8 + 2 + 12 + 4);
  b.write('MM', 0, 'ascii');
  b.writeUInt16BE(0x002a, 2);
  b.writeUInt32BE(8, 4);
  b.writeUInt16BE(1, 8);
  b.writeUInt16BE(0x0112, 10);
  b.writeUInt16BE(3, 12);
  b.writeUInt32BE(1, 14);
  b.writeUInt16BE(orientation, 18);
  const head = Buffer.from('Exif\0\0', 'binary');
  const body = Buffer.concat([head, b]);
  const seg = Buffer.alloc(4);
  seg[0] = 0xff;
  seg[1] = 0xe1;
  seg.writeUInt16BE(body.length + 2, 2);
  return Buffer.concat([seg, body]);
}

function strip(buf) {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== SOI) throw new Error('Not a valid JPEG file');
  const removed = [];
  const kept = [buf.subarray(0, 2)];
  let orientation = 1;
  let pos = 2;
  let sawSos = false;

  while (pos < buf.length) {
    if (buf[pos] !== 0xff) throw new Error('Corrupt JPEG: expected marker at ' + pos);
    while (buf[pos] === 0xff && pos < buf.length) pos++; // fill bytes
    const marker = buf[pos++];
    if (marker === EOI) {
      kept.push(Buffer.from([0xff, EOI]));
      const trailing = buf.length - pos;
      if (trailing > 0) removed.push(`Trailing data after image (${trailing} bytes)`);
      pos = buf.length;
      break;
    }
    if ((marker >= 0xd0 && marker <= 0xd7) || marker === 0x01 || marker === 0x00) {
      kept.push(Buffer.from([0xff, marker]));
      continue;
    }
    if (pos + 2 > buf.length) throw new Error('Corrupt JPEG: truncated segment');
    const len = buf.readUInt16BE(pos);
    const segEnd = pos + len;
    if (segEnd > buf.length) throw new Error('Corrupt JPEG: segment overruns file');
    const data = buf.subarray(pos + 2, segEnd);
    const full = buf.subarray(pos - 2, segEnd);

    if (marker >= 0xe0 && marker <= 0xef) {
      const id = data.toString('latin1', 0, Math.min(data.length, 29));
      let keep = false;
      if (marker === 0xe0 && id.startsWith('JFIF\0')) keep = true;
      else if (marker === 0xee && id.startsWith('Adobe')) keep = true; // colour transform flag
      else if (marker === 0xe2 && id.startsWith('ICC_PROFILE\0')) keep = true;
      if (keep) {
        kept.push(full);
      } else if (marker === 0xe1 && id.startsWith('Exif\0')) {
        const t = readTiff(buf, pos + 2 + 6);
        if (t) orientation = t.orientation;
        removed.push('EXIF');
        if (t && t.gps) removed.push('GPS location');
        if (t && t.camera) removed.push('Camera make/model');
      } else if (marker === 0xe1 && id.startsWith('http://ns.adobe.com/xap/1.0/')) {
        removed.push('XMP');
      } else if (marker === 0xed) {
        removed.push('IPTC / Photoshop data');
      } else if (marker === 0xe2 && id.startsWith('MPF\0')) {
        removed.push('Multi-picture data (MPF)');
      } else {
        removed.push(`Application data (APP${marker - 0xe0})`);
      }
    } else if (marker === 0xfe) {
      removed.push('Comment');
    } else {
      kept.push(full);
    }
    pos = segEnd;

    if (marker === SOS) {
      sawSos = true;
      const start = pos;
      // Entropy-coded data: 0xFF is always stuffed (00) or an RSTn until the next real marker.
      while (pos + 1 < buf.length) {
        if (buf[pos] === 0xff) {
          const n = buf[pos + 1];
          if (n === 0x00 || (n >= 0xd0 && n <= 0xd7) || n === 0xff) {
            pos += n === 0xff ? 1 : 2;
            continue;
          }
          break;
        }
        pos++;
      }
      kept.push(buf.subarray(start, pos));
    }
  }

  if (!sawSos) throw new Error('Corrupt JPEG: no image data');
  if (orientation > 1 && orientation <= 8) {
    // insert after SOI (and after JFIF if present, otherwise right after SOI is fine for decoders)
    kept.splice(1, 0, minimalExif(orientation));
    removed.push('(kept EXIF orientation so the image does not rotate)');
  }
  return { data: Buffer.concat(kept), removed: dedupe(removed) };
}

function dedupe(a) {
  return [...new Set(a)];
}

module.exports = { strip };
