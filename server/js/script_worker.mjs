/*
 * ProxyPin server - JavaScript script worker.
 *
 * The desktop/mobile app runs user scripts with flutter_js (QuickJS / JavaScriptCore). The headless
 * server has no Flutter, so it runs them here instead. The Dart side (lib/server/script/node_script_runtime.dart)
 * talks to this process over stdin/stdout using newline-delimited JSON:
 *
 *   -> {"id": 1, "type": "eval", "code": "...", "timeout": 30000}
 *   <- {"id": 1, "ok": true, "result": <json>}          | {"id": 1, "ok": false, "error": "..."}
 *   <- {"type": "log", "id": 1, "args": ["log", ...arguments]}   (console output of eval 1, flutter_js ConsoleLog shape)
 *
 * Every evaluation gets a fresh V8 context exposing the same globals ProxyPin scripts can use on the desktop:
 * console, fetch, XMLHttpRequest, md5(), File(), getApplicationSupportDirectory(), timers, URL, TextEncoder, ...
 * State that must survive between runs belongs in `context.session`, exactly as on the desktop.
 */
import { createHash, webcrypto } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import vm from 'node:vm';

const DATA_DIR = process.env.PROXYPIN_DATA_DIR || process.cwd();
const DEFAULT_TIMEOUT = 30000;

// stdout is the protocol channel: nothing else may write to it.
function send(message) {
  process.stdout.write(JSON.stringify(message, jsonReplacer) + '\n');
}

/** Typed arrays / buffers serialize as plain int arrays, matching flutter_js results. */
function jsonReplacer(_key, value) {
  if (value === undefined) return null;
  if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
  if (ArrayBuffer.isView(value)) return Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  if (typeof value === 'bigint') return value.toString();
  return value;
}

function consoleArg(value) {
  if (value instanceof Error) return value.stack || String(value);
  if (typeof value === 'function') return value.toString();
  if (typeof value === 'symbol') return value.toString();
  try {
    // round-trip through JSON like flutter_js does (JSON.stringify(['log', ...arguments]))
    return JSON.parse(JSON.stringify(value, jsonReplacer) ?? 'null');
  } catch (_) {
    return String(value);
  }
}

function makeConsole(id) {
  // flutter_js maps console.warn to 'info' (ScriptManager turns 'info' into 'warn'); keep that contract.
  const emit = (level) => (...args) => send({ type: 'log', id, args: [level, ...args.map(consoleArg)] });
  return {
    log: emit('log'),
    debug: emit('log'),
    info: emit('log'),
    warn: emit('info'),
    error: emit('error'),
    trace: emit('log'),
  };
}

function toBytes(input) {
  if (Array.isArray(input)) return Buffer.from(input);
  if (input instanceof ArrayBuffer) return Buffer.from(new Uint8Array(input));
  if (ArrayBuffer.isView(input)) return Buffer.from(input.buffer, input.byteOffset, input.byteLength);
  return Buffer.from(String(input), 'utf8');
}

function md5(input) {
  return createHash('md5').update(toBytes(input)).digest('hex');
}

/** Same surface as lib/network/components/js/file.dart (FileBridge). Relative paths resolve against the data dir. */
function File(filePath) {
  const resolved = path.isAbsolute(String(filePath)) ? String(filePath) : path.join(DATA_DIR, String(filePath));
  const flag = (append) => (append ? 'a' : 'w');
  return {
    path: filePath,
    readAsString: () => fs.promises.readFile(resolved, 'utf8'),
    readAsStringSync: () => fs.readFileSync(resolved, 'utf8'),
    readAsBytes: async () => Array.from(await fs.promises.readFile(resolved)),
    readAsBytesSync: () => Array.from(fs.readFileSync(resolved)),
    writeAsString: async (content, append) => {
      await fs.promises.writeFile(resolved, String(content), { flag: flag(append) });
      return true;
    },
    writeAsStringSync: (content, append) => {
      fs.writeFileSync(resolved, String(content), { flag: flag(append) });
      return true;
    },
    writeAsBytes: async (bytes, append) => {
      await fs.promises.writeFile(resolved, toBytes(bytes), { flag: flag(append) });
      return true;
    },
    writeAsBytesSync: (bytes, append) => {
      fs.writeFileSync(resolved, toBytes(bytes), { flag: flag(append) });
      return true;
    },
    length: async () => (await fs.promises.stat(resolved)).size,
    lengthSync: () => fs.statSync(resolved).size,
    delete: async () => {
      await fs.promises.rm(resolved, { force: true });
      return true;
    },
    deleteSync: () => {
      fs.rmSync(resolved, { force: true });
      return true;
    },
    exists: async () => fs.existsSync(resolved),
    existsSync: () => fs.existsSync(resolved),
    create: async (recursive) => {
      if (recursive) await fs.promises.mkdir(path.dirname(resolved), { recursive: true });
      await fs.promises.appendFile(resolved, '');
      return true;
    },
    createSync: (recursive) => {
      if (recursive) fs.mkdirSync(path.dirname(resolved), { recursive: true });
      fs.appendFileSync(resolved, '');
      return true;
    },
    rename: async (newPath) => {
      const target = path.isAbsolute(String(newPath)) ? String(newPath) : path.join(DATA_DIR, String(newPath));
      await fs.promises.rename(resolved, target);
      return File(target);
    },
  };
}

/** Minimal asynchronous XMLHttpRequest on top of fetch (flutter_js exposes one; some scripts still use it). */
function makeXMLHttpRequest(realFetch) {
  return class XMLHttpRequest {
    static UNSENT = 0;
    static OPENED = 1;
    static HEADERS_RECEIVED = 2;
    static LOADING = 3;
    static DONE = 4;

    constructor() {
      this.readyState = 0;
      this.status = 0;
      this.statusText = '';
      this.responseText = '';
      this.response = '';
      this.responseURL = '';
      this.responseType = '';
      this.withCredentials = false;
      this.timeout = 0;
      this._headers = {};
      this._responseHeaders = new Map();
      this.onload = null;
      this.onerror = null;
      this.onreadystatechange = null;
      this.ontimeout = null;
    }

    open(method, url) {
      this._method = String(method || 'GET').toUpperCase();
      this._url = url;
      this._setState(1);
    }

    setRequestHeader(name, value) {
      this._headers[name] = value;
    }

    getResponseHeader(name) {
      return this._responseHeaders.get(String(name).toLowerCase()) ?? null;
    }

    getAllResponseHeaders() {
      return [...this._responseHeaders].map(([k, v]) => `${k}: ${v}`).join('\r\n');
    }

    abort() {
      this._controller?.abort();
    }

    _setState(state) {
      this.readyState = state;
      if (typeof this.onreadystatechange === 'function') this.onreadystatechange();
    }

    send(body) {
      this._controller = new AbortController();
      const timer = this.timeout > 0 ? setTimeout(() => this._controller.abort(), this.timeout) : null;
      const init = { method: this._method, headers: this._headers, signal: this._controller.signal };
      if (body != null && this._method !== 'GET' && this._method !== 'HEAD') init.body = body;
      realFetch(this._url, init)
        .then(async (res) => {
          this.status = res.status;
          this.statusText = res.statusText;
          this.responseURL = res.url;
          res.headers.forEach((v, k) => this._responseHeaders.set(k, v));
          this._setState(2);
          this.responseText = await res.text();
          this.response = this.responseType === 'json' ? JSON.parse(this.responseText || 'null') : this.responseText;
          this._setState(4);
          if (typeof this.onload === 'function') this.onload();
        })
        .catch((error) => {
          this._setState(4);
          const handler = error?.name === 'AbortError' && this.ontimeout ? this.ontimeout : this.onerror;
          if (typeof handler === 'function') handler(error);
        })
        .finally(() => timer && clearTimeout(timer));
    }
  };
}

function createSandbox(id) {
  const sandbox = {
    console: makeConsole(id),
    md5,
    File,
    getApplicationSupportDirectory: async () => DATA_DIR,
    fetch: (...args) => fetch(...args),
    Headers,
    Request,
    Response,
    FormData,
    Blob,
    AbortController,
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    atob,
    btoa,
    crypto: webcrypto,
    structuredClone,
    queueMicrotask,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  };
  sandbox.XMLHttpRequest = makeXMLHttpRequest(sandbox.fetch);
  sandbox.globalThis = sandbox;
  return vm.createContext(sandbox, { name: 'proxypin-script' });
}

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Script timed out after ${ms}ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function evaluate(id, code, timeout) {
  const context = createSandbox(id);
  const script = new vm.Script(String(code), { filename: 'proxypin-script.js' });
  // the completion value of the last expression is the result (QuickJS eval semantics)
  const value = script.runInContext(context, { timeout, breakOnSigint: false });
  const result = value && typeof value.then === 'function' ? await withTimeout(value, timeout) : value;
  // JSON round-trip here so serialization errors surface as script errors, not protocol errors
  return JSON.parse(JSON.stringify(result, jsonReplacer) ?? 'null');
}

async function handle(message) {
  if (message.type === 'ping') {
    send({ id: message.id, ok: true, result: 'pong' });
    return;
  }
  if (message.type !== 'eval') {
    send({ id: message.id, ok: false, error: `unknown message type: ${message.type}` });
    return;
  }
  try {
    const result = await evaluate(message.id, message.code, Number(message.timeout) || DEFAULT_TIMEOUT);
    send({ id: message.id, ok: true, result });
  } catch (error) {
    send({ id: message.id, ok: false, error: error?.stack || String(error) });
  }
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    send({ type: 'log', args: ['error', `script worker: bad message ${error}`] });
    return;
  }
  handle(message);
});
input.on('close', () => process.exit(0));

process.on('uncaughtException', (error) => send({ type: 'log', args: ['error', `uncaught: ${error?.stack || error}`] }));
process.on('unhandledRejection', (error) => send({ type: 'log', args: ['error', `unhandled: ${error?.stack || error}`] }));

send({ type: 'ready', node: process.version });
