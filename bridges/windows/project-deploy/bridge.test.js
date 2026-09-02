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
  appendAndVerifyAudit,
  inspectDestination,
  validateDestination,
  assertLayoutUnchanged,
  createPlannedDirectories,
  removeCreatedDirectories,
  dispatch
} = require('./bridge.js');

function fakeWindowsDirectories(initial) {
  const nodes = new Map();
  let nextIno = 100;
  const key = value => value.toLowerCase();
  const add = (filename, type = 'directory', real = filename) => {
    nodes.set(key(filename), { filename, type, real, ino: nextIno++ });
  };
  for (const filename of initial) add(filename);
  const calls = { mkdir: [], rmdir: [] };
  return {
    nodes,
    calls,
    add,
    replace(filename, type = 'directory', real = filename) {
      nodes.delete(key(filename));
      add(filename, type, real);
    },
    async lstat(filename) {
      const node = nodes.get(key(filename));
      if (!node) { const error = new Error('absent'); error.code = 'ENOENT'; throw error; }
      return {
        dev: 7,
        ino: node.ino,
        isSymbolicLink: () => node.type === 'link',
        isDirectory: () => node.type === 'directory',
        isFile: () => node.type === 'file'
      };
    },
    async realpath(filename) {
      const node = nodes.get(key(filename));
      if (!node) { const error = new Error('absent'); error.code = 'ENOENT'; throw error; }
      return node.real;
    },
    async mkdir(filename) {
      calls.mkdir.push(filename);
      if (nodes.has(key(filename))) { const error = new Error('exists'); error.code = 'EEXIST'; throw error; }
      const parent = path.win32.dirname(filename);
      const parentNode = nodes.get(key(parent));
      if (!parentNode || parentNode.type !== 'directory') {
        const error = new Error('parent absent'); error.code = 'ENOENT'; throw error;
      }
      add(filename);
    },
    async rmdir(filename) {
      calls.rmdir.push(filename);
      const prefix = `${key(filename)}\\`;
      if ([...nodes.keys()].some(candidate => candidate.startsWith(prefix))) {
        const error = new Error('not empty'); error.code = 'ENOTEMPTY'; throw error;
      }
      if (!nodes.delete(key(filename))) { const error = new Error('absent'); error.code = 'ENOENT'; throw error; }
    }
  };
}

async function withFakeWindowsFs(fake, callback) {
  const originals = {
    lstat: fs.promises.lstat,
    realpath: fs.promises.realpath,
    mkdir: fs.promises.mkdir,
    rmdir: fs.promises.rmdir
  };
  Object.assign(fs.promises, {
    lstat: fake.lstat.bind(fake),
    realpath: fake.realpath.bind(fake),
    mkdir: fake.mkdir.bind(fake),
    rmdir: fake.rmdir.bind(fake)
  });
  try {
    return await callback();
  } finally {
    Object.assign(fs.promises, originals);
  }
}

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

test('registered missing parents are planned read-only and created one component at a time', async () => {
  const root = 'D:\\mods\\Proof';
  const plugin = `${root}\\SKSE\\Plugins`;
  const hoarfrost = `${plugin}\\Hoarfrost`;
  const runtimeTests = `${hoarfrost}\\RuntimeTests`;
  const fake = fakeWindowsDirectories([root, `${root}\\SKSE`, plugin]);
  await withFakeWindowsFs(fake, async () => {
    const first = await inspectDestination(
      root, 'SKSE\\Plugins\\Hoarfrost\\RuntimeTests\\runtime-proof-mode.txt'
    );
    const second = await inspectDestination(
      root, 'SKSE\\Plugins\\Hoarfrost\\RuntimeTests\\schema-v4-persistence-proof.json'
    );
    assert.deepEqual(first.missing, [hoarfrost, runtimeTests]);
    assert.deepEqual(second.missing, [hoarfrost, runtimeTests]);
    assert.deepEqual(fake.calls.mkdir, []);

    const created = [];
    await createPlannedDirectories(root, [first, second], created);
    assert.deepEqual(fake.calls.mkdir, [hoarfrost, runtimeTests]);
    assert.deepEqual(created.map(entry => entry.path), [hoarfrost, runtimeTests]);
    assert.equal((await validateDestination(root, first.destination.slice(root.length + 1))), first.destination);
    assert.equal((await validateDestination(root, second.destination.slice(root.length + 1))), second.destination);
  });
});

test('existing parent deployment layout remains unchanged and creates no directories', async () => {
  const root = 'D:\\mods\\Development';
  const plugin = `${root}\\SKSE\\Plugins`;
  const fake = fakeWindowsDirectories([root, `${root}\\SKSE`, plugin]);
  await withFakeWindowsFs(fake, async () => {
    const layout = await inspectDestination(root, 'SKSE\\Plugins\\Hoarfrost.dll');
    assert.deepEqual(layout.missing, []);
    const created = [];
    await createPlannedDirectories(root, [layout], created);
    assert.deepEqual(created, []);
    assert.deepEqual(fake.calls.mkdir, []);
  });
});

test('directory rollback removes only transaction-created directories in reverse order', async () => {
  const root = 'D:\\mods\\Proof';
  const plugin = `${root}\\SKSE\\Plugins`;
  const fake = fakeWindowsDirectories([root, `${root}\\SKSE`, plugin]);
  await withFakeWindowsFs(fake, async () => {
    const layout = await inspectDestination(
      root, 'SKSE\\Plugins\\Hoarfrost\\RuntimeTests\\proof.txt'
    );
    const created = [];
    await createPlannedDirectories(root, [layout], created);
    assert.deepEqual(await removeCreatedDirectories(root, created), []);
    assert.deepEqual(fake.calls.rmdir, [
      `${plugin}\\Hoarfrost\\RuntimeTests`, `${plugin}\\Hoarfrost`
    ]);
    assert.equal(fake.nodes.has(plugin.toLowerCase()), true);
    assert.equal(fake.nodes.has(root.toLowerCase()), true);
  });
});

test('rollback refuses to remove a changed or unexpectedly nonempty created directory', async () => {
  const root = 'D:\\mods\\Proof';
  const parent = `${root}\\NewParent`;
  const fake = fakeWindowsDirectories([root]);
  await withFakeWindowsFs(fake, async () => {
    const layout = await inspectDestination(root, 'NewParent\\proof.txt');
    const created = [];
    await createPlannedDirectories(root, [layout], created);
    fake.add(`${parent}\\unexpected.txt`, 'file');
    const errors = await removeCreatedDirectories(root, created);
    assert.match(errors[0], /not empty/);
    assert.equal(fake.nodes.has(parent.toLowerCase()), true);
  });
});

test('unsafe, conflicting, and changed destination ancestry is refused', async () => {
  const root = 'D:\\mods\\Proof';
  const plugin = `${root}\\SKSE\\Plugins`;
  const fake = fakeWindowsDirectories([root, `${root}\\SKSE`, plugin]);
  await withFakeWindowsFs(fake, async () => {
    const planned = await inspectDestination(root, 'SKSE\\Plugins\\RuntimeTests\\proof.txt');
    fake.replace(plugin);
    const current = await inspectDestination(root, 'SKSE\\Plugins\\RuntimeTests\\proof.txt');
    assert.throws(() => assertLayoutUnchanged(planned, current), /ancestry changed after plan/);

    fake.replace(plugin, 'link', 'D:\\mods\\Other');
    await assert.rejects(
      inspectDestination(root, 'SKSE\\Plugins\\RuntimeTests\\proof.txt'),
      /not a safe directory/
    );

    fake.replace(plugin, 'file');
    await assert.rejects(
      inspectDestination(root, 'SKSE\\Plugins\\RuntimeTests\\proof.txt'),
      /not a safe directory/
    );

    fake.replace(plugin, 'directory', 'D:\\mods\\Other');
    await assert.rejects(
      inspectDestination(root, 'SKSE\\Plugins\\RuntimeTests\\proof.txt'),
      /escapes registered target/
    );
  });
});

test('unsafe existing destination is refused before deployment', async () => {
  const root = 'D:\\mods\\Proof';
  const plugin = `${root}\\SKSE\\Plugins`;
  const destination = `${plugin}\\Hoarfrost.dll`;
  const fake = fakeWindowsDirectories([root, `${root}\\SKSE`, plugin]);
  fake.add(destination, 'link', 'D:\\mods\\Other\\Hoarfrost.dll');
  await withFakeWindowsFs(fake, async () => {
    await assert.rejects(
      validateDestination(root, 'SKSE\\Plugins\\Hoarfrost.dll'),
      /existing destination is not a regular file/
    );
  });
});

test('no forced-command caller can request directory creation independently', async () => {
  await assert.rejects(
    dispatch({ protocol: 'project-deploy-v1', operation: 'mkdir', directories: ['D:\\mods\\Proof\\x'] }),
    /unsupported forced-command operation/
  );
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
