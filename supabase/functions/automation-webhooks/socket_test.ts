import {
  connectWebhookSocket,
  postWebhook,
  type WebhookSocket,
} from "./socket.ts";
const encode = (value: string) => new TextEncoder().encode(value);
const assert = (ok: unknown, label: string) => {
  if (!ok) throw Error(label);
};
async function wire(
  response: string | Uint8Array,
  challenge = true,
  split = 1,
) {
  const bytes = typeof response === "string" ? encode(response) : response;
  let offset = 0, closed = false, written = 0;
  const socket: WebhookSocket = {
    read: (buffer) => {
      const length = Math.min(split, buffer.length, bytes.length - offset);
      if (!length) return Promise.resolve(null);
      buffer.set(bytes.subarray(offset, offset + length));
      offset += length;
      return Promise.resolve(length);
    },
    write: (buffer) => {
      written += buffer.length;
      return Promise.resolve(buffer.length);
    },
    close: () => {
      closed = true;
    },
  };
  try {
    return await postWebhook(
      socket,
      { authority: "receiver.example", path: "/" },
      { "Content-Length": "2" },
      "{}",
      new AbortController().signal,
      challenge,
    );
  } finally {
    assert(
      closed && written > 0,
      "Every response closes its own one-shot socket",
    );
  }
}
async function rejects(response: string) {
  let rejected = false;
  try {
    await wire(response);
  } catch {
    rejected = true;
  }
  assert(rejected, "Malformed/ambiguous response must reject");
}
Deno.test("webhook wire parser reads fragmented UTF-8, interim headers, chunks and close-delimited challenges", async () => {
  const body = "Déjà 📝";
  const content = encode(body).length;
  assert(
    (await wire(`HTTP/1.1 200 OK\r\nContent-Length: ${content}\r\n\r\n${body}`))
      .challengeResponse === body,
    "Fragmented Content-Length UTF-8",
  );
  assert(
    (await wire(
      `HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n${
        content.toString(16)
      };extension=yes\r\n${body}\r\n0\r\nX-Fixture: end\r\n\r\n`,
    )).challengeResponse === body,
    "Interim/chunked/trailers",
  );
  assert(
    (await wire(`HTTP/1.0 200 OK\r\n\r\n${body}`)).challengeResponse === body,
    "Close-delimited UTF-8",
  );
  assert(
    (await wire("HTTP/1.1 204 No Content\r\n\r\n")).challengeResponse === "",
    "204 has no challenge body",
  );
});
Deno.test("webhook wire parser refuses conflicting framing, malformed status/chunks and truncated bodies", async () => {
  for (
    const response of [
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
      "HTTP/1.1 200 OK\r\n Content-Length: 0\r\n\r\n",
      "HTTP/1.1 200 OK\nContent-Length: 0\n\n",
      "HTTP/2 200\r\n\r\n",
      "HTTP/1.1 101 Switching Protocols\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nshort",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nxZZ0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\ninvalid trailer\r\n\r\n",
      "HTTP/1.1 100 Continue\r\n\r\n".repeat(5) + "HTTP/1.1 200 OK\r\n\r\n",
    ]
  ) await rejects(response);
});
Deno.test("webhook wire parser bounds headers, challenge bodies, trailers and chunk framing", async () => {
  await rejects("HTTP/1.1 200 OK\r\nX-Long: " + "x".repeat(8200) + "\r\n\r\n");
  await rejects(
    "HTTP/1.1 200 OK\r\n" +
      Array.from({ length: 40 }, (_, i) => `X-${i}: ${"x".repeat(500)}\r\n`)
        .join("") +
      "\r\n",
  );
  for (
    const response of [
      "HTTP/1.1 200 OK\r\nContent-Length: 8193\r\n\r\n",
      "HTTP/1.1 200 OK\r\n\r\n" + "x".repeat(8193),
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffff\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" +
      ("X-End: " + "x".repeat(500) + "\r\n").repeat(20) + "\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
      ("1;" + "x".repeat(1000) + "\r\nx\r\n").repeat(70) + "0\r\n\r\n",
    ]
  ) {
    assert(
      (await wire(response, true, 8192)).refused === true,
      "Bounded challenge refusal",
    );
  }
  assert(
    (await wire("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n")).refused,
    "No decompression or opaque challenge",
  );
  assert(
    (await wire("HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n", false))
      .status === 200,
    "Delivery acknowledgement does not read recipient content",
  );
});
Deno.test("webhook wire deadline closes a connection whose response never arrives", async () => {
  let closed = false;
  const controller = new AbortController();
  const socket: WebhookSocket = {
    read: () => new Promise(() => {}),
    write: (bytes) => Promise.resolve(bytes.length),
    close: () => {
      closed = true;
    },
  };
  const attempt = postWebhook(
    socket,
    { authority: "receiver.example", path: "/" },
    { "Content-Length": "2" },
    "{}",
    controller.signal,
    true,
  );
  controller.abort();
  let rejected = false;
  try {
    await attempt;
  } catch {
    rejected = true;
  }
  assert(
    rejected && closed,
    "Abort is bounded without waiting for an untrusted read",
  );
});

Deno.test("webhook cancellation before connection does not dial a socket", async () => {
  const controller = new AbortController();
  controller.abort();
  let started = false, rejected = false;
  try {
    await connectWebhookSocket(
      "1.1.1.1",
      443,
      "receiver.example",
      controller.signal,
      {
        tcp: () => {
          started = true;
          throw Error("Must not dial");
        },
      },
    );
  } catch {
    rejected = true;
  }
  assert(
    rejected && !started,
    "Already cancelled connection creates no socket",
  );
});
