const http = require('http');

const HOST = '127.0.0.1';
const PORT = 7346;
const HOUSECARL = 'http://127.0.0.1:7345/';

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
    let body = '';
    let bytes = 0;

    req.setEncoding('utf8');

    req.on('data', chunk => {
      bytes += Buffer.byteLength(chunk);

      if (bytes > 64 * 1024) {
        reject(new Error('request body exceeds 64 KiB'));
        req.destroy();
        return;
      }

      body += chunk;
    });

    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error('request body is not valid JSON'));
      }
    });

    req.on('error', reject);
  });
}

function parseSse(text) {
  const blocks = text.split(/\r?\n\r?\n/);

  for (const block of blocks) {
    const data = block
      .split(/\r?\n/)
      .filter(line => line.startsWith('data:'))
      .map(line => line.replace(/^data:\s?/, ''))
      .join('\n');

    if (data) {
      return JSON.parse(data);
    }
  }

  throw new Error('houseCARL returned SSE without a data event');
}

async function callHouseCarl(tool, args) {
  const response = await fetch(HOUSECARL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream'
    },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: tool,
        arguments: args
      }
    })
  });

  const raw = await response.text();

  if (!response.ok) {
    throw new Error(
      `houseCARL HTTP ${response.status}: ${raw.slice(0, 1000)}`
    );
  }

  const contentType =
    response.headers.get('content-type') || '';

  const envelope = contentType.includes('text/event-stream')
    ? parseSse(raw)
    : JSON.parse(raw);

  if (envelope.error) {
    throw new Error(
      `houseCARL MCP error: ${JSON.stringify(envelope.error)}`
    );
  }

  return envelope.result;
}

function validatePluginName(value, field) {
  if (value == null) return null;

  if (typeof value !== 'string')
    throw new Error(`${field} must be a string`);

  if (
    value.includes('/') ||
    value.includes('\\') ||
    value.includes('\r') ||
    value.includes('\n')
  ) {
    throw new Error(`${field} must be a plugin filename, not a path`);
  }

  if (!/\.(esp|esm|esl)$/i.test(value))
    throw new Error(`${field} must end in .esp, .esm, or .esl`);

  return value;
}

function validateReadRecord(input) {
  if (
    typeof input.formid !== 'string' ||
    !/^[0-9a-f]{6}:[^\\/\r\n]+\.(esp|esm|esl)$/i.test(input.formid)
  ) {
    throw new Error(
      'formid must look like 000007:Skyrim.esm'
    );
  }

  const args = {
    formid: input.formid,
    format: 'json',

    // Fixed by the bridge, not controllable by the caller.
    max_chars: 60000
  };

  if (input.plugin != null) {
    args.plugin =
      validatePluginName(input.plugin, 'plugin');
  }

  if (input.fields != null) {
    if (
      !Array.isArray(input.fields) ||
      input.fields.length > 32 ||
      input.fields.some(
        value =>
          typeof value !== 'string' ||
          value.length > 200 ||
          /[\r\n]/.test(value)
      )
    ) {
      throw new Error(
        'fields must be an array of at most 32 short field paths'
      );
    }

    args.fields = input.fields;
  }

  if (input.depth != null) {
    if (
      !Number.isInteger(input.depth) ||
      input.depth < 1 ||
      input.depth > 4
    ) {
      throw new Error(
        'depth must be an integer from 1 through 4'
      );
    }

    args.depth = input.depth;
  }

  if (input.conflict_tree != null) {
    if (typeof input.conflict_tree !== 'boolean')
      throw new Error('conflict_tree must be boolean');

    // houseCARL does not support conflict_tree with JSON format.
    if (input.conflict_tree)
      throw new Error(
        'conflict_tree is not enabled in the read bridge yet'
      );
  }

  if (input.resolve_names != null) {
    if (typeof input.resolve_names !== 'boolean')
      throw new Error('resolve_names must be boolean');

    args.resolve_names = input.resolve_names;
  }

  return args;
}

function validateDiffRecord(input) {
  if (
    typeof input.formid !== 'string' ||
    !/^[0-9a-f]{6}:[^\\/\r\n]+\.(esp|esm|esl)$/i.test(input.formid)
  ) {
    throw new Error(
      'formid must look like 000007:Skyrim.esm'
    );
  }

  const pluginA = validatePluginName(
    input.plugin_a,
    'plugin_a'
  );

  const pluginB = validatePluginName(
    input.plugin_b,
    'plugin_b'
  );

  if (!pluginA || !pluginB) {
    throw new Error(
      'plugin_a and plugin_b are required'
    );
  }

  const args = {
    formid: input.formid,
    plugin_a: pluginA,
    plugin_b: pluginB,

    // Fixed by the bridge.
    format: 'json',
    max_chars: 60000
  };

  if (input.fields != null) {
    if (
      !Array.isArray(input.fields) ||
      input.fields.length > 32 ||
      input.fields.some(
        value =>
          typeof value !== 'string' ||
          value.length > 200 ||
          /[\r\n]/.test(value)
      )
    ) {
      throw new Error(
        'fields must be an array of at most 32 short field paths'
      );
    }

    args.fields = input.fields;
  }

  return args;
}

function validateQueryRecords(input) {
  const args = {
    // Fixed by the bridge.
    format: 'json',
    offset: 0,

    // Summary-only responses at <=50 rows should stay comfortably
    // below this ceiling, avoiding houseCARL's spill-to-file path.
    max_chars: 250000
  };

  let hasBound = false;

  if (input.type != null) {
    if (
      typeof input.type !== 'string' ||
      !/^[A-Za-z0-9_]{2,64}$/.test(input.type)
    ) {
      throw new Error(
        'type must be a short record signature or catalog name'
      );
    }

    args.type = input.type;
    hasBound = true;
  }

  if (input.plugin != null) {
    const plugin = validatePluginName(
      input.plugin,
      'plugin'
    );

    args.plugins = [plugin];
    hasBound = true;
  }

  if (input.editorid != null) {
    if (
      typeof input.editorid !== 'string' ||
      input.editorid.length < 1 ||
      input.editorid.length > 128 ||
      /[\r\n]/.test(input.editorid)
    ) {
      throw new Error(
        'editorid must be a short single-line substring'
      );
    }

    args.editorid_contains = input.editorid;
  }

  if (input.conflicts_only != null) {
    if (typeof input.conflicts_only !== 'boolean') {
      throw new Error(
        'conflicts_only must be boolean'
      );
    }

    args.conflicts_only = input.conflicts_only;
  }

  const limit = input.limit == null
    ? 25
    : input.limit;

  if (
    !Number.isInteger(limit) ||
    limit < 1 ||
    limit > 50
  ) {
    throw new Error(
      'limit must be an integer from 1 through 50'
    );
  }

  args.limit = limit;

  if (!hasBound) {
    throw new Error(
      'query-records requires type or plugin'
    );
  }

  return args;
}

async function handleQueryRecords(req, res) {
  const input = await readJson(req);
  const args = validateQueryRecords(input);

  const result = await callHouseCarl(
    'housecarl_cross_plugin_query',
    args
  );

  const textPart = result?.content?.find(
    item => item?.type === 'text'
  );

  if (!textPart || typeof textPart.text !== 'string') {
    throw new Error(
      'houseCARL returned no text tool result'
    );
  }

  let data;

  try {
    data = JSON.parse(textPart.text);
  } catch {
    data = {
      raw: textPart.text
    };
  }

  reply(res, 200, {
    ok: true,
    operation: 'query-records',
    data
  });
}

async function handleDiffRecord(req, res) {
  const input = await readJson(req);
  const args = validateDiffRecord(input);

  const result = await callHouseCarl(
    'housecarl_diff_record',
    args
  );

  const textPart = result?.content?.find(
    item => item?.type === 'text'
  );

  if (!textPart || typeof textPart.text !== 'string') {
    throw new Error(
      'houseCARL returned no text tool result'
    );
  }

  let data;

  try {
    data = JSON.parse(textPart.text);
  } catch {
    data = {
      raw: textPart.text
    };
  }

  reply(res, 200, {
    ok: true,
    operation: 'diff-record',
    data
  });
}

async function handleReadRecord(req, res) {
  const input = await readJson(req);
  const args = validateReadRecord(input);

  const result = await callHouseCarl(
    'housecarl_read_record',
    args
  );

  const textPart = result?.content?.find(
    item => item?.type === 'text'
  );

  if (!textPart || typeof textPart.text !== 'string') {
    throw new Error(
      'houseCARL returned no text tool result'
    );
  }

  let data;

  try {
    data = JSON.parse(textPart.text);
  } catch {
    data = {
      raw: textPart.text
    };
  }

  reply(res, 200, {
    ok: true,
    operation: 'read-record',
    data
  });
}

const server = http.createServer(async (req, res) => {
  try {
    if (
      req.method === 'GET' &&
      req.url === '/health'
    ) {
      return reply(res, 200, {
        ok: true,
        service: 'housecarl-read-bridge'
      });
    }

    if (
      req.method === 'POST' &&
      req.url === '/read-record'
    ) {
      return await handleReadRecord(req, res);
    }

    if (
      req.method === 'POST' &&
      req.url === '/diff-record'
    ) {
      return await handleDiffRecord(req, res);
    }

    if (
      req.method === 'POST' &&
      req.url === '/query-records'
    ) {
      return await handleQueryRecords(req, res);
    }

    reply(res, 404, {
      ok: false,
      error: 'unsupported operation'
    });
  } catch (error) {
    reply(res, 400, {
      ok: false,
      error: String(error?.message ?? error)
    });
  }
});

server.listen(PORT, HOST, () => {
  console.log(
    `houseCARL read bridge listening on http://${HOST}:${PORT}`
  );
  console.log(
    `upstream houseCARL: ${HOUSECARL}`
  );
});


