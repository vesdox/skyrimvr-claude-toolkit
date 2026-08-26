const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  normalizeRelative,
  samePath,
  sameSnapshot,
  beneath,
  validateArtifactRequest,
  readFrame,
  writeFrame,
  proveUnrelatedWriteRefused,
  appendAndVerifyAudit
} = require('./bridge.js');

test('normalizes only safe relative deployment paths', () => {
  assert.equal(normalizeRelative('SKSE/Plugins/Hoarfrost.dll'), 'SKSE\\Plugins\\Hoarfrost.dll');
  for (const value of ['../evil.dll', 'SKSE/../evil.dll', 'C:\\evil.dll', '\\server\\evil.dll', 'Hoarfrost.esp']) {
    assert.throws(() => normalizeRelative(value));
  }
});

test('Windows path comparison is case insensitive and bounded', () => {
  assert.equal(samePath('SKSE\\Plugins\\Hoarfrost.dll', 'skse/plugins/Hoarfrost.dll'), true);
  assert.equal(beneath('D:\\mods\\Hoarfrost', 'D:\\mods\\Hoarfrost\\SKSE\\x.dll'), true);
  assert.equal(beneath('D:\\mods\\Hoarfrost', 'D:\\mods\\Other\\x.dll'), false);
});

test('snapshot comparison detects additions, removals, and hash changes', () => {
  assert.equal(sameSnapshot({ b: '2', a: '1' }, { a: '1', b: '2' }), true);
  assert.equal(sameSnapshot({ a: '1' }, { a: '1', b: '2' }), false);
  assert.equal(sameSnapshot({ a: '1', b: '2' }, { a: '1' }), false);
  assert.equal(sameSnapshot({ a: '1' }, { a: '2' }), false);
});

test('forced-command frames round-trip structured JSON', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'project-deploy-frame-'));
  const filename = path.join(directory, 'frame.bin');
  const output = fs.openSync(filename, 'w');
  writeFrame(output, { protocol: 'project-deploy-v1', operation: 'health' });
  fs.closeSync(output);
  const input = fs.openSync(filename, 'r');
  assert.deepEqual(readFrame(input), {
    protocol: 'project-deploy-v1',
    operation: 'health'
  });
  assert.equal(readFrame(input), null);
  fs.closeSync(input);
  fs.rmSync(directory, { recursive: true, force: true });
});

test('forced-command frames reject truncation, invalid JSON, and invalid lengths', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'project-deploy-invalid-frame-'));
  const cases = [
    Buffer.from([0, 0, 0, 1, 0x7b]),
    Buffer.from([0, 0, 0, 5, 0x7b, 0x7d]),
    Buffer.from([0, 0, 0, 4, 0x6e, 0x6f, 0x70, 0x65]),
    Buffer.from([0xff, 0xff, 0xff, 0xff])
  ];
  for (const [index, content] of cases.entries()) {
    const filename = path.join(directory, `invalid-${index}.bin`);
    fs.writeFileSync(filename, content);
    const input = fs.openSync(filename, 'r');
    assert.throws(() => readFrame(input));
    fs.closeSync(input);
  }
  fs.rmSync(directory, { recursive: true, force: true });
});

test('audit append is durably read back as the exact record', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'project-deploy-audit-'));
  const filename = path.join(directory, 'project-deploy.ndjson');
  const record = JSON.stringify({ request_id: 'current-request', operation: 'smoke' });
  appendAndVerifyAudit(filename, record);
  assert.equal(fs.readFileSync(filename, 'utf8'), `${record}\r\n`);
  fs.rmSync(directory, { recursive: true, force: true });
});

test('unrelated write proof cannot turn successful creation into refusal', async () => {
  const originalWriteFile = fs.promises.writeFile;
  const originalLstat = fs.promises.lstat;
  const originalRm = fs.promises.rm;
  try {
    fs.promises.writeFile = async () => { const error = new Error('denied'); error.code = 'EACCES'; throw error; };
    fs.promises.lstat = async () => { const error = new Error('absent'); error.code = 'ENOENT'; throw error; };
    assert.equal(await proveUnrelatedWriteRefused('D:\\mods\\Other\\probe.tmp'), true);

    fs.promises.writeFile = async () => {};
    fs.promises.rm = async () => {};
    await assert.rejects(
      proveUnrelatedWriteRefused('D:\\mods\\Other\\probe.tmp'),
      /unrelated mod write unexpectedly succeeded: D:\\mods\\Other\\probe\.tmp/
    );

    fs.promises.rm = async () => { const error = new Error('cleanup denied'); error.code = 'EACCES'; throw error; };
    await assert.rejects(
      proveUnrelatedWriteRefused('D:\\mods\\Other\\residue.tmp'),
      /residue could not be removed: D:\\mods\\Other\\residue\.tmp: cleanup denied/
    );

    fs.promises.writeFile = async () => { const error = new Error('denied after create'); error.code = 'EACCES'; throw error; };
    fs.promises.lstat = async () => ({ isFile: () => true });
    await assert.rejects(
      proveUnrelatedWriteRefused('D:\\mods\\Other\\partial-residue.tmp'),
      /residue could not be removed: D:\\mods\\Other\\partial-residue\.tmp: cleanup denied/
    );
  } finally {
    fs.promises.writeFile = originalWriteFile;
    fs.promises.lstat = originalLstat;
    fs.promises.rm = originalRm;
  }
});

test('artifact requests must match the exact allowlist destination', () => {
  const target = { artifacts: { dll: {
    destination: 'SKSE\\Plugins\\Hoarfrost.dll',
    sha256: 'a'.repeat(64)
  } } };
  const valid = validateArtifactRequest(target, {
    artifacts: [{
      id: 'dll',
      destination: 'SKSE/Plugins/Hoarfrost.dll',
      sha256: 'a'.repeat(64),
      size: 42
    }]
  });
  assert.equal(valid[0].id, 'dll');
  assert.throws(() => validateArtifactRequest(target, {
    artifacts: [{
      id: 'other',
      destination: 'SKSE/Plugins/Other.dll',
      sha256: 'a'.repeat(64),
      size: 42
    }]
  }));
  assert.throws(() => validateArtifactRequest(target, {
    artifacts: [{
      id: 'dll',
      destination: 'SKSE/Plugins/Hoarfrost.dll',
      sha256: 'b'.repeat(64),
      size: 42
    }]
  }));
});
