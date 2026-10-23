// One HTTP/1.1 POST on an already checked IP, upgraded to TLS using the original
// hostname. Supabase's Node HTTPS shim reconstructs a fetch URL and cannot retain
// this separation; do not replace the native socket with that shim or fetch.
export type WebhookSocket = Pick<Deno.Conn, "read" | "write" | "close">;
type Connectors = {
  tcp?: (options: Deno.ConnectOptions) => Promise<Deno.TcpConn>;
  tls?: (
    conn: Deno.TcpConn,
    options: Deno.StartTlsOptions,
  ) => Promise<Deno.TlsConn>;
};
export function abortable<T>(
  promise: Promise<T>,
  signal: AbortSignal,
): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => reject(new Error("Webhook deadline"));
    promise.then(resolve, reject).finally(() =>
      signal.removeEventListener("abort", abort)
    );
    if (signal.aborted) {
      abort();
      return;
    }
    signal.addEventListener("abort", abort, { once: true });
  });
}
const close = (socket?: WebhookSocket) => {
  try {
    socket?.close();
  } catch { /* Already transferred or closed. */ }
};
export async function connectWebhookSocket(
  address: string,
  port: number,
  hostname: string,
  signal: AbortSignal,
  connectors: Connectors = {},
): Promise<WebhookSocket> {
  if (signal.aborted) throw Error("Webhook deadline");
  let owned: Deno.Conn | Deno.TlsConn | undefined;
  const abort = () => close(owned);
  signal.addEventListener("abort", abort, { once: true });
  try {
    const tcp = (connectors.tcp ?? Deno.connect)({ hostname: address, port });
    const connected = await abortable(
      tcp.then((conn) => {
        if (signal.aborted) {
          conn.close();
          throw Error("Webhook deadline");
        }
        owned = conn;
        return conn;
      }),
      signal,
    );
    owned = connected;
    const tls = (connectors.tls ?? Deno.startTls)(connected, {
      hostname,
      alpnProtocols: ["http/1.1"],
    });
    const secured = await abortable(
      tls.then((conn) => {
        if (signal.aborted) {
          conn.close();
          throw Error("Webhook deadline");
        }
        owned = conn;
        return conn;
      }),
      signal,
    );
    // Explicitly complete CA/hostname validation before any task/secret bytes.
    const handshake = await abortable(secured.handshake(), signal);
    if (handshake.alpnProtocol && handshake.alpnProtocol !== "http/1.1") {
      throw Error("Unsupported webhook protocol");
    }
    return secured;
  } catch (error) {
    close(owned);
    throw error;
  } finally {
    signal.removeEventListener("abort", abort);
  }
}

class Limit extends Error {}
class Reader {
  buffer = new Uint8Array(0);
  wireBytes = 0;
  eof = false;
  constructor(private socket: WebhookSocket, private signal: AbortSignal) {}
  async more() {
    if (this.eof) return;
    const next = new Uint8Array(8192);
    const count = await abortable(this.socket.read(next), this.signal);
    if (count === null) {
      this.eof = true;
      return;
    }
    if (count <= 0 || (this.wireBytes += count) > 65536) {
      throw new Limit("Webhook response bound");
    }
    const joined = new Uint8Array(this.buffer.length + count);
    joined.set(this.buffer);
    joined.set(next.subarray(0, count), this.buffer.length);
    this.buffer = joined;
  }
  async line(maximum = 8192): Promise<string> {
    while (true) {
      for (let i = 0; i + 1 < this.buffer.length; i++) {
        if (this.buffer[i] === 13 && this.buffer[i + 1] === 10) {
          if (i > maximum) throw new Limit("Webhook line bound");
          const bytes = this.buffer.slice(0, i);
          this.buffer = this.buffer.slice(i + 2);
          // HTTP field syntax is ASCII; UTF-8 belongs only in the body.
          if (bytes.some((b) => b < 32 && b !== 9 || b > 126)) {
            throw Error("Invalid webhook header");
          }
          return new TextDecoder().decode(bytes);
        }
      }
      if (this.buffer.length > maximum + 1) {
        throw new Limit("Webhook line bound");
      }
      if (this.eof) throw Error("Incomplete webhook header");
      await this.more();
    }
  }
  async take(count: number) {
    while (this.buffer.length < count && !this.eof) await this.more();
    if (this.buffer.length < count) throw Error("Incomplete webhook body");
    const result = this.buffer.slice(0, count);
    this.buffer = this.buffer.slice(count);
    return result;
  }
}
export type WireResult = {
  status: number;
  retryAfter?: string;
  challengeResponse?: string;
  refused?: boolean;
};
export async function postWebhook(
  socket: WebhookSocket,
  target: { authority: string; path: string },
  headers: Record<string, string>,
  body: string,
  signal: AbortSignal,
  challenge: boolean,
): Promise<WireResult> {
  const abort = () => close(socket);
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw Error("Webhook deadline");
    const fields = {
      ...headers,
      Host: target.authority,
      Connection: "close",
      "Accept-Encoding": "identity",
    };
    const bytes = new TextEncoder().encode(
      `POST ${target.path} HTTP/1.1\r\n` +
        Object.entries(fields).map(([key, value]) => `${key}: ${value}\r\n`)
          .join("") +
        "\r\n" + body,
    );
    for (let offset = 0; offset < bytes.length;) {
      if (signal.aborted) throw Error("Webhook deadline");
      const written = await abortable(
        socket.write(bytes.subarray(offset)),
        signal,
      );
      if (written <= 0) throw Error("Incomplete webhook request");
      offset += written;
    }
    const reader = new Reader(socket, signal);
    let status = 0, budget = 0, incoming = new Map<string, string>();
    for (let interim = 0; interim <= 4; interim++) {
      const line = await reader.line();
      budget += line.length + 2;
      if (!/^HTTP\/1\.[01] [1-5][0-9]{2}(?: [\x20-\x7e]*)?$/.test(line)) {
        throw Error("Invalid webhook status");
      }
      status = Number(line.slice(9, 12));
      incoming = new Map();
      while (true) {
        const line = await reader.line();
        budget += line.length + 2;
        if (budget > 16384) throw new Limit("Webhook header bound");
        if (!line) break;
        const match = /^([!#$%&'*+.^_`|~0-9A-Za-z-]+):[ \t]*(.*)$/.exec(line);
        if (!match) throw Error("Invalid webhook header");
        const key = match[1].toLowerCase();
        if (incoming.has(key)) {
          if (
            [
              "content-length",
              "transfer-encoding",
              "retry-after",
              "content-encoding",
            ].includes(key)
          ) throw Error("Ambiguous webhook header");
          continue;
        }
        incoming.set(key, match[2].trim());
      }
      if (status >= 200) break;
      if (status === 101 || interim === 4) {
        throw Error("Unsupported webhook response");
      }
    }
    const result: WireResult = {
      status,
      retryAfter: incoming.get("retry-after"),
    };
    if (!challenge || status < 200 || status >= 300) return result;
    try {
      const encoding = incoming.get("content-encoding");
      if (encoding && encoding.toLowerCase() !== "identity") {
        return { status, refused: true };
      }
      const transfer = incoming.get("transfer-encoding"),
        length = incoming.get("content-length");
      if (
        transfer &&
        (transfer.toLowerCase() !== "chunked" || length !== undefined)
      ) throw Error("Ambiguous webhook body");
      const chunks: Uint8Array[] = [];
      let size = 0;
      const append = (bytes: Uint8Array) => {
        if ((size += bytes.length) > 8192) {
          throw new Limit("Webhook challenge bound");
        }
        chunks.push(bytes);
      };
      if (status !== 204 && status !== 205) {
        if (transfer) {
          while (true) {
            const line = await reader.line(1024);
            if (!/^[0-9a-fA-F]{1,8}(?:;[\x20-\x7e]*)?$/.test(line)) {
              throw Error("Invalid webhook chunk");
            }
            const count = parseInt(line.split(";")[0], 16);
            if (!count) {
              let trailerBudget = 0;
              while (true) {
                const trailer = await reader.line();
                trailerBudget += trailer.length + 2;
                if (trailerBudget > 8192) {
                  throw new Limit("Webhook trailer bound");
                }
                if (!trailer) break;
                if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+:/.test(trailer)) {
                  throw Error("Invalid webhook trailer");
                }
              }
              break;
            }
            if (size + count > 8192) throw new Limit("Webhook challenge bound");
            append(await reader.take(count));
            const end = await reader.take(2);
            if (end[0] !== 13 || end[1] !== 10) {
              throw Error("Invalid webhook chunk boundary");
            }
          }
        } else if (length !== undefined) {
          if (!/^\d{1,10}$/.test(length)) throw Error("Invalid webhook length");
          const count = Number(length);
          if (count > 8192) throw new Limit("Webhook challenge bound");
          append(await reader.take(count));
        } else {
          do {
            append(reader.buffer);
            reader.buffer = new Uint8Array(0);
            if (reader.eof) break;
            await reader.more();
          } while (true);
        }
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      try {
        return {
          ...result,
          challengeResponse: new TextDecoder("utf-8", { fatal: true }).decode(
            bytes,
          ),
        };
      } catch {
        return { status, refused: true };
      }
    } catch (error) {
      if (error instanceof Limit) return { status, refused: true };
      throw error;
    }
  } finally {
    signal.removeEventListener("abort", abort);
    close(socket);
  }
}
