const test = require('node:test');
const assert = require('node:assert/strict');
const {
  normalizeRelative,
  samePath,
  beneath,
  validateArtifactRequest
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
