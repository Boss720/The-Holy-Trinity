'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { strip } = require('../src/strip/gif');

function subBlocks(data) {
  const blocks = [];
  for (let offset = 0; offset < data.length; offset += 255) {
    const chunk = data.subarray(offset, offset + 255);
    blocks.push(Buffer.from([chunk.length]), chunk);
  }
  return Buffer.concat([...blocks, Buffer.from([0])]);
}

function image(data = Buffer.from([0x2c, 0x01, 0x02])) {
  return Buffer.concat([
    Buffer.from([0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0]),
    Buffer.from([2]), // LZW minimum code size
    subBlocks(data),
  ]);
}

function extension(label, payload) {
  return Buffer.concat([Buffer.from([0x21, label]), subBlocks(payload)]);
}

function application(identifier, payload) {
  const id = Buffer.from(identifier, 'ascii');
  return Buffer.concat([Buffer.from([0x21, 0xff, id.length]), id, subBlocks(payload)]);
}

function makeGif(blocks, version = '89a') {
  return Buffer.concat([
    Buffer.from(`GIF${version}`, 'ascii'),
    Buffer.from([1, 0, 1, 0, 0, 0, 0]), // 1x1 screen, no global color table
    ...blocks,
    Buffer.from([0x3b]),
  ]);
}

function parseImages(buf) {
  assert.ok(['GIF87a', 'GIF89a'].includes(buf.toString('ascii', 0, 6)));
  let pos = 13;
  const images = [];
  while (pos < buf.length && buf[pos] !== 0x3b) {
    if (buf[pos++] !== 0x2c) throw new Error('Unexpected block in parsed GIF');
    pos += 9;
    if (buf[pos - 1] & 0x80) pos += 3 * (1 << ((buf[pos - 1] & 7) + 1));
    pos++; // LZW minimum code size
    const chunks = [];
    while (buf[pos] !== 0) {
      const size = buf[pos++];
      chunks.push(buf.subarray(pos, pos + size));
      pos += size;
    }
    pos++;
    images.push(Buffer.concat(chunks));
  }
  assert.equal(buf[pos], 0x3b, 'GIF trailer present');
  assert.equal(pos + 1, buf.length, 'no data after GIF trailer');
  return images;
}

test('gif: removes comments and XMP while preserving image data', () => {
  const imageData = Buffer.from([0x2c, 0x01, 0x02, 0x03]);
  const input = makeGif([
    extension(0xfe, Buffer.from('private comment')),
    application('XMP DataXMP', Buffer.from('<x:xmpmeta>private</x:xmpmeta>')),
    image(imageData),
  ]);
  const { data, removed } = strip(input);
  assert.deepEqual(removed, ['Comment', 'XMP']);
  assert.deepEqual(parseImages(data), [imageData]);
  assert.ok(!data.includes(Buffer.from('private')));
});

test('gif: keeps NETSCAPE loop extension', () => {
  const loop = application('NETSCAPE2.0', Buffer.from([1, 0, 0]));
  const { data, removed } = strip(makeGif([loop, image()]));
  assert.ok(data.includes(loop));
  assert.deepEqual(removed, []);
});

test('gif: keeps Graphic Control Extension', () => {
  const control = Buffer.from([0x21, 0xf9, 4, 1, 0, 0, 0, 0]);
  const { data } = strip(makeGif([control, image()]));
  assert.ok(data.includes(control));
});

test('gif: rejects non-GIF input', () => {
  assert.throws(() => strip(Buffer.from('not a GIF')), { message: 'Not a valid GIF file' });
});

test('gif: rejects truncated input', () => {
  const truncated = makeGif([extension(0xfe, Buffer.from('comment'))]).subarray(0, -2);
  assert.throws(() => strip(truncated), /Corrupt GIF/);
});

test('gif: keeps plain text extensions because they render visible text', () => {
  const plainText = extension(0x01, Buffer.from('visible caption', 'ascii'));
  const input = makeGif([plainText, image()]);
  const { data, removed } = strip(input);
  assert.ok(data.includes(plainText));
  assert.deepEqual(removed, []);
});
