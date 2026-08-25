const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const HOST = '127.0.0.1';
const PORT = 7347;
const CONFIG_PATH = process.env.SKYRIM_DEPLOY_CONFIG ||
  'C:\\ProgramData\\SkyrimToolBridge\\project-deploy\\config.json';
const MAX_REQUEST_BYTES = 180 * 1024 * 1024;
const MAX_CONTENT_BYTES = 128 * 1024 * 1024;
const PLAN_TTL_MS = 5 * 60 * 1000;
const plans = new Map();

function reply(res, status, body) {
  const data = JSON.stringify(body, null, 2);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data)
  });
  res.end(data);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    req.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > MAX_REQUEST_BYTES) {
        reject(new Error('request body exceeds 180 MiB'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'));
      } catch {
        reject(new Error('request body is not valid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function loadConfig() {
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  if (config.schema !== 1 || typeof config.environment !== 'string' ||
      typeof config.backup_root !== 'string' || typeof config.targets !== 'object') {
    throw new Error('deployment bridge config has an unsupported schema');
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
  if (input.environment !== config.environment) {
    throw new Error('environment is not served by this deployment bridge');
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
    if (typeof item.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(item.sha256)) {
      throw new Error(`invalid SHA256 for artifact ${item.id}`);
    }
    if (item.sha256 !== allowed.sha256) {
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

async function handlePlan(req, res) {
  const input = await readJson(req);
  const config = loadConfig();
  const target = resolveTarget(config, input);
  const artifacts = validateArtifactRequest(target, input);
  let total = 0;
  for (const item of artifacts) total += item.size;
  if (total > MAX_CONTENT_BYTES) throw new Error('deployment content exceeds 128 MiB');

  for (const item of artifacts) {
    item.destination = await validateDestination(target.root, item.relative);
    item.existing_sha256 = await currentHash(item.destination);
  }
  for (const [existingToken, existingPlan] of plans) {
    if (existingPlan.expires < Date.now()) plans.delete(existingToken);
  }
  if (plans.size >= 100) throw new Error('too many active deployment plans');
  const token = crypto.randomUUID();
  plans.set(token, {
    expires: Date.now() + PLAN_TTL_MS,
    config,
    target,
    artifacts
  });
  reply(res, 200, {
    ok: true,
    operation: 'plan',
    token,
    expires_seconds: PLAN_TTL_MS / 1000,
    artifacts: artifacts.map(item => ({
      id: item.id,
      destination: item.destination,
      existing_sha256: item.existing_sha256,
      source_sha256: item.sha256
    }))
  });
}

async function handleApply(req, res) {
  const input = await readJson(req);
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
    if (!allowed || !samePath(allowed.destination, item.relative) ||
        allowed.sha256 !== item.sha256) {
      throw new Error(`protected artifact registration changed after plan: ${item.id}`);
    }
  }
  plan.config = currentConfig;
  plan.target = currentTarget;
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
    const revalidated = await validateDestination(currentTarget.root, item.relative);
    if (!samePath(revalidated, item.destination)) {
      throw new Error(`destination identity changed after plan: ${item.destination}`);
    }
    item.destination = revalidated;
    const now = await currentHash(item.destination);
    if (now !== item.existing_sha256) {
      throw new Error(`destination changed after plan; refusing: ${item.destination}`);
    }
  }

  const backupDir = path.win32.join(
    plan.config.backup_root,
    new Date().toISOString().replaceAll(':', '-'),
    crypto.randomUUID()
  );
  const changed = [];
  try {
    for (const item of plan.artifacts) {
      let backup = null;
      if (item.existing_sha256 !== null) {
        backup = path.win32.join(backupDir, item.relative);
        await fs.promises.mkdir(path.win32.dirname(backup), { recursive: true });
        await fs.promises.copyFile(item.destination, backup, fs.constants.COPYFILE_EXCL);
        if (await sha256File(backup) !== item.existing_sha256) {
          throw new Error(`backup hash mismatch: ${item.destination}`);
        }
      }
      const temp = `${item.destination}.skyrim-agent-${crypto.randomUUID()}.tmp`;
      await fs.promises.writeFile(temp, payloads.get(item.id), { flag: 'wx' });
      if (await sha256File(temp) !== item.sha256) {
        await fs.promises.rm(temp, { force: true });
        throw new Error(`staged hash mismatch: ${item.id}`);
      }
      const entry = { item, backup, resulting: null, temp };
      changed.push(entry);
      await fs.promises.rename(temp, item.destination);
      entry.temp = null;
      entry.resulting = await sha256File(item.destination);
      if (entry.resulting !== item.sha256) {
        throw new Error(`resulting hash mismatch: ${item.id}`);
      }
    }
  } catch (error) {
    const rollbackErrors = [];
    for (const entry of changed.reverse()) {
      try {
        if (entry.temp) await fs.promises.rm(entry.temp, { force: true });
        if (entry.backup) {
          await fs.promises.copyFile(entry.backup, entry.item.destination);
          if (await sha256File(entry.item.destination) !== entry.item.existing_sha256) {
            throw new Error(`rollback hash mismatch: ${entry.item.destination}`);
          }
        } else {
          await fs.promises.rm(entry.item.destination, { force: true });
        }
      } catch (rollbackError) {
        rollbackErrors.push(String(rollbackError?.message ?? rollbackError));
      }
    }
    if (rollbackErrors.length) {
      throw new Error(`${String(error?.message ?? error)}; rollback errors: ${rollbackErrors.join('; ')}`);
    }
    throw error;
  }

  reply(res, 200, {
    ok: true,
    operation: 'apply',
    artifacts: changed.map(entry => ({
      id: entry.item.id,
      destination: entry.item.destination,
      previous_sha256: entry.item.existing_sha256,
      resulting_sha256: entry.resulting,
      backup: entry.backup
    }))
  });
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/health') {
      loadConfig();
      return reply(res, 200, { ok: true, service: 'project-deploy-bridge' });
    }
    if (req.method === 'POST' && req.url === '/plan') return await handlePlan(req, res);
    if (req.method === 'POST' && req.url === '/apply') return await handleApply(req, res);
    reply(res, 404, { ok: false, error: 'unsupported operation' });
  } catch (error) {
    reply(res, 400, { ok: false, error: String(error?.message ?? error) });
  }
});

if (require.main === module) {
  server.listen(PORT, HOST, () => {
    console.log(`project deployment bridge listening on http://${HOST}:${PORT}`);
    console.log(`config: ${CONFIG_PATH}`);
  });
}

module.exports = { normalizeRelative, samePath, beneath, validateArtifactRequest };
