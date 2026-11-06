// A pg_net queue entry must never contain the reusable worker credential.
export async function admitScheduledWebhook(
  header: string | null,
  config: { url: string; serviceKey: string; workerToken: string },
  send: (request: Request) => Promise<Response> = fetch,
): Promise<boolean> {
  const match =
    /^Taskfold-Schedule ([0-9]{10})\.([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\.([a-f0-9]{64})$/
      .exec(header ?? "");
  const project = /^https:\/\/([a-z]{20})\.supabase\.co$/.exec(config.url)?.[1];
  if (!match || !project || !/^[a-f0-9]{64}$/.test(config.workerToken)) {
    return false;
  }
  const [, issued, nonce, proof] = match,
    age = Date.now() / 1000 - Number(issued);
  if (age > 90 || age < -5) return false;
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(config.workerToken),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      "HMAC",
      key,
      Uint8Array.from(proof.match(/../g)!, (s) => parseInt(s, 16)),
      new TextEncoder().encode(
        `taskfold.webhook.schedule.v1.${issued}.${nonce}.${project}`,
      ),
    );
    if (!valid) return false;
    const response = await send(
      new Request(
        config.url + "/rest/v1/rpc/taskfold_webhook_schedule_admit",
        {
          method: "POST",
          redirect: "error",
          credentials: "omit",
          cache: "no-store",
          signal: AbortSignal.timeout(6000),
          headers: {
            "Content-Type": "application/json",
            apikey: config.serviceKey,
            Authorization: "Bearer " + config.serviceKey,
          },
          body: JSON.stringify({ _nonce: nonce, _issued: Number(issued) }),
        },
      ),
    );
    // The fixed service RPC returns one JSON boolean, never task content.
    if (!response.ok || !response.body) return false;
    const reader = response.body.getReader();
    let size = 0, text = "";
    try {
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        if ((size += part.value.length) > 16) return false;
        text += new TextDecoder().decode(part.value);
      }
    } finally {
      await reader.cancel().catch(() => {});
      reader.releaseLock();
    }
    return text.trim() === "true";
  } catch {
    return false;
  }
}
