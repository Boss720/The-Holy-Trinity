'use strict';

// WebP (RIFF): drop EXIF and XMP chunks, clear their flags in VP8X, fix the RIFF size.

function strip(buf) {
  if (buf.length < 12 || buf.toString('latin1', 0, 4) !== 'RIFF' || buf.toString('latin1', 8, 12) !== 'WEBP') {
    throw new Error('Not a valid WebP file');
  }
  const riffEnd = Math.min(buf.length, 8 + buf.readUInt32LE(4));
  const chunks = [];
  const removed = [];
  let pos = 12;
  while (pos + 8 <= riffEnd) {
    const fourcc = buf.toString('latin1', pos, pos + 4);
    const size = buf.readUInt32LE(pos + 4);
    const padded = size + (size & 1);
    const end = pos + 8 + padded;
    if (pos + 8 + size > riffEnd) throw new Error('Corrupt WebP: chunk overruns file');
    if (fourcc === 'EXIF') removed.push('EXIF');
    else if (fourcc === 'XMP ') removed.push('XMP');
    else {
      let chunk = Buffer.from(buf.subarray(pos, Math.min(end, buf.length)));
      if (chunk.length < 8 + padded) chunk = Buffer.concat([chunk, Buffer.alloc(8 + padded - chunk.length)]);
      if (fourcc === 'VP8X') chunk[8] &= ~(0x08 | 0x04); // EXIF + XMP flags
      chunks.push(chunk);
    }
    pos = end;
  }
  const body = Buffer.concat(chunks);
  const head = Buffer.alloc(12);
  head.write('RIFF', 0, 'latin1');
  head.writeUInt32LE(4 + body.length, 4);
  head.write('WEBP', 8, 'latin1');
  return { data: Buffer.concat([head, body]), removed };
}

module.exports = { strip };
