'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const CONFIG_PATH =
  'C:\\ProgramData\\SkyrimToolBridge\\project-deploy\\config.json';
const WORKER_PATH =
  'C:\\ProgramData\\SkyrimToolBridge\\project-deploy\\bridge\\bridge.js';
const WRAPPER_PATH =
  'C:\\ProgramData\\SkyrimToolBridge\\project-deploy\\invoke-ssh.ps1';
const AUTHORIZED_KEYS_PATH =
  'C:\\ProgramData\\SkyrimToolBridge\\openssh\\authorized_keys';
const EXPECTED_SID = 'S-1-5-21-3046562540-2879210194-691397096-1014';
const MAX_REQUEST_BYTES = 180 * 1024 * 1024;
const MAX_CONTENT_BYTES = 128 * 1024 * 1024;
const PLAN_TTL_MS = 5 * 60 * 1000;
const APPLY_LOCK_STALE_MS = 15 * 60 * 1000;
const plans = new Map();
const PROTOCOL_MAGIC = Buffer.from('HFDEPLOY1\0', 'ascii');

function loadConfig() {
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  if (config.schema !== 1 || typeof config.environment !== 'string' ||
      typeof config.backup_root !== 'string' || typeof config.targets !== 'object' ||
      Object.keys(config.targets).length < 1 || Object.keys(config.targets).length > 64) {
    throw new Error('deployment worker config has an unsupported or unbounded schema');
  }
  return config;
}

function sha256File(filename) {
  return new Promise((resolve, reject) => {
    const digest = crypto.createHash('sha256');
    const stream = fs.createReadStream(filename);
    stream.on('data', chunk => digest.update(chunk));
    stream.on('end', () => resolve(digest.digest('hex')));
    stream.on('error', reject);
  });
}

function sha256Buffer(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function normalizeRelative(value) {
  if (typeof value !== 'string' || !value || /[\r\n:]/.test(value)) {
    throw new Error('destination must be a safe registered relative path');
  }
  const normalized = value.replaceAll('/', '\\');
  if (path.win32.isAbsolute(normalized)) {
    throw new Error('destination must be relative');
  }
  const parts = normalized.split('\\');
  if (parts.some(part => !part || part === '.' || part === '..')) {
    throw new Error('destination contains an unsafe path component');
  }
  if (/\.(esp|esm|esl|bsa|ba2)$/i.test(parts.at(-1))) {
    throw new Error('direct binary mod-file deployment is not allowed');
  }
  return parts.join('\\');
}

function samePath(a, b) {
  return path.win32.resolve(a).toLowerCase() === path.win32.resolve(b).toLowerCase();
}

function beneath(root, candidate) {
  const rel = path.win32.relative(path.win32.resolve(root), path.win32.resolve(candidate));
  return rel !== '..' && !rel.startsWith('..\\') && !path.win32.isAbsolute(rel);
}

function resolveTarget(config, input) {
  if (!input || input.environment !== config.environment) {
    throw new Error('environment is not served by this deployment worker');
  }
  const key = `${input.project}:${input.target}`;
  const target = config.targets[key];
  if (!target || target.project !== input.project || target.target !== input.target ||
      target.environment !== input.environment) {
    throw new Error('project/environment/target combination is not registered');
  }
  return target;
}

async function validateDestination(root, relative) {
  const destination = path.win32.resolve(root, relative);
  if (!beneath(root, destination) || samePath(root, destination)) {
    throw new Error(`destination escapes registered target: ${relative}`);
  }
  const rootReal = await fs.promises.realpath(root);
  const parentReal = await fs.promises.realpath(path.win32.dirname(destination));
  if (!beneath(rootReal, parentReal)) {
    throw new Error(`destination parent escapes registered target: ${relative}`);
  }
  try {
    const stat = await fs.promises.lstat(destination);
    if (stat.isSymbolicLink() || !stat.isFile()) {
      throw new Error(`existing destination is not a regular file: ${destination}`);
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return destination;
}

function validateArtifactRequest(target, input) {
  if (!Array.isArray(input.artifacts) || input.artifacts.length < 1 || input.artifacts.length > 64) {
    throw new Error('artifacts must contain 1 through 64 registered files');
  }
  const seenIds = new Set();
  const seenDestinations = new Set();
  return input.artifacts.map(item => {
    if (!item || typeof item.id !== 'string' || seenIds.has(item.id)) {
      throw new Error('artifact ids must be unique strings');
    }
    seenIds.add(item.id);
    const allowed = target.artifacts[item.id];
    if (!allowed || typeof allowed.destination !== 'string' ||
        typeof allowed.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(allowed.sha256)) {
      throw new Error(`artifact is not registered with a pinned hash for this target: ${item.id}`);
    }
    const destination = normalizeRelative(item.destination);
    if (!samePath(allowed.destination, destination)) {
      throw new Error(`destination does not match registry for artifact ${item.id}`);
    }
    const destinationKey = destination.toLowerCase();
    if (seenDestinations.has(destinationKey)) {
      throw new Error(`duplicate destination: ${destination}`);
    }
    seenDestinations.add(destinationKey);
    if (typeof item.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(item.sha256) ||
        item.sha256 !== allowed.sha256) {
      throw new Error(`source SHA256 does not match protected registry for artifact ${item.id}`);
    }
    if (!Number.isSafeInteger(item.size) || item.size < 0 || item.size > MAX_CONTENT_BYTES) {
      throw new Error(`invalid size for artifact ${item.id}`);
    }
    return { id: item.id, relative: destination, sha256: item.sha256, size: item.size };
  });
}

async function currentHash(destination) {
  try {
    await fs.promises.access(destination, fs.constants.F_OK);
    return await sha256File(destination);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function cleanPlans() {
  for (const [token, plan] of plans) {
    if (plan.expires < Date.now()) plans.delete(token);
  }
}

async function planDeployment(input) {
  const config = loadConfig();
  const target = resolveTarget(config, input);
  const artifacts = validateArtifactRequest(target, input);
  const total = artifacts.reduce((sum, item) => sum + item.size, 0);
  if (total > MAX_CONTENT_BYTES) throw new Error('deployment content exceeds 128 MiB');

  for (const item of artifacts) {
    item.destination = await validateDestination(target.root, item.relative);
    item.existing_sha256 = await currentHash(item.destination);
  }
  cleanPlans();
  if (plans.size >= 100) throw new Error('too many active deployment plans');
  const token = crypto.randomUUID();
  plans.set(token, { expires: Date.now() + PLAN_TTL_MS, config, target, artifacts });
  return {
    ok: true,
    operation: 'plan',
    token,
    expires_seconds: PLAN_TTL_MS / 1000,
    artifacts: artifacts.map(item => ({
      id: item.id,
      destination: item.destination,
      existing_sha256: item.existing_sha256,
      source_sha256: item.sha256,
      size: item.size
    }))
  };
}

async function applyDeploymentUnlocked(input, requestId) {
  if (typeof input.token !== 'string') throw new Error('plan token is required');
  const plan = plans.get(input.token);
  plans.delete(input.token);
  if (!plan || plan.expires < Date.now()) throw new Error('plan token is unknown or expired');
  const currentConfig = loadConfig();
  const currentTarget = currentConfig.targets[`${plan.target.project}:${plan.target.target}`];
  if (!currentTarget || currentConfig.environment !== plan.target.environment ||
      !samePath(currentTarget.root, plan.target.root) ||
      !samePath(currentConfig.backup_root, plan.config.backup_root)) {
    throw new Error('protected deployment target changed after plan');
  }
  for (const item of plan.artifacts) {
    const allowed = currentTarget.artifacts[item.id];
    if (!allowed || !samePath(allowed.destination, item.relative) || allowed.sha256 !== item.sha256) {
      throw new Error(`protected artifact registration changed after plan: ${item.id}`);
    }
  }
  if (!Array.isArray(input.artifacts) || input.artifacts.length !== plan.artifacts.length) {
    throw new Error('apply artifacts do not match plan');
  }

  const payloads = new Map();
  let total = 0;
  for (const item of input.artifacts) {
    if (!item || typeof item.id !== 'string' || payloads.has(item.id) ||
        typeof item.sha256 !== 'string' || typeof item.content_base64 !== 'string') {
      throw new Error('invalid or duplicate apply artifact');
    }
    const planned = plan.artifacts.find(candidate => candidate.id === item.id);
    if (!planned || item.sha256 !== planned.sha256) {
      throw new Error(`apply artifact does not match plan: ${item.id}`);
    }
    const content = Buffer.from(item.content_base64, 'base64');
    total += content.length;
    if (content.length !== planned.size || sha256Buffer(content) !== planned.sha256) {
      throw new Error(`content hash/size mismatch: ${item.id}`);
    }
    payloads.set(item.id, content);
  }
  if (payloads.size !== plan.artifacts.length || total > MAX_CONTENT_BYTES) {
    throw new Error('apply content does not exactly match plan');
  }

  for (const item of plan.artifacts) {
    const destination = await validateDestination(currentTarget.root, item.relative);
    if (!samePath(destination, item.destination)) {
      throw new Error(`destination identity changed after plan: ${item.destination}`);
    }
    item.destination = destination;
    if (await currentHash(destination) !== item.existing_sha256) {
      throw new Error(`destination changed after plan; refusing: ${destination}`);
    }
  }

  audit(currentConfig, requestId, 'apply', {
    ok: true,
    operation: 'apply',
    event: 'apply-start',
    artifacts: plan.artifacts.map(item => ({
      id: item.id,
      destination: item.destination,
      previous_sha256: item.existing_sha256,
      source_sha256: item.sha256,
      resulting_sha256: null,
      backup: null,
      size: item.size
    }))
  });

  const backupDir = path.win32.join(
    currentConfig.backup_root,
    new Date().toISOString().replaceAll(':', '-'),
    crypto.randomUUID()
  );
  const changed = [];
  try {
    for (const item of plan.artifacts) {
      const entry = {
        item,
        backup: null,
        backupCreated: false,
        resulting: null,
        temp: null,
        replaced: false
      };
      changed.push(entry);
      if (item.existing_sha256 !== null) {
        entry.backup = path.win32.join(backupDir, item.relative);
        await fs.promises.mkdir(path.win32.dirname(entry.backup), { recursive: true });
        await fs.promises.copyFile(item.destination, entry.backup, fs.constants.COPYFILE_EXCL);
        entry.backupCreated = true;
        if (await sha256File(entry.backup) !== item.existing_sha256) {
          throw new Error(`backup hash mismatch: ${item.destination}`);
        }
      }
      entry.temp = `${item.destination}.skyrim-agent-${crypto.randomUUID()}.tmp`;
      await fs.promises.writeFile(entry.temp, payloads.get(item.id), { flag: 'wx' });
      if (await sha256File(entry.temp) !== item.sha256) {
        throw new Error(`staged hash mismatch: ${item.id}`);
      }
      await fs.promises.rename(entry.temp, item.destination);
      entry.replaced = true;
      entry.temp = null;
      entry.resulting = await sha256File(item.destination);
      if (entry.resulting !== item.sha256) throw new Error(`resulting hash mismatch: ${item.id}`);
    }
    const result = {
      ok: true,
      operation: 'apply',
      event: 'commit',
      artifacts: changed.map(entry => ({
        id: entry.item.id,
        destination: entry.item.destination,
        previous_sha256: entry.item.existing_sha256,
        source_sha256: entry.item.sha256,
        resulting_sha256: entry.resulting,
        backup: entry.backup,
        size: entry.item.size
      }))
    };
    // A commit is not accepted unless its durable audit record is written. An audit
    // failure is handled by this transaction's rollback path.
    audit(currentConfig, requestId, 'apply', result);
    return result;
  } catch (error) {
    const rollbackErrors = [];
    const rollbackAttempted = changed.some(entry => entry.replaced === true);
    for (const entry of changed.reverse()) {
      try {
        if (entry.temp) await fs.promises.rm(entry.temp, { force: true });
        if (entry.replaced) {
          if (entry.backupCreated) {
            await fs.promises.copyFile(entry.backup, entry.item.destination);
            if (await sha256File(entry.item.destination) !== entry.item.existing_sha256) {
              throw new Error(`rollback hash mismatch: ${entry.item.destination}`);
            }
          } else {
            await fs.promises.rm(entry.item.destination, { force: true });
          }
        }
      } catch (rollbackError) {
        rollbackErrors.push(String(rollbackError?.message ?? rollbackError));
      }
    }
    if (rollbackErrors.length === 0) {
      await fs.promises.rm(backupDir, { recursive: true, force: true });
    }
    error.rollback = {
      attempted: rollbackAttempted,
      ok: rollbackErrors.length === 0,
      errors: rollbackErrors
    };
    error.artifacts = changed.map(entry => ({
      id: entry.item.id,
      destination: entry.item.destination,
      previous_sha256: entry.item.existing_sha256,
      source_sha256: entry.item.sha256,
      resulting_sha256: entry.resulting,
      backup: entry.backupCreated ? entry.backup : null,
      size: entry.item.size
    }));
    if (rollbackErrors.length) {
      error.message = `${String(error?.message ?? error)}; rollback errors: ${rollbackErrors.join('; ')}`;
    }
    audit(currentConfig, requestId, 'apply', {
      ok: rollbackErrors.length === 0,
      operation: 'apply',
      event: 'rollback',
      error: String(error?.message ?? error),
      rollback: error.rollback,
      artifacts: error.artifacts
    });
    throw error;
  }
}

function processIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

async function createApplyLock(lockPath, body) {
  const lock = await fs.promises.open(lockPath, 'wx');
  try {
    await lock.writeFile(body, 'utf8');
    return lock;
  } catch (error) {
    await lock.close().catch(() => {});
    await fs.promises.rm(lockPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function acquireApplyLock(lockPath) {
  const body = JSON.stringify({
    timestamp: new Date().toISOString(),
    pid: process.pid,
    ssh_connection: process.env.SSH_CONNECTION || null
  });
  try {
    return await createApplyLock(lockPath, body);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }

  let stale;
  try {
    const stat = await fs.promises.stat(lockPath);
    const parsed = JSON.parse(await fs.promises.readFile(lockPath, 'utf8'));
    stale = Date.now() - stat.mtimeMs > APPLY_LOCK_STALE_MS && !processIsAlive(parsed.pid);
  } catch (error) {
    throw new Error(`deployment apply lock cannot be validated for recovery: ${error.message}`);
  }
  if (!stale) throw new Error('another deployment apply is active or requires later lock recovery');

  const quarantine = `${lockPath}.stale-${crypto.randomUUID()}`;
  try {
    await fs.promises.rename(lockPath, quarantine);
    await fs.promises.rm(quarantine, { force: true });
  } catch (error) {
    throw new Error(`stale deployment apply lock recovery lost a race: ${error.message}`);
  }
  return createApplyLock(lockPath, body);
}

async function applyDeployment(input, requestId) {
  const config = loadConfig();
  const lockPath = path.win32.join(config.backup_root, 'project-deploy.apply.lock');
  let lock;
  try {
    lock = await acquireApplyLock(lockPath);
  } catch (error) {
    const failure = error;
    try {
      audit(config, requestId, 'apply', {
        ok: false,
        operation: 'apply',
        event: 'failure',
        error: String(failure?.message ?? failure),
        rollback: null,
        artifacts: null
      });
    } catch (auditError) {
      throw new Error(
        `${String(failure?.message ?? failure)}; required failure audit write failed: ` +
        String(auditError?.message ?? auditError)
      );
    }
    throw failure;
  }
  try {
    return await applyDeploymentUnlocked(input, requestId);
  } catch (error) {
    try {
      audit(config, requestId, 'apply', {
        ok: false,
        operation: 'apply',
        event: 'failure',
        error: String(error?.message ?? error),
        rollback: error.rollback ?? null,
        artifacts: error.artifacts ?? null
      });
    } catch (auditError) {
      throw new Error(
        `${String(error?.message ?? error)}; required failure audit write failed: ` +
        String(auditError?.message ?? auditError)
      );
    }
    throw error;
  } finally {
    try {
      await lock.close();
    } finally {
      await fs.promises.rm(lockPath, { force: true });
    }
  }
}

async function expectWriteRefused(filename) {
  let handle;
  try {
    handle = await fs.promises.open(filename, 'r+');
    throw new Error(`write-open unexpectedly succeeded: ${filename}`);
  } catch (error) {
    if (error.message?.startsWith('write-open unexpectedly succeeded:')) throw error;
    if (!['EACCES', 'EPERM'].includes(error.code)) throw error;
    return true;
  } finally {
    if (handle) await handle.close();
  }
}

async function snapshotRegisteredDestinations(target) {
  const result = {};
  for (const [id, artifact] of Object.entries(target.artifacts)) {
    const relative = normalizeRelative(artifact.destination);
    const destination = await validateDestination(target.root, relative);
    result[id] = await currentHash(destination);
  }
  return result;
}

async function snapshotRegisteredBackups(config, target) {
  const suffixes = Object.values(target.artifacts).map(artifact =>
    normalizeRelative(artifact.destination).toLowerCase()
  );
  const result = {};
  let visited = 0;
  async function walk(directory, depth) {
    if (depth > 16) throw new Error('backup snapshot exceeded maximum depth');
    let entries;
    try {
      entries = await fs.promises.readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error.code === 'ENOENT') return;
      throw error;
    }
    for (const entry of entries) {
      visited += 1;
      if (visited > 10000) throw new Error('backup snapshot exceeded maximum entries');
      const filename = path.win32.join(directory, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`backup snapshot encountered a symbolic link: ${filename}`);
      if (entry.isDirectory()) {
        await walk(filename, depth + 1);
      } else if (entry.isFile() && suffixes.some(suffix => filename.toLowerCase().endsWith(suffix))) {
        result[filename.toLowerCase()] = await sha256File(filename);
      }
    }
  }
  await walk(config.backup_root, 0);
  return result;
}

function sameSnapshot(before, after) {
  return JSON.stringify(before, Object.keys(before).sort()) ===
    JSON.stringify(after, Object.keys(after).sort());
}

async function smoke(config) {
  const keys = Object.keys(config.targets);
  if (keys.length !== 1) throw new Error('smoke requires one exact protected target');
  const target = config.targets[keys[0]];
  const modsRoot = path.win32.dirname(target.root);
  const pluginRoot = path.win32.join(target.root, 'SKSE', 'Plugins');
  const destinationSnapshot = await snapshotRegisteredDestinations(target);
  const backupSnapshot = await snapshotRegisteredBackups(config, target);
  const token = crypto.randomUUID().replaceAll('-', '').slice(0, 8);
  const probe = path.win32.join(pluginRoot, `.hf-${token}.tmp`);
  const oldContent = Buffer.from(`old-${token}`, 'utf8');
  const newContent = Buffer.from(`new-${token}`, 'utf8');
  const smokeBackup = path.win32.join(config.backup_root, 'smoke', token, 'probe.bak');
  let targetRemoved = false;
  try {
    await fs.promises.writeFile(probe, oldContent, { flag: 'wx' });
    const oldHash = await sha256File(probe);
    await fs.promises.mkdir(path.win32.dirname(smokeBackup), { recursive: true });
    await fs.promises.copyFile(probe, smokeBackup, fs.constants.COPYFILE_EXCL);
    if (await sha256File(smokeBackup) !== oldHash) throw new Error('smoke backup hash mismatch');
    const temp = `${probe}.replace`;
    await fs.promises.writeFile(temp, newContent, { flag: 'wx' });
    await fs.promises.rename(temp, probe);
    if (await sha256File(probe) !== sha256Buffer(newContent)) throw new Error('smoke replacement mismatch');
    await fs.promises.copyFile(smokeBackup, probe);
    if (await sha256File(probe) !== oldHash) throw new Error('smoke rollback mismatch');
    await fs.promises.rm(probe);
    targetRemoved = true;
  } finally {
    await fs.promises.rm(`${probe}.replace`, { force: true });
    await fs.promises.rm(probe, { force: true });
    await fs.promises.rm(path.win32.dirname(smokeBackup), { recursive: true, force: true });
  }

  let unrelatedCount = 0;
  for (const entry of await fs.promises.readdir(modsRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.toLowerCase() === path.win32.basename(target.root).toLowerCase()) continue;
    unrelatedCount += 1;
    const unrelatedProbe = path.win32.join(modsRoot, entry.name, `.hf-${token}.tmp`);
    try {
      await fs.promises.writeFile(unrelatedProbe, 'refuse', { flag: 'wx' });
      await fs.promises.rm(unrelatedProbe, { force: true });
      throw new Error(`unrelated mod write unexpectedly succeeded: ${entry.name}`);
    } catch (error) {
      if (error.message?.startsWith('unrelated mod write unexpectedly succeeded:')) throw error;
      if (!['EACCES', 'EPERM'].includes(error.code)) throw error;
    }
  }
  if (unrelatedCount < 1) throw new Error('no unrelated mod roots were tested');
  const destinationsAfter = await snapshotRegisteredDestinations(target);
  const backupsAfter = await snapshotRegisteredBackups(config, target);
  if (!sameSnapshot(destinationSnapshot, destinationsAfter)) {
    throw new Error('registered candidate destinations changed during fixed smoke');
  }
  if (!sameSnapshot(backupSnapshot, backupsAfter)) {
    throw new Error('registered candidate backups changed during fixed smoke');
  }

  return {
    ok: true,
    operation: 'smoke',
    sid: process.env.SKYRIM_DEPLOY_SID || null,
    target_write_backup_replace_rollback_remove: targetRemoved,
    unrelated_count: unrelatedCount,
    unrelated_refused: true,
    config_write_open_refused: await expectWriteRefused(CONFIG_PATH),
    worker_write_open_refused: await expectWriteRefused(WORKER_PATH),
    wrapper_write_open_refused: await expectWriteRefused(WRAPPER_PATH),
    authorized_keys_write_open_refused: await expectWriteRefused(AUTHORIZED_KEYS_PATH),
    registered_destinations_unchanged: true,
    registered_backups_unchanged: true,
    smoke_backup_removed: true
  };
}

function audit(config, requestId, operation, result) {
  const auditDir = path.win32.join(config.backup_root, 'audit');
  fs.mkdirSync(auditDir, { recursive: true });
  const record = {
    timestamp: new Date().toISOString(),
    request_id: requestId,
    operation,
    identity: `${process.env.USERDOMAIN || ''}\\${process.env.USERNAME || ''}`,
    sid: process.env.SKYRIM_DEPLOY_SID || null,
    ssh_connection: process.env.SSH_CONNECTION || null,
    ok: result.ok === true,
    error: result.ok === true ? null : result.error,
    artifacts: Array.isArray(result.artifacts) ? result.artifacts.map(item => ({
      id: item.id,
      destination: item.destination,
      previous_sha256: item.previous_sha256 ?? item.existing_sha256 ?? null,
      source_sha256: item.source_sha256 ?? null,
      resulting_sha256: item.resulting_sha256 ?? null,
      backup: item.backup ?? null,
      size: item.size ?? null
    })) : null,
    event: result.event ?? operation,
    rollback: result.rollback ?? null
  };
  fs.appendFileSync(path.win32.join(auditDir, 'project-deploy.ndjson'), `${JSON.stringify(record)}\r\n`, 'utf8');
}

async function dispatch(input, requestId = crypto.randomUUID()) {
  if (!input || input.protocol !== 'project-deploy-v1' || typeof input.operation !== 'string') {
    throw new Error('unsupported forced-command protocol request');
  }
  if (input.operation === 'health') {
    loadConfig();
    return { ok: true, operation: 'health', service: 'project-deploy-ssh-worker' };
  }
  if (input.operation === 'smoke') return smoke(loadConfig());
  if (input.operation === 'plan') return planDeployment(input);
  if (input.operation === 'apply') return applyDeployment(input, requestId);
  throw new Error('unsupported forced-command operation');
}

function readExact(fd, length) {
  const result = Buffer.alloc(length);
  let offset = 0;
  while (offset < length) {
    const count = fs.readSync(fd, result, offset, length - offset, null);
    if (count === 0) {
      if (offset === 0) return null;
      throw new Error('truncated forced-command frame');
    }
    offset += count;
  }
  return result;
}

function readFrame(fd) {
  const header = readExact(fd, 4);
  if (header === null) return null;
  const length = header.readUInt32BE(0);
  if (length < 2 || length > MAX_REQUEST_BYTES) {
    throw new Error('forced-command frame has an invalid length');
  }
  const payload = readExact(fd, length);
  if (payload === null) throw new Error('truncated forced-command frame');
  try {
    return JSON.parse(payload.toString('utf8'));
  } catch {
    throw new Error('forced-command frame is not valid JSON');
  }
}

function writeFrame(fd, body) {
  const payload = Buffer.from(JSON.stringify(body), 'utf8');
  if (payload.length > MAX_REQUEST_BYTES) throw new Error('response frame exceeds limit');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  fs.writeSync(fd, header);
  fs.writeSync(fd, payload);
}

async function runStdio(inputFd = 0, outputFd = 1) {
  fs.writeSync(outputFd, PROTOCOL_MAGIC);
  if (process.env.SKYRIM_DEPLOY_SID !== EXPECTED_SID ||
      process.env.SSH_ORIGINAL_COMMAND !== 'project-deploy-v1' || !process.env.SSH_CONNECTION) {
    writeFrame(outputFd, { ok: false, error: 'worker requires the exact pinned SSH forced-command identity' });
    return 1;
  }
  const inputMagic = readExact(inputFd, PROTOCOL_MAGIC.length);
  if (inputMagic === null || !crypto.timingSafeEqual(inputMagic, PROTOCOL_MAGIC)) {
    writeFrame(outputFd, { ok: false, error: 'forced-command protocol magic mismatch' });
    return 1;
  }
  for (let count = 1; count <= 2; count += 1) {
    const request = readFrame(inputFd);
    if (request === null) {
      writeFrame(outputFd, { ok: false, error: 'required forced-command request is absent' });
      return 1;
    }
    const requestId = crypto.randomUUID();
    let result;
    try {
      result = await dispatch(request, requestId);
    } catch (error) {
      result = { ok: false, operation: request?.operation || null, error: String(error?.message ?? error) };
    }
    if (request?.operation !== 'apply') {
      try {
        audit(loadConfig(), requestId, request?.operation || null, result);
      } catch (auditError) {
        result = {
          ok: false,
          operation: request?.operation || null,
          error: `required audit write failed: ${String(auditError?.message ?? auditError)}`
        };
      }
    }
    result.request_id = requestId;
    writeFrame(outputFd, result);
    if (!result.ok) return 1;
    if (count === 1 && request.operation !== 'plan') return 0;
    if (count === 2) {
      if (request.operation !== 'apply') {
        writeFrame(outputFd, { ok: false, error: 'second request must be apply' });
        return 1;
      }
      return 0;
    }
  }
  return 1;
}

if (require.main === module) {
  if (process.argv.length !== 3 || process.argv[2] !== '--stdio') {
    process.stderr.write('project-deploy worker requires --stdio\n');
    process.exitCode = 64;
  } else {
    runStdio().then(code => { process.exitCode = code; }).catch(error => {
      try { writeFrame(1, { ok: false, error: String(error?.message ?? error) }); } catch {}
      process.exitCode = 1;
    });
  }
}

module.exports = {
  normalizeRelative,
  samePath,
  beneath,
  validateArtifactRequest,
  dispatch,
  runStdio,
  PROTOCOL_MAGIC,
  readFrame,
  writeFrame
};
