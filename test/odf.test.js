'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const JSZip = require('jszip');
const { strip } = require('../src/strip/odf');

async function makeOdt(entries = {}) {
  const zip = new JSZip();
  zip.file('mimetype', 'application/vnd.oasis.opendocument.text');
  for (const [name, content] of Object.entries(entries)) zip.file(name, content);
  return zip.generateAsync({ type: 'nodebuffer' });
}

test('odf: removes document properties and manifest entry while preserving content', async () => {
  const manifest = '<manifest:manifest><manifest:file-entry manifest:full-path="/"/><manifest:file-entry manifest:full-path="meta.xml"/><manifest:file-entry manifest:full-path="content.xml"/></manifest:manifest>';
  const content = '<office:document-content><secret>unchanged body</secret></office:document-content>';
  const input = await makeOdt({
    'META-INF/manifest.xml': manifest,
    'meta.xml': '<office:document-meta><secret>Jane Doe</secret></office:document-meta>',
    'content.xml': content,
  });

  const { data, removed } = await strip(input);
  const output = await JSZip.loadAsync(data);
  assert.equal(output.file('meta.xml'), null);
  assert.equal(await output.file('content.xml').async('string'), content);
  const outputManifest = await output.file('META-INF/manifest.xml').async('string');
  assert.ok(!outputManifest.includes('full-path="meta.xml"'));
  assert.ok(outputManifest.includes('full-path="content.xml"'));
  assert.deepEqual(removed, ['Document properties']);
});

test('odf: removes thumbnails and matching manifest entries', async () => {
  const input = await makeOdt({
    'META-INF/manifest.xml': '<manifest:manifest><manifest:file-entry manifest:full-path="Thumbnails/thumbnail.png"/><manifest:file-entry manifest:full-path="content.xml"/></manifest:manifest>',
    'Thumbnails/thumbnail.png': Buffer.from([1, 2, 3]),
    'content.xml': '<body/>',
  });

  const { data, removed } = await strip(input);
  const output = await JSZip.loadAsync(data);
  assert.equal(output.file('Thumbnails/thumbnail.png'), null);
  const manifest = await output.file('META-INF/manifest.xml').async('string');
  assert.ok(!manifest.includes('Thumbnails/thumbnail.png'));
  assert.deepEqual(removed, ['Thumbnail']);
});

test('odf: writes mimetype first and stored', async () => {
  const input = await makeOdt({ 'content.xml': '<body/>' });
  const { data } = await strip(input);
  assert.equal(data.readUInt32LE(0), 0x04034b50);
  const nameLength = data.readUInt16LE(26);
  const name = data.subarray(30, 30 + nameLength).toString('utf8');
  assert.equal(name, 'mimetype');
  assert.equal(data.readUInt16LE(8), 0);
});

test('odf: removes printer settings from settings.xml', async () => {
  const settings = '<config:config-item-set><config:config-item config:name="PrinterName" config:type="string">Office Printer</config:config-item><config:config-item config:name="PrinterSetup" config:type="base64Binary">secret</config:config-item><config:config-item config:name="Keep" config:type="string">value</config:config-item></config:config-item-set>';
  const input = await makeOdt({ 'settings.xml': settings });

  const { data, removed } = await strip(input);
  const output = await JSZip.loadAsync(data);
  const outputSettings = await output.file('settings.xml').async('string');
  assert.ok(!outputSettings.includes('PrinterName') && !outputSettings.includes('PrinterSetup'));
  assert.ok(outputSettings.includes('config:name="Keep"'));
  assert.deepEqual(removed, ['Printer settings']);
});

test('odf: rejects non-OpenDocument zip files', async () => {
  const zip = new JSZip();
  zip.file('mimetype', 'application/zip');
  await assert.rejects(strip(await zip.generateAsync({ type: 'nodebuffer' })), /Not a valid OpenDocument file/);
});
