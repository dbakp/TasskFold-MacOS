export function webhookMasterCatalog(text: string): Record<string, Uint8Array> {
  const keys: Record<string, Uint8Array> = {};
  try {
    const values = JSON.parse(text);
    if (
      !values || typeof values !== "object" || Array.isArray(values) ||
      Object.keys(values).length > 3
    ) throw Error("Invalid catalog");
    for (const [version, value] of Object.entries(values)) {
      if (
        !/^[a-z0-9-]{1,32}$/.test(version) || typeof value !== "string" ||
        !/^[a-f0-9]{64}$/.test(value)
      ) throw Error("Invalid master");
      keys[version] = Uint8Array.from(
        value.match(/../g) as string[],
        (byte) => parseInt(byte, 16),
      );
    }
    return keys;
  } catch {
    for (const key of Object.values(keys)) key.fill(0);
    return {};
  }
}
