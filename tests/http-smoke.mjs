// Start the container's entry point (dist/httpServer.js) against a loopback-only
// mock API and exercise it over Streamable HTTP, the way mcp.sportwizzard.com
// serves it.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { createServer, request } from 'node:http';
import { dirname, resolve } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const [entryArgument, receiptArgument] = process.argv.slice(2);
assert(entryArgument && receiptArgument, 'Usage: npm run smoke:http -- HTTP_ENTRY RECEIPT_PATH');
const started = performance.now();
const validKey = 'http-smoke-key';
const odds = [{ marketScope: 'SEASON', selection: 'Buffalo Bills', priceAmerican: -180 }];
const requests = [];
const api = createServer((req, res) => {
  const key = req.headers['x-api-key'];
  requests.push({ url: req.url, key });
  res.setHeader('Content-Type', 'application/json');
  if (req.url === '/api/v1/account/usage') {
    if (key !== validKey) {
      res.writeHead(401);
      return res.end(JSON.stringify({ success: false }));
    }
    return res.end(JSON.stringify({ success: true, data: { authenticated: true } }));
  }
  if (req.url === '/api/v1/account/measurement/mcp-tool-success') {
    res.writeHead(204);
    return res.end();
  }
  if (req.url === '/api/v1/odds?scope=season' && key === validKey) {
    return res.end(JSON.stringify({ success: true, data: odds, nextCursor: null, meta: { count: 1 } }));
  }
  res.writeHead(400);
  res.end(JSON.stringify({ error: 'Unexpected mock request' }));
});
const listen = server => new Promise(done => server.listen(0, '127.0.0.1', done));
await listen(api);
const baseUrl = `http://127.0.0.1:${api.address().port}`;

// Reserve a free port for the entry point, which reads its port from MCP_HTTP_PORT.
const probe = createServer();
await listen(probe);
const port = probe.address().port;
await new Promise(done => probe.close(done));
const origin = `http://127.0.0.1:${port}`;

let output = '';
const child = spawn(process.execPath, [resolve(entryArgument)], {
  // NODE_ENV matches the image's ENV.
  env: { PATH: process.env.PATH, NODE_ENV: 'production', MCP_HTTP_PORT: String(port),
    SPORTWIZZARD_BASE_URL: baseUrl },
  stdio: ['ignore', 'pipe', 'pipe'],
});
child.stdout.on('data', chunk => { output += chunk; });
child.stderr.on('data', chunk => { output += chunk; });
const exited = new Promise(done => child.on('exit', (code, signal) => done({ code, signal })));
const timeout = setTimeout(() => {
  console.error(`HTTP entry point smoke exceeded 20 seconds\n${output}`);
  child.kill('SIGKILL');
  process.exit(1);
}, 20_000);

// A raw request, so the smoke can send a foreign Host header.
const raw = (method, path, headers = {}, body = undefined) => new Promise((done, fail) => {
  const req = request({ host: '127.0.0.1', port, method, path, headers }, res => {
    let text = '';
    res.setEncoding('utf8');
    res.on('data', chunk => { text += chunk; });
    res.on('end', () => done({ status: res.statusCode, text }));
  });
  req.on('error', fail);
  req.end(body);
});
const initialize = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
  protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'http-smoke', version: '1.0.0' } } });
const mcpHeaders = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' };

const client = new Client({ name: 'sportwizzard-http-smoke', version: '1.0.0' });
try {
  let health;
  for (;;) {
    try {
      health = await raw('GET', '/healthz');
      if (health.status === 200) break;
    } catch {
      // Not listening yet.
    }
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`entry point exited before listening:\n${output}`);
    }
    await new Promise(done => setTimeout(done, 50));
  }
  const healthBody = JSON.parse(health.text);
  assert.equal(healthBody.status, 'ok');
  assert.equal(healthBody.base_url, baseUrl);

  const missingKey = await raw('POST', '/mcp', mcpHeaders, initialize);
  assert.equal(missingKey.status, 401);
  assert.equal(requests.length, 0, 'a request without a key must not reach the API');
  const wrongKey = await raw('POST', '/mcp', { ...mcpHeaders, Authorization: 'Bearer wrong-key' }, initialize);
  assert.equal(wrongKey.status, 401, 'a key the API rejects must be rejected');
  assert.deepEqual(requests, [{ url: '/api/v1/account/usage', key: 'wrong-key' }],
    'the wrong key must be rejected by the API, not by the missing-key check');
  const foreignHost = await raw('POST', '/mcp',
    { ...mcpHeaders, Host: 'attacker.example', Authorization: `Bearer ${validKey}` }, initialize);
  assert.equal(foreignHost.status, 403, 'a Host header outside the allow list must be refused');
  assert.equal(requests.length, 1, 'the Host check must refuse before the key check');
  assert.equal((await raw('GET', '/mcp')).status, 405);

  const installedPackage = JSON.parse(await readFile(
    resolve(dirname(resolve(entryArgument)), '../package.json'), 'utf8'));
  const transport = new StreamableHTTPClientTransport(new URL(`${origin}/mcp`), {
    requestInit: { headers: { Authorization: `Bearer ${validKey}` } },
  });
  await client.connect(transport);
  assert.equal(client.getServerVersion().version, installedPackage.version);
  const tools = (await client.listTools()).tools;
  assert.equal(tools.length, healthBody.tools, '/healthz and tools/list must agree');
  assert.equal(new Set(tools.map(tool => tool.name)).size, tools.length);
  assert(tools.find(tool => tool.name === 'download_snapshot'));
  const result = await client.callTool({ name: 'get_odds', arguments: { scope: 'season' } });
  assert(!result.isError, JSON.stringify(result));
  const payload = JSON.parse(result.content.find(item => item.type === 'text').text);
  assert.equal(payload.success, true);
  assert.deepEqual(payload.data, odds);
  const forwarded = requests.find(item => item.url === '/api/v1/odds?scope=season');
  assert(forwarded, 'the tool call must reach the mock API');
  assert.equal(forwarded.key, validKey, 'the bearer key must be forwarded as X-Api-Key');
  await client.close();

  child.kill('SIGTERM');
  const stopped = await exited;
  assert.equal(stopped.code, 0, `entry point must exit cleanly on SIGTERM: ${JSON.stringify(stopped)}`);

  const receipt = { result: 'passed', node: process.version,
    environment: 'installed npm tarball with locked runtime dependencies; dist/httpServer.js (the container entry point) with NODE_ENV=production over Streamable HTTP; loopback mock API and dummy fixture key; no production API or credentials',
    command: 'npm run smoke:http -- HTTP_ENTRY RECEIPT_PATH',
    package_version: installedPackage.version, server: client.getServerVersion(),
    tools_list_count: tools.length, api_requests: requests.map(item => item.url),
    duration_seconds: (performance.now() - started) / 1000 };
  await writeFile(resolve(receiptArgument), JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify(receipt));
} finally {
  clearTimeout(timeout);
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  await new Promise(done => api.close(done));
}
