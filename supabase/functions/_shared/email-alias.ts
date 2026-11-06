// Internal version-1 recipient contract, shared with the native vault. This does
// not attest a provider, sender or recipient and must follow signature checks.
export function emailAliasDomain(value: string | undefined): string | null {
  // A 64-byte local part plus @ leaves 189 bytes in a 254-byte mailbox.
  if (!value || value.length > 189 || value !== value.toLowerCase()) {
    return null;
  }
  const labels = value.split(".");
  if (labels.length < 2 || !/^[a-z]{2,63}$/.test(labels.at(-1)!)) return null;
  return labels.every((p) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(p))
    ? value
    : null;
}
export async function emailAliasHash(address: string): Promise<string> {
  const parts = address.split("@");
  if (
    parts.length !== 2 || !/^[a-f0-9]{64}$/.test(parts[0]) ||
    !emailAliasDomain(parts[1])
  ) throw Error("Invalid email capture address");
  const bytes = new TextEncoder().encode(
    JSON.stringify(["taskfold-email-alias", 1, address]),
  );
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}
