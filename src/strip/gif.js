'use strict';

// GIF: walk blocks, keeping rendering data and the standard animation controls while dropping metadata extensions.

function strip(buf) {
  const signature = buf.subarray(0, 6);
  if (buf.length < 13 || (!signature.equals(Buffer.from('GIF87a')) && !signature.equals(Buffer.from('GIF89a')))) {
    throw new Error('Not a valid GIF file');
  }

  const kept = [buf.subarray(0, 13)];
  const removed = [];
  const addRemoved = (label) => {
    if (!removed.includes(label)) removed.push(label);
  };
  let pos = 13;

  const requireBytes = (count) => {
    if (pos + count > buf.length) throw new Error('Corrupt GIF: truncated block');
  };
  const skipSubBlocks = () => {
    while (true) {
      requireBytes(1);
      const size = buf[pos++];
      if (size === 0) return pos;
      requireBytes(size);
      pos += size;
    }
  };

  if (buf[10] & 0x80) {
    const size = 3 * (1 << ((buf[10] & 0x07) + 1));
    requireBytes(size);
    kept.push(buf.subarray(pos, pos + size));
    pos += size;
  }

  let sawTrailer = false;
  while (pos < buf.length) {
    const start = pos;
    const marker = buf[pos++];
    if (marker === 0x3b) {
      kept.push(buf.subarray(start, pos));
      sawTrailer = true;
      break;
    }
    if (marker === 0x2c) {
      requireBytes(9);
      const packed = buf[pos + 8];
      pos += 9;
      if (packed & 0x80) {
        const size = 3 * (1 << ((packed & 0x07) + 1));
        requireBytes(size);
        pos += size;
      }
      requireBytes(1);
      pos++; // LZW minimum code size
      skipSubBlocks();
      kept.push(buf.subarray(start, pos));
      continue;
    }
    if (marker !== 0x21) throw new Error('Corrupt GIF: unexpected block');

    requireBytes(1);
    const label = buf[pos++];
    if (label === 0xf9) {
      requireBytes(1);
      const size = buf[pos++];
      requireBytes(size + 1);
      if (size !== 4 || buf[pos + size] !== 0) throw new Error('Corrupt GIF: invalid graphic control extension');
      pos += size + 1;
      kept.push(buf.subarray(start, pos));
      continue;
    }

    let appIdentifier = null;
    if (label === 0xff) {
      requireBytes(1);
      const size = buf[pos++];
      requireBytes(size);
      appIdentifier = buf.toString('latin1', pos, pos + size);
      pos += size;
    }
    skipSubBlocks();
    const end = pos;

    if (label === 0xfe) {
      addRemoved('Comment');
    } else if (label === 0x01) {
      // Plain Text Extension draws visible text on the canvas: rendering data, not metadata.
      kept.push(buf.subarray(start, end));
    } else if (label === 0xff) {
      if (appIdentifier === 'NETSCAPE2.0' || appIdentifier === 'ANIMEXTS1.0') {
        kept.push(buf.subarray(start, end));
      } else if (appIdentifier === 'XMP DataXMP') {
        addRemoved('XMP');
      } else if (appIdentifier === 'ICCRGBG1012') {
        addRemoved('ICC profile');
      } else {
        addRemoved(`Application data (${appIdentifier})`);
      }
    } else {
      addRemoved(`Extension data (0x${label.toString(16).padStart(2, '0')})`);
    }
  }

  if (!sawTrailer) throw new Error('Corrupt GIF: missing trailer');
  return { data: Buffer.concat(kept), removed };
}

module.exports = { strip };
