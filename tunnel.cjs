"use strict";

const net = require("node:net");

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

function portEnv(name) {
  const value = Number(requiredEnv(name));
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`Invalid port in ${name}`);
  }
  return value;
}

const LISTEN_HOST = requiredEnv("CODEX_REMOTE_LISTEN_HOST");
const LISTEN_PORT = portEnv("CODEX_REMOTE_LISTEN_PORT");
const PROXY_HOST = requiredEnv("CODEX_REMOTE_PROXY_HOST");
const PROXY_PORT = portEnv("CODEX_REMOTE_PROXY_PORT");
const TARGET_HOST = requiredEnv("CODEX_REMOTE_TARGET_HOST");
const TARGET_PORT = portEnv("CODEX_REMOTE_TARGET_PORT");
const MAX_CONNECT_RESPONSE_BYTES = 16 * 1024;

function closePair(client, upstream) {
  if (!client.destroyed) client.destroy();
  if (upstream && !upstream.destroyed) upstream.destroy();
}

const server = net.createServer((client) => {
  client.pause();
  const upstream = net.connect({ host: PROXY_HOST, port: PROXY_PORT });
  let response = Buffer.alloc(0);
  let established = false;
  const fail = () => closePair(client, upstream);

  client.once("error", fail);
  upstream.once("error", fail);
  upstream.once("connect", () => {
    upstream.write(
      `CONNECT ${TARGET_HOST}:${TARGET_PORT} HTTP/1.1\r\n` +
        `Host: ${TARGET_HOST}:${TARGET_PORT}\r\n` +
        "Proxy-Connection: Keep-Alive\r\n\r\n",
      "ascii",
    );
  });

  function onConnectResponse(chunk) {
    response = Buffer.concat([response, chunk]);
    if (response.length > MAX_CONNECT_RESPONSE_BYTES) return fail();

    const headerEnd = response.indexOf("\r\n\r\n");
    if (headerEnd === -1) return;
    const statusLineEnd = response.indexOf("\r\n");
    const statusLine = response
      .subarray(0, statusLineEnd === -1 ? headerEnd : statusLineEnd)
      .toString("ascii");
    if (!/^HTTP\/1\.[01] 200\b/.test(statusLine)) return fail();

    established = true;
    upstream.off("data", onConnectResponse);
    const remaining = response.subarray(headerEnd + 4);
    if (remaining.length) client.write(remaining);
    client.pipe(upstream);
    upstream.pipe(client);
    client.resume();
  }

  upstream.on("data", onConnectResponse);
  upstream.once("close", () => {
    if (!established || !client.destroyed) client.destroy();
  });
  client.once("close", () => {
    if (!upstream.destroyed) upstream.destroy();
  });
});

server.on("error", (error) => {
  process.stderr.write(`${new Date().toISOString()} ${error.stack || error.message}\n`);
  process.exitCode = 1;
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  process.stdout.write(
    `${new Date().toISOString()} listening ${LISTEN_HOST}:${LISTEN_PORT}; ` +
      `proxy ${PROXY_HOST}:${PROXY_PORT}; target ${TARGET_HOST}:${TARGET_PORT}\n`,
  );
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
