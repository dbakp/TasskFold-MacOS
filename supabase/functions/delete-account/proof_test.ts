import { issueProof, verifyProof } from "./proof.ts";
const account = "f084cafe-0000-4000-8000-000000000001";
const origin = "https://removal.test", now = 1_800_000_000_000;
const old = {
  id: "f084cafe-0000-4000-8000-000000000020",
  key: btoa("a".repeat(32)),
};
const next = {
  id: "f084cafe-0000-4000-8000-000000000021",
  key: btoa("b".repeat(32)),
};
const read = (id: string | null) =>
  Promise.resolve(
    id === old.id ? old : id === null || id === next.id ? next : null,
  );
const assert = (value: unknown) => {
  if (!value) throw new Error("Proof assertion failed");
};
Deno.test("status proof survives elapsed years and retained-key rotation, but not revocation", async () => {
  const value = await issueProof(
    account,
    origin,
    now,
    () => Promise.resolve(old),
  );
  assert(
    await verifyProof(value, origin, now + 10 * 365 * 86400000, read) ===
      account,
  );
  assert(
    await verifyProof(value, origin, now, () => Promise.resolve(null)) === null,
  );
  assert(await verifyProof(value, "https://another.test", now, read) === null);
  const rotated = await issueProof(account, origin, now, read);
  assert(await verifyProof(rotated, origin, now, read) === account);
  assert(
    await verifyProof(
      value,
      origin,
      now,
      () => Promise.resolve({ ...old, key: next.key }),
    ) === null,
  );
});
Deno.test("malformed, altered, noncanonical and future claims cannot verify", async () => {
  const value = await issueProof(account, origin, now, read);
  for (
    const bad of [
      "",
      value + "=",
      value + "x",
      "a.b",
      "x".repeat(2049),
      value.replace(account, "other") + " ",
    ]
  ) {
    assert(await verifyProof(bad, origin, now, read) === null);
  }
  const [payload, signature] = value.split(".");
  const claims = JSON.parse(
    atob(payload.replaceAll("-", "+").replaceAll("_", "/")),
  );
  for (
    const altered of [
      { ...claims, account: old.id },
      { ...claims, scope: "delete" },
      { ...claims, extra: true },
      { ...claims, issued: 0 },
    ]
  ) {
    const changed = btoa(JSON.stringify(altered)).replaceAll("+", "-")
      .replaceAll("/", "_").replace(/=+$/, "");
    assert(
      await verifyProof(changed + "." + signature, origin, now, read) === null,
    );
  }
  const future = await issueProof(account, origin, now + 301000, read);
  assert(await verifyProof(future, origin, now, read) === null);
});
Deno.test("trusted key-service failures propagate as retryable errors", async () => {
  const value = await issueProof(account, origin, now, read);
  for (
    const reader of [
      () => Promise.reject(new Error("outage")),
      () => Promise.resolve({ id: next.id, key: "broken" }),
    ]
  ) {
    let failed = false;
    try {
      await verifyProof(value, origin, now, reader);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});
