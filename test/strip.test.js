'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');
const JSZip = require('jszip');
const { PDFDocument, PDFName } = require('pdf-lib');
const { stripBuffer, isSupported } = require('../src/strip');

function seg(marker, payload) {
  const h = Buffer.alloc(4);
  h[0] = 0xff;
  h[1] = marker;
  h.writeUInt16BE(payload.length + 2, 2);
  return Buffer.concat([h, payload]);
}

function exifWithGps(orientation) {
  // TIFF big-endian, IFD0 entries: Make(0x010f), Orientation(0x0112), GPSInfo(0x8825)
  const tiff = Buffer.alloc(8 + 2 + 3 * 12 + 4);
  tiff.write('MM', 0, 'ascii');
  tiff.writeUInt16BE(0x2a, 2);
  tiff.writeUInt32BE(8, 4);
  tiff.writeUInt16BE(3, 8);
  const entries = [
    [0x010f, 2, 4, 0],
    [0x0112, 3, 1, orientation << 16],
    [0x8825, 4, 1, 0],
  ];
  entries.forEach(([tag, type, count, val], i) => {
    const o = 10 + i * 12;
    tiff.writeUInt16BE(tag, o);
    tiff.writeUInt16BE(type, o + 2);
    tiff.writeUInt32BE(count, o + 4);
    tiff.writeUInt32BE(val, o + 8);
  });
  return Buffer.concat([Buffer.from('Exif\0\0', 'binary'), tiff]);
}

function makeJpeg({ orientation = 1 } = {}) {
  const scan = Buffer.from([0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56, 0x78]);
  return Buffer.concat([
    Buffer.from([0xff, 0xd8]),
    seg(0xe0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'binary')),
    seg(0xe1, exifWithGps(orientation)),
    seg(0xe1, Buffer.from('http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>', 'binary')),
    seg(0xed, Buffer.from('Photoshop 3.0\0secret', 'binary')),
    seg(0xfe, Buffer.from('my private comment')),
    seg(0xdb, Buffer.alloc(65, 1)),
    seg(0xc0, Buffer.from([8, 0, 1, 0, 1, 1, 1, 0x11, 0])),
    seg(0xda, Buffer.from([1, 1, 0, 0, 0x3f, 0])),
    scan,
    Buffer.from([0xff, 0xd9]),
    Buffer.from('TRAILING-SECRET'),
  ]);
}

test('jpeg: strips EXIF/XMP/IPTC/comment/trailer, keeps JFIF and scan data', async () => {
  const { data, removed } = await stripBuffer(makeJpeg(), 'jpg');
  const s = data.toString('latin1');
  assert.ok(!s.includes('Exif'));
  assert.ok(!s.includes('xmpmeta'));
  assert.ok(!s.includes('Photoshop'));
  assert.ok(!s.includes('private comment'));
  assert.ok(!s.includes('TRAILING-SECRET'));
  assert.ok(s.includes('JFIF'));
  assert.ok(data.includes(Buffer.from([0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56, 0x78])));
  assert.deepEqual([...data.subarray(data.length - 2)], [0xff, 0xd9]);
  for (const label of ['EXIF', 'GPS location', 'Camera make/model', 'XMP', 'IPTC / Photoshop data', 'Comment']) {
    assert.ok(removed.includes(label), `missing label ${label}: ${removed}`);
  }
});

test('jpeg: orientation survives as minimal EXIF without GPS', async () => {
  const { data } = await stripBuffer(makeJpeg({ orientation: 6 }), 'jpeg');
  const i = data.indexOf(Buffer.from('Exif\0\0', 'binary'));
  assert.ok(i > 0, 'orientation block present');
  assert.equal(data.readUInt16BE(i + 6 + 8), 1); // one IFD entry
  assert.equal(data.readUInt16BE(i + 6 + 10), 0x0112);
  assert.equal(data.readUInt16BE(i + 6 + 18), 6);
  // second pass: no GPS, nothing leaks
  const again = await stripBuffer(data, 'jpg');
  assert.ok(!again.removed.includes('GPS location'));
});

test('jpeg: rejects garbage', async () => {
  await assert.rejects(stripBuffer(Buffer.from('nope nope'), 'jpg'), /valid JPEG/);
});

function pngChunk(type, payload) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(payload.length);
  const body = Buffer.concat([Buffer.from(type, 'latin1'), payload]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body));
  return Buffer.concat([len, body, crc]);
}

test('png: drops text/time/exif chunks, keeps image chunks', async () => {
  const ihdr = Buffer.from([0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]);
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('tEXt', Buffer.from('Author\0Someone')),
    pngChunk('eXIf', Buffer.from('MM\0*secret')),
    pngChunk('tIME', Buffer.alloc(7)),
    pngChunk('gAMA', Buffer.alloc(4)),
    pngChunk('IDAT', zlib.deflateSync(Buffer.from([0, 1, 2, 3]))),
    pngChunk('IEND', Buffer.alloc(0)),
    Buffer.from('TRAILING'),
  ]);
  const { data, removed } = await stripBuffer(png, 'png');
  const s = data.toString('latin1');
  assert.ok(!s.includes('Someone') && !s.includes('secret') && !s.includes('TRAILING'));
  assert.ok(s.includes('IDAT') && s.includes('gAMA') && s.endsWith(pngChunk('IEND', Buffer.alloc(0)).toString('latin1')));
  assert.deepEqual(new Set(removed), new Set(['Text comment', 'EXIF', 'Modification time', 'Trailing data after image (8 bytes)']));
});

function riffChunk(id, payload) {
  const h = Buffer.alloc(8);
  h.write(id, 0, 'latin1');
  h.writeUInt32LE(payload.length, 4);
  return Buffer.concat([h, payload, payload.length & 1 ? Buffer.alloc(1) : Buffer.alloc(0)]);
}

test('webp: drops EXIF/XMP, clears VP8X flags, fixes RIFF size', async () => {
  const vp8x = Buffer.alloc(10);
  vp8x[0] = 0x08 | 0x04 | 0x20; // exif + xmp + icc
  const body = Buffer.concat([
    Buffer.from('WEBP'),
    riffChunk('VP8X', vp8x),
    riffChunk('VP8 ', Buffer.from([1, 2, 3])),
    riffChunk('EXIF', Buffer.from('secret-exif')),
    riffChunk('XMP ', Buffer.from('secret-xmp')),
  ]);
  const head = Buffer.alloc(8);
  head.write('RIFF');
  head.writeUInt32LE(body.length, 4);
  const { data, removed } = await stripBuffer(Buffer.concat([head, body]), 'webp');
  assert.ok(!data.includes('secret'));
  assert.equal(data.readUInt32LE(4), data.length - 8);
  assert.equal(data[20], 0x20);
  assert.deepEqual(removed, ['EXIF', 'XMP']);
});

// pdf-lib writes text strings as UTF-16BE hex: <FEFF...>
const hex16 = (t) => Buffer.from(t, 'utf16le').swap16().toString('hex');

test('pdf: removes Info dict, XMP and ID', async () => {
  const doc = await PDFDocument.create();
  doc.addPage();
  doc.setAuthor('Secret Author');
  doc.setTitle('Secret Title');
  doc.setProducer('SecretProducer');
  const xmp = doc.context.stream('<x:xmpmeta>SecretXmp</x:xmpmeta>', { Type: 'Metadata', Subtype: 'XML' });
  doc.catalog.set(PDFName.of('Metadata'), doc.context.register(xmp));
  const input = Buffer.from(await doc.save({ useObjectStreams: false }));
  assert.ok(input.toString('latin1').toUpperCase().includes(hex16('Secret Author').toUpperCase()), 'precondition: author present in input');

  const { data, removed } = await stripBuffer(input, 'pdf');
  const s = data.toString('latin1');
  for (const needle of ['SecretXmp', '/Info', '/Metadata', hex16('Secret Author'), hex16('Secret Title'), hex16('SecretProducer')]) {
    assert.ok(!s.toUpperCase().includes(needle.toUpperCase()), `leaked: ${needle}`);
  }
  assert.ok(removed.some((r) => r.startsWith('Author')));
  assert.ok(removed.includes('XMP'));
  const reopened = await PDFDocument.load(data, { updateMetadata: false });
  assert.equal(reopened.getPageCount(), 1);
  assert.equal(reopened.getAuthor(), undefined);
});

test('pdf: rejects non-pdf', async () => {
  await assert.rejects(stripBuffer(Buffer.from('hello'), 'pdf'), /valid PDF/);
});

test('docx: removes docProps and their references, keeps content', async () => {
  const zip = new JSZip();
  zip.file('[Content_Types].xml', '<Types><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="x"/><Override PartName="/docProps/core.xml" ContentType="y"/><Override PartName="/docProps/app.xml" ContentType="z"/></Types>');
  zip.file('_rels/.rels', '<Relationships><Relationship Id="rId1" Type="t" Target="word/document.xml"/><Relationship Id="rId2" Type="t" Target="docProps/core.xml"/><Relationship Id="rId3" Type="t" Target="docProps/app.xml"/></Relationships>');
  zip.file('word/document.xml', '<w:document>Hello body</w:document>');
  zip.file('docProps/core.xml', '<cp:coreProperties><dc:creator>Jane Doe</dc:creator><cp:lastModifiedBy>John Roe</cp:lastModifiedBy></cp:coreProperties>');
  zip.file('docProps/app.xml', '<Properties><Company>Acme Corp</Company></Properties>');
  const input = await zip.generateAsync({ type: 'nodebuffer' });

  const { data, removed } = await stripBuffer(input, 'docx');
  const out = await JSZip.loadAsync(data);
  assert.deepEqual(Object.keys(out.files).filter((n) => n.startsWith('docProps/')), []);
  assert.equal(await out.file('word/document.xml').async('string'), '<w:document>Hello body</w:document>');
  const rels = await out.file('_rels/.rels').async('string');
  const types = await out.file('[Content_Types].xml').async('string');
  assert.ok(rels.includes('word/document.xml') && !rels.includes('docProps'));
  assert.ok(types.includes('/word/document.xml') && !types.includes('docProps'));
  assert.ok(removed.includes('Author "Jane Doe"'));
  assert.ok(removed.includes('Last modified by "John Roe"'));
  assert.ok(removed.includes('Company "Acme Corp"'));
});

test('isSupported', () => {
  assert.ok(isSupported('C:\\x\\Photo.JPG'));
  assert.ok(isSupported('a.gif') && isSupported('b.ODT') && isSupported('c.ods') && isSupported('d.odp'));
  assert.ok(isSupported('a.docx'));
  assert.ok(!isSupported('a.exe'));
});

test('zipguard: rejects archives whose declared size exceeds the limits', async () => {
  const { loadZipSafe } = require('../src/strip/zipguard');
  const zip = new JSZip();
  zip.file('big.txt', 'x'.repeat(1000));
  const buf = await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' });
  await assert.rejects(loadZipSafe(buf, { maxEntry: 100 }), /too large/);
  await assert.rejects(loadZipSafe(buf, { maxTotal: 100 }), /too large/);
  await assert.doesNotReject(loadZipSafe(buf));
});
