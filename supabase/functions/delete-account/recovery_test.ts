import {
  issueRecoveryProof,
  recoveryRequest,
  verifyRecoveryProof,
} from "./recovery.ts";
import { verifyProof } from "./proof.ts";
import { createHandler } from "./handler.ts";
import { createRemovalRepairHandler } from "../account-removal-repair/handler.ts";
const account = "f086cafe-0000-4000-8000-000000000001",
  command = "f086cafe-0000-4000-8000-000000000002";
const origin = "https://recovery.test",
  token = "expired-original-token",
  now = 1700000000000;
const hash = [
  ...new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
  ),
].map((x) => x.toString(16).padStart(2, "0")).join("");
const request = recoveryRequest(
  {
    format: "taskfold-account-removal-recovery-request",
    version: 1,
    origin,
    account,
    command,
    authorization_hash: hash,
  },
  origin,
  account,
);
const key = {
  id: "f086cafe-0000-4000-8000-000000000003",
  key: btoa("s".repeat(32)),
};
const config = {
  url: origin,
  serviceKey: "synthetic-server-key",
  maintenanceKey: "synthetic-operator-key-never-in-clients",
  enabled: true,
};
const assert = (v: unknown) => {
  if (!v) throw Error("assertion");
};
const proof = await issueRecoveryProof(
  request,
  now,
  () => Promise.resolve(key),
);
function fixture(
  { absent = true, present = false, revoked = false, outage = false } = {},
) {
  const calls: string[] = [];
  const send = async (r: Request) => {
    const path = new URL(r.url).pathname;
    const body = await r.json();
    if (path.endsWith("_absent")) assert(body._account === account);
    calls.push(r.method + " " + path);
    assert(r.headers.get("Authorization") === "Bearer " + config.serviceKey);
    assert(r.redirect === "error");
    if (path.endsWith("_proof_key")) {
      if (outage) throw Error("PRIVATE KEY");
      return Response.json(revoked ? null : key);
    }
    if (path.endsWith("_absent")) return Response.json(absent);
    if (path.endsWith("_repair_manifest")) {
      return Response.json(
        present ? { code: "28000" } : { account, files: [], more: false },
        { status: present ? 400 : 200 },
      );
    }
    throw Error("Recovery must not call Auth, destructive receipts or Storage");
  };
  const client = createHandler(config, { send, now: () => now });
  const operator = createRemovalRepairHandler(config, { send, now: () => now });
  const status = (p = proof, t = token, c = command) =>
    client(
      new Request("https://edge.test", {
        method: "POST",
        headers: {
          Authorization: "Bearer " + t,
          "X-Taskfold-Account-Removal": "2",
          "X-Taskfold-Account-Removal-Proof": p,
          "X-Taskfold-Account-Removal-Command": c,
        },
        body: "{}",
      }),
    );
  const certify = (r: unknown = request) =>
    operator(
      new Request("https://edge.test", {
        method: "POST",
        headers: { "X-Taskfold-Removal-Repair": config.maintenanceKey },
        body: JSON.stringify({
          action: "certify",
          account,
          request: r,
          confirmation: account,
        }),
      }),
    );
  return { calls, status, certify };
}
Deno.test("certificate is bound to origin account command and original authorization hash", async () => {
  assert(
    JSON.stringify(
      await verifyRecoveryProof(proof, origin, now, () => Promise.resolve(key)),
    ) === JSON.stringify({ account, command, authorization_hash: hash }),
  );
  assert(
    await verifyRecoveryProof(
      proof,
      "https://other.test",
      now,
      () => Promise.resolve(key),
    ) === null,
  );
  assert(
    await verifyProof(proof, origin, now, () => Promise.resolve(key)) === null,
  );
});
Deno.test("absence certificate returns an identity bound acknowledgement without deletion authority", async () => {
  const f = fixture(), r = await f.status();
  assert(r.status === 200);
  const body = await r.json();
  assert(
    body.deleted && body.account === account && body.command === command &&
      body.authorization_hash === hash,
  );
  assert(
    f.calls.length === 2 &&
      f.calls.every((c) => c.endsWith("_proof_key") || c.endsWith("_absent")),
  );
});
Deno.test("existing Auth or residual files refuse recovery even with a valid original login or receipt", async () => {
  const f = fixture({ absent: false }), r = await f.status();
  assert(r.status === 409);
  assert(
    !f.calls.some((c) =>
      c.includes("_status") || c.includes("/auth/") || c.includes("/storage/")
    ),
  );
});
Deno.test("wrong command and original bearer cannot be recovered with another certificate", async () => {
  for (
    const [t, c] of [["other-token", command], [
      token,
      "f086cafe-0000-4000-8000-000000000004",
    ], [token, ""]]
  ) {
    const f = fixture();
    assert((await f.status(proof, t, c)).status === 401);
    assert(f.calls.every((c) => c.endsWith("_proof_key")));
  }
});
Deno.test("revoked malformed and unavailable signing keys never confirm a certificate", async () => {
  assert((await fixture({ revoked: true }).status()).status === 401);
  assert((await fixture({ outage: true }).status()).status === 503);
  const f = fixture();
  assert((await f.status(proof.slice(0, -2) + "aa")).status === 401);
});
Deno.test("operator only issues a recovery file after current Auth and file absence", async () => {
  const f = fixture(), r = await f.certify();
  assert(r.status === 200);
  const file = await r.json();
  assert(
    file.format === "taskfold-account-removal-recovery" &&
      file.request.command === command && typeof file.proof === "string",
  );
  assert(
    await verifyRecoveryProof(
      file.proof,
      origin,
      now,
      () => Promise.resolve(key),
    ) !== null,
  );
  assert(f.calls.every((c) => !c.startsWith("DELETE")));
  for (const options of [{ present: true }, { absent: false }]) {
    const f = fixture(options);
    assert((await f.certify()).status === 409);
    assert(!f.calls.some((c) => c.endsWith("_proof_key")));
  }
});
Deno.test("operator refuses foreign future extra and raw credential request fields before I/O", async () => {
  for (
    const changed of [
      { ...request, origin: "https://other.test" },
      { ...request, account: "f086cafe-0000-4000-8000-000000000004" },
      { ...request, version: 2 },
      { ...request, authorization: "private" },
      { ...request, command: "not-a-command" },
    ]
  ) {
    const f = fixture();
    assert((await f.certify(changed)).status === 400);
    assert(f.calls.length === 0);
  }
});
