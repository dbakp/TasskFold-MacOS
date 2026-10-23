import { createHmac } from "node:crypto";
import { connectWebhookSocket } from "./socket.ts";
import { createServer } from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { TLSSocket } from "node:tls";
import {
  createWebhookTransport,
  publicWebhookAddress,
  webhookHeaders,
  type WebhookMessage,
  webhookTarget,
} from "./transport.ts";
import { openWebhookSecret, sealWebhookSecret } from "./secret.ts";

const assert = (ok: unknown, label: string) => {
  if (!ok) throw Error(label);
};
async function rejects(work: () => unknown) {
  try {
    await work();
  } catch {
    return;
  }
  throw Error("Expected rejection");
}
const id = "f091cafe-0000-4000-8000-000000000001";
const other = "f091cafe-0000-4000-8000-000000000002";
const message: WebhookMessage = {
  subscription: id,
  event: other,
  timestamp: 1792730000,
  body: JSON.stringify({ version: 1, title: "Préparer la réunion 📝" }),
  secret: new Uint8Array(32).fill(23),
};

Deno.test("webhook address policy rejects special, embedded and ambiguous private routes", () => {
  for (
    const ip of [
      "0.0.0.0",
      "0.2.3.4",
      "10.0.0.1",
      "100.64.0.1",
      "100.127.255.255",
      "127.0.0.1",
      "127.255.255.255",
      "169.254.169.254",
      "172.16.0.1",
      "172.31.255.255",
      "192.0.0.8",
      "192.0.0.170",
      "192.0.2.1",
      "192.88.99.2",
      "192.168.1.1",
      "198.18.0.1",
      "198.19.255.255",
      "198.51.100.1",
      "203.0.113.1",
      "224.0.0.1",
      "239.255.255.255",
      "240.0.0.1",
      "255.255.255.255",
      "::",
      "::1",
      "::127.0.0.1",
      "::ffff:127.0.0.1",
      "::ffff:8.8.8.8",
      "64:ff9b::7f00:1",
      "64:ff9b:1::1",
      "100::1",
      "100:0:0:1::1",
      "2001::1",
      "2001:2::1",
      "2001:10::1",
      "2001:db8::1",
      "2002:7f00:1::1",
      "3fff::1",
      "3fff:fff:ffff::1",
      "5f00::1",
      "fc00::1",
      "fd00::1",
      "fe80::1",
      "ff02::1",
      "fe80::1%en0",
      "127.1",
      "2130706433",
      "0x7f000001",
      "not an IP",
    ]
  ) assert(!publicWebhookAddress(ip), "Must refuse " + ip);
  for (
    const ip of [
      "1.1.1.1",
      "8.8.8.8",
      "100.63.255.255",
      "100.128.0.0",
      "172.15.255.255",
      "172.32.0.0",
      "192.0.0.9",
      "192.0.0.10",
      "192.31.196.1",
      "192.52.193.1",
      "192.175.48.1",
      "198.17.255.255",
      "198.20.0.0",
      "223.255.255.255",
      "2001:4860:4860::8888",
      "2606:4700:4700::1111",
      "2001:1::1",
      "2001:3::1",
      "2001:4:112::1",
      "2620:4f:8000::1",
    ]
  ) assert(publicWebhookAddress(ip), "Must allow public " + ip);
});

Deno.test("webhook URLs canonicalize public identities and refuse userinfo, controls and URL parser bypasses", async () => {
  for (
    const url of [
      "http://receiver.example",
      "https://user:pass@receiver.example/",
      "https://receiver.example/#secret",
      "https://127.1/",
      "https://2130706433/",
      "https://0x7f000001/",
      "https://[::ffff:7f00:1]/",
      "https://localhost/",
      "https://foo.localhost/",
      "https://foo.local/",
      "https://a.internal/",
      "https://a.home.arpa/",
      "https://metadata/",
      "https://receiver.example:0/",
      "https://receiver.example:65536/",
      "https://receiver.example/\nprivate",
      "https://receiver.example\\@127.0.0.1/",
      "https://receiver.example/" + "x".repeat(4096),
    ]
  ) await rejects(() => webhookTarget(url));
  const target = webhookTarget(
    "https://RECEIVER.example.:8443/events?key=private%2Fvalue",
  );
  assert(
    target.hostname === "receiver.example" &&
      target.authority === "receiver.example:8443",
    "Normalized host",
  );
  assert(
    target.path === "/events?key=private%2Fvalue" && target.port === 8443,
    "Retained path/query/port",
  );
  assert(
    webhookTarget("https://[2606:4700:4700::1111]/").hostname ===
      "2606:4700:4700::1111",
    "Literal global IPv6",
  );
});

Deno.test("webhook HMAC signs exact UTF-8 bytes, event, subscription and attempt timestamp", async () => {
  const headers = await webhookHeaders(message);
  const independent = createHmac("sha256", message.secret).update(
    `v1.${message.timestamp}.${id}.${other}.${message.body}`,
  ).digest("hex");
  assert(
    headers["X-Taskfold-Signature"] === "v1=" + independent,
    "Independent receiver signature",
  );
  assert(
    Number(headers["Content-Length"]) ===
      new TextEncoder().encode(message.body).length,
    "UTF-8 byte length",
  );
  for (
    const change of [{ body: message.body + " " }, { event: id }, {
      subscription: other,
    }, { timestamp: message.timestamp + 1 }]
  ) {
    assert(
      (await webhookHeaders({ ...message, ...change }))[
        "X-Taskfold-Signature"
      ] !== headers["X-Taskfold-Signature"],
      "Bound field",
    );
  }
  await rejects(() =>
    webhookHeaders({ ...message, secret: new Uint8Array(31) })
  );
  await rejects(() => webhookHeaders({ ...message, body: "é".repeat(131073) }));
});

Deno.test("webhook receiver secrets use random authenticated encryption bound to account, endpoint and master version", async () => {
  const master = new Uint8Array(32).fill(74);
  const envelope = await sealWebhookSecret(
    message.secret,
    master,
    id,
    other,
    "primary-1",
  );
  const second = await sealWebhookSecret(
    message.secret,
    master,
    id,
    other,
    "primary-1",
  );
  assert(
    envelope.nonce !== second.nonce &&
      envelope.ciphertext !== second.ciphertext,
    "Independent random nonces",
  );
  assert(
    (await openWebhookSecret(envelope, master, id, other)).every((b, i) =>
      b === message.secret[i]
    ),
    "Secret recovered",
  );
  for (
    const work of [
      () => openWebhookSecret(envelope, master, other, other),
      () => openWebhookSecret(envelope, master, id, id),
      () =>
        openWebhookSecret(
          { ...envelope, keyVersion: "primary-2" },
          master,
          id,
          other,
        ),
      () => openWebhookSecret(envelope, new Uint8Array(32).fill(75), id, other),
      () =>
        openWebhookSecret(
          { ...envelope, nonce: envelope.nonce.slice(1) },
          master,
          id,
          other,
        ),
      () =>
        openWebhookSecret(
          { ...envelope, ciphertext: "A".repeat(64) },
          master,
          id,
          other,
        ),
      () =>
        sealWebhookSecret(
          message.secret,
          new Uint8Array(16),
          id,
          other,
          "primary-1",
        ),
    ]
  ) await rejects(work);
});

Deno.test("webhook DNS checks fail closed and cancellation never starts a late socket", async () => {
  let sockets = 0;
  const noSocket = (() => {
    sockets++;
    throw Error("Must never connect");
  }) as typeof connectWebhookSocket;
  for (
    const addresses of [[], [{ address: "127.0.0.1", family: 4 }], [{
      address: "1.1.1.1",
      family: 4,
    }, { address: "169.254.169.254", family: 4 }], [{
      address: "1.1.1.1",
      family: 6,
    }], Array(17).fill({ address: "1.1.1.1", family: 4 })]
  ) {
    const send = createWebhookTransport({
      resolve: () => Promise.resolve(addresses),
      connect: noSocket,
    });
    assert(
      (await send("https://receiver.example/", message)).outcome === "refused",
      "Reject entire DNS set",
    );
  }
  const failed = createWebhookTransport({
    resolve: () => Promise.reject(Error("private DNS diagnostic")),
    connect: noSocket,
  });
  assert(
    JSON.stringify(await failed("https://receiver.example/", message)) ===
      '{"outcome":"retry"}',
    "No raw diagnostic",
  );
  let resolved:
    | ((value: { address: string; family: number }[]) => void)
    | undefined;
  const held = new Promise<{ address: string; family: number }[]>((r) => {
    resolved = r;
  });
  const send = createWebhookTransport({
    resolve: () => held,
    connect: noSocket,
  });
  const controller = new AbortController();
  const attempt = send("https://receiver.example/", message, {
    signal: controller.signal,
  });
  controller.abort();
  await attempt;
  resolved!([{ address: "1.1.1.1", family: 4 }]);
  await new Promise((r) => setTimeout(r, 5));
  assert(sockets === 0, "No socket after cancellation/private DNS");
});

Deno.test("webhook actual TLS and HTTP receiver behavior", async (t) => {
  const directory = await Deno.makeTempDir({
    dir: "/private/tmp",
    prefix: "taskfold-webhook-tls-",
  });
  try {
    const generated = await new Deno.Command("openssl", {
      args: [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-days",
        "1",
        "-subj",
        "/CN=receiver.example",
        "-addext",
        "subjectAltName=DNS:receiver.example",
        "-keyout",
        directory + "/key.pem",
        "-out",
        directory + "/cert.pem",
      ],
      stdout: "piped",
      stderr: "piped",
    }).output();
    assert(generated.success, "Generate owned local TLS certificate");
    const cert = await Deno.readTextFile(directory + "/cert.pem"),
      key = await Deno.readTextFile(directory + "/key.pem");
    const hits: {
      host?: string;
      path?: string;
      sni?: string;
      body: string;
      headers: IncomingMessage["headers"];
    }[] = [];
    let respond: (req: IncomingMessage, res: ServerResponse) => void = (
      _req,
      res,
    ) => {
      res.writeHead(204);
      res.end();
    };
    const server = createServer({ key, cert }, (req, res) => {
      let body = "";
      req.setEncoding("utf8");
      req.on("data", (chunk) => {
        body += chunk;
      });
      req.on("end", () => {
        hits.push({
          host: req.headers.host,
          path: req.url,
          sni: (req.socket as TLSSocket).servername || undefined,
          body,
          headers: req.headers,
        });
        respond(req, res);
      });
    });
    server.on("tlsClientError", () => {});
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const configs: { address: string; port: number; hostname: string }[] = [];
    // This test changes only the dial route and the trusted CA at the I/O
    // boundary. It retains the production TCP -> TLS hostname handshake.
    const tcp = (options: Deno.ConnectOptions) =>
      Deno.connect({ ...options, hostname: "127.0.0.1", port });
    const mapped: typeof connectWebhookSocket = (
      address,
      requestedPort,
      hostname,
      signal,
    ) => {
      configs.push({ address, port: requestedPort, hostname });
      assert(
        address === "93.184.216.34" && requestedPort === 8443,
        "Socket pinned to checked public IP",
      );
      return connectWebhookSocket(address, requestedPort, hostname, signal, {
        tcp,
        tls: (conn, options) =>
          Deno.startTls(conn, { ...options, caCerts: [cert] }),
      });
    };
    let resolutions = 0;
    const send = createWebhookTransport({
      resolve: () => {
        resolutions++;
        return Promise.resolve([{ address: "93.184.216.34", family: 4 }]);
      },
      connect: mapped,
    });
    const target = "https://receiver.example:8443/events?token=synthetic";
    try {
      await t.step(
        "signed POST retains hostname, SNI, encoded route and exact body on pinned socket",
        async () => {
          assert(
            (await send(target, message)).outcome === "delivered",
            "204 acknowledgement",
          );
          const hit = hits.at(-1)!;
          assert(
            hit.host === "receiver.example:8443" &&
              hit.sni === "receiver.example",
            "HTTP and TLS host identity",
          );
          assert(
            hit.path === "/events?token=synthetic" && hit.body === message.body,
            "Exact signed payload",
          );
          assert(
            hit.headers["x-taskfold-signature"] ===
              (await webhookHeaders(message))["X-Taskfold-Signature"],
            "Actual signature transmitted",
          );
          assert(
            !hit.headers.authorization && !hit.headers.cookie,
            "No native/API credentials",
          );
        },
      );
      await t.step(
        "final authorization runs after TLS and can stop every HTTP byte",
        async () => {
          const before = hits.length;
          let checked = false;
          const denied = await send(target, message, {
            beforeWrite: () => {
              checked = true;
              return Promise.reject(Error("Access was removed"));
            },
          });
          assert(
            checked && denied.outcome === "retry" && hits.length === before,
            "No task/header request reaches receiver after denied authorization",
          );
          let allowed = false;
          const accepted = await send(target, message, {
            beforeWrite: () => {
              allowed = true;
              return Promise.resolve();
            },
          });
          assert(
            allowed && accepted.outcome === "delivered" &&
              hits.length === before + 1,
            "Authorized TLS socket sends once",
          );
        },
      );
      await t.step(
        "bad certificate hostname and untrusted CA fail without a request body",
        async () => {
          const before = hits.length;
          assert(
            (await send("https://wrong.example/", message)).outcome === "retry",
            "Wrong hostname rejected",
          );
          const untrusted = createWebhookTransport({
            resolve: () =>
              Promise.resolve([{ address: "93.184.216.34", family: 4 }]),
            connect: (address, requestedPort, hostname, signal) =>
              connectWebhookSocket(address, requestedPort, hostname, signal, {
                tcp,
              }),
          });
          assert(
            (await untrusted(target, message)).outcome === "retry",
            "Untrusted CA rejected",
          );
          assert(
            hits.length === before,
            "No secret/task payload after failed TLS",
          );
        },
      );
      await t.step(
        "redirects to private networks are refused without a second request",
        async () => {
          const before = hits.length;
          respond = (_req, res) => {
            res.writeHead(302, { Location: "https://169.254.169.254/private" });
            res.end();
          };
          const result = await send(target, message);
          assert(
            result.outcome === "refused" && result.status === 302 &&
              hits.length === before + 1,
            "No redirects",
          );
        },
      );
      await t.step(
        "transient statuses and bounded Retry-After remain distinct from permanent rejection",
        async () => {
          for (const status of [408, 425, 429, 500, 503]) {
            respond = (_req, res) => {
              res.writeHead(status, { "Retry-After": "9999999999" });
              res.end();
            };
            const result = await send(target, message);
            assert(
              result.outcome === "retry" && result.status === status &&
                result.retryAfterSeconds === 86400,
              "Bounded transient status",
            );
          }
          for (const status of [400, 401, 403, 404, 410]) {
            respond = (_req, res) => {
              res.writeHead(status);
              res.end();
            };
            const result = await send(target, message);
            assert(
              result.outcome === (status === 410 ? "gone" : "refused"),
              "Permanent receiver status",
            );
          }
        },
      );
      await t.step(
        "verification body is bounded and strict UTF-8; delivery never exposes it",
        async () => {
          respond = (_req, res) => {
            res.writeHead(200);
            res.end('{"challenge":"synthetic"}');
          };
          assert(
            (await send(target, message, { challenge: true }))
              .challengeResponse === '{"challenge":"synthetic"}',
            "Challenge read",
          );
          assert(
            (await send(target, message)).challengeResponse === undefined,
            "No delivery response exposure",
          );
          respond = (_req, res) => {
            res.writeHead(200);
            res.end("x".repeat(8193));
          };
          assert(
            (await send(target, message, { challenge: true })).outcome ===
              "refused",
            "Challenge bound",
          );
          respond = (_req, res) => {
            res.writeHead(200);
            res.end(new Uint8Array([0xff]));
          };
          assert(
            (await send(target, message, { challenge: true })).outcome ===
              "refused",
            "Invalid UTF-8",
          );
        },
      );
      await t.step(
        "aborted response and held challenge/header can retry without claiming rollback",
        async () => {
          respond = (_req, res) => {
            res.socket!.destroy();
          };
          assert(
            (await send(target, message)).outcome === "retry",
            "Uncertain response retry",
          );
          for (const challenge of [false, true]) {
            respond = (_req, res) => {
              if (challenge) {
                res.writeHead(200);
                res.write("pending");
              }
            };
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 100);
            const result = await send(target, message, {
              challenge,
              signal: controller.signal,
            });
            clearTimeout(timer);
            assert(
              result.outcome === "retry",
              "Cancellation covers response/headers",
            );
          }
        },
      );
      await t.step(
        "each retry resolves again; changed private DNS never receives another socket",
        async () => {
          const prior = configs.length;
          const rebound = createWebhookTransport({
            resolve: () =>
              Promise.resolve([{ address: "10.0.0.2", family: 4 }]),
            connect: mapped,
          });
          assert(
            (await rebound(target, message)).outcome === "refused" &&
              configs.length === prior,
            "Rebound private answer refused",
          );
          assert(
            resolutions === configs.length,
            "Exactly one resolver query per DNS attempt",
          );
        },
      );
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) =>
        server.close((e) => e ? reject(e) : resolve())
      );
    }
  } finally {
    await Deno.remove(directory, { recursive: true });
  }
});
