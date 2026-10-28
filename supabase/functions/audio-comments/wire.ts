// Canonical native publication v1. Container checks are not a full AAC decoder;
// native playback must still perform complete AVFoundation decoding.
export const maximumAudioBytes = 8_000_000;
export const maximumEnvelopeBytes = Math.ceil(maximumAudioBytes / 3) * 4 +
  64_000;
export const bucket = "taskfold-audio-v1";
export type Row = Record<string, unknown>;
export const object = (value: unknown): Row => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw Error("shape");
  }
  return value as Row;
};
export const exact = (row: Row, keys: string[]) => {
  if (Object.keys(row).sort().join(",") !== [...keys].sort().join(",")) {
    throw Error("shape");
  }
};
export const identity = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value) &&
  value !== "00000000-0000-0000-0000-000000000000";
export function target(value: unknown) {
  const row = object(value);
  exact(row, ["task_id", "task_generation", "project_id"]);
  if (
    !identity(row.task_id) || !identity(row.task_generation) ||
    !(row.project_id === null || identity(row.project_id))
  ) throw Error("target");
  return row;
}
export function descriptor(value: unknown) {
  const row = object(value);
  exact(row, ["version", "mime_type", "byte_count", "duration_ms", "sha256"]);
  if (
    row.version !== 1 || row.mime_type !== "audio/mp4" ||
    !Number.isInteger(row.byte_count) || Number(row.byte_count) < 1 ||
    Number(row.byte_count) > maximumAudioBytes ||
    !Number.isInteger(row.duration_ms) || Number(row.duration_ms) < 1 ||
    Number(row.duration_ms) > 120_000 || typeof row.sha256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(row.sha256)
  ) throw Error("audio");
  return row;
}
export function publication(value: unknown) {
  const row = object(value);
  exact(row, [
    "version",
    "account",
    "operation_id",
    "comment_id",
    "asset_id",
    "target",
    "caption",
    "audio",
  ]);
  if (
    row.version !== 1 ||
    ![row.account, row.operation_id, row.comment_id, row.asset_id].every(
      identity,
    ) || typeof row.caption !== "string" ||
    new TextEncoder().encode(row.caption).length > 4000 ||
    row.caption.includes("\0") ||
    new TextDecoder().decode(new TextEncoder().encode(row.caption)) !==
      row.caption
  ) throw Error("intent");
  target(row.target);
  descriptor(row.audio);
  return row;
}
export function path(row: Row) {
  const t = target(row.target);
  if (!identity(row.asset_id)) throw Error("asset");
  return `audio-comments/v1/${t.task_id}/${t.task_generation}/${row.asset_id}.m4a`;
}
const date = (value: unknown) =>
  typeof value === "string" && value.length <= 40 &&
  /^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
  Number.isFinite(Date.parse(value));
export function receipt(value: unknown, actor: string, expected?: Row) {
  const row = object(value);
  exact(row, [
    "protocol",
    "account",
    "operation_id",
    "comment_id",
    "asset_id",
    "author_id",
    "target",
    "caption",
    "audio",
    "state",
    "reserved_at",
    "expires_at",
    "published_at",
    "bucket",
    "object_name",
  ]);
  if (
    row.protocol !== 1 || row.account !== actor ||
    ![row.operation_id, row.comment_id, row.asset_id].every(identity) ||
    !(row.author_id === null || identity(row.author_id)) ||
    !["pending", "published"].includes(String(row.state)) ||
    !date(row.reserved_at) || !date(row.expires_at) ||
    !(row.published_at === null && row.state === "pending" ||
      date(row.published_at) && row.state === "published") ||
    row.bucket !== bucket || row.object_name !== path(row)
  ) throw Error("receipt");
  const native = publication({
    version: 1,
    account: actor,
    operation_id: row.operation_id,
    comment_id: row.comment_id,
    asset_id: row.asset_id,
    target: row.target,
    caption: row.caption,
    audio: row.audio,
  });
  if (expected && key(native) !== key(expected)) {
    throw Error("mismatched receipt");
  }
  return row;
}
export function key(value: unknown): string {
  if (Array.isArray(value)) return "[" + value.map(key).join(",") + "]";
  if (value && typeof value === "object") {
    return "{" + Object.keys(value).sort().map((k) =>
      JSON.stringify(k) + ":" + key((value as Row)[k])
    ).join(",") + "}";
  }
  return JSON.stringify(value);
}
export function publicReceipt(row: Row) {
  return Object.fromEntries(
    Object.entries(row).filter(([key]) =>
      !["bucket", "object_name"].includes(key)
    ),
  );
}
export function audio64(value: unknown) {
  if (
    typeof value !== "string" ||
    value.length > Math.ceil(maximumAudioBytes / 3) * 4 ||
    value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)
  ) throw Error("base64");
  const decoded = atob(value);
  if (!decoded.length || decoded.length > maximumAudioBytes) {
    throw Error("size");
  }
  return Uint8Array.from(decoded, (c) => c.charCodeAt(0));
}
export async function digest(bytes: Uint8Array) {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", bytes as BufferSource),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}
type Atom = { kind: string; start: number; end: number };
export function encodedMilliseconds(bytes: Uint8Array) {
  if (!bytes.length || bytes.length > maximumAudioBytes) throw Error("size");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const number = (offset: number, size: number, start: number, end: number) => {
    if (offset < start || offset > end - size) throw Error("truncated");
    let n = 0;
    for (let i = 0; i < size; i++) {
      n = n * 256 + view.getUint8(offset + i);
      if (!Number.isSafeInteger(n)) throw Error("size");
    }
    return n;
  };
  const text = (start: number, end: number) =>
    new TextDecoder().decode(bytes.subarray(start, end));
  const atoms = (start: number, end: number) => {
    const result: Atom[] = [];
    let cursor = start;
    while (cursor < end) {
      if (result.length >= 4096) throw Error("atoms");
      let size = number(cursor, 4, start, end), header = 8;
      const kind = text(cursor + 4, cursor + 8);
      if (size === 1) {
        header = 16;
        size = number(cursor + 8, 8, start, end);
      }
      if (size === 0) size = end - cursor;
      if (size < header || size > end - cursor) throw Error("atom");
      result.push({ kind, start: cursor + header, end: cursor + size });
      cursor += size;
    }
    return result;
  };
  const one = (rows: Atom[], kind: string) => {
    const matches = rows.filter((a) => a.kind === kind);
    if (matches.length !== 1) throw Error("track");
    return matches[0];
  };
  const children = (a: Atom) => atoms(a.start, a.end);
  const duration = (a: Atom) => {
    const version = number(a.start, 1, a.start, a.end);
    if (version > 1) throw Error("duration");
    const offset = a.start + (version === 0 ? 12 : 20);
    const scale = number(offset, 4, a.start, a.end),
      ticks = number(offset + 4, version === 0 ? 4 : 8, a.start, a.end);
    if (scale < 1 || ticks < 1 || ticks > 121000 * scale / 1000) {
      throw Error("duration");
    }
    return Math.ceil(ticks * 1000 / scale);
  };
  const top = atoms(0, bytes.length), brand = one(top, "ftyp");
  if (
    brand.end - brand.start < 8 || (brand.end - brand.start) % 4 !== 0 ||
    top.some((a) => a.kind === "moof") ||
    !top.some((a) => a.kind === "mdat" && a.end > a.start)
  ) throw Error("container");
  let supported = false;
  for (let i = brand.start; i < brand.end; i += 4) {
    if (
      i !== brand.start + 4 &&
      ["M4A ", "isom", "iso2", "mp41", "mp42"].includes(text(i, i + 4))
    ) supported = true;
  }
  if (!supported) throw Error("brand");
  const movie = children(one(top, "moov")),
    movieMS = duration(one(movie, "mvhd"));
  const media = children(one(children(one(movie, "trak")), "mdia")),
    trackMS = duration(one(media, "mdhd")),
    handler = one(media, "hdlr");
  if (
    handler.end - handler.start < 12 ||
    text(handler.start + 8, handler.start + 12) !== "soun" ||
    Math.abs(trackMS - movieMS) > 1000
  ) throw Error("audio track");
  const sample = one(
    children(one(children(one(media, "minf")), "stbl")),
    "stsd",
  );
  if (number(sample.start + 4, 4, sample.start, sample.end) !== 1) {
    throw Error("codec");
  }
  const entries = atoms(sample.start + 8, sample.end),
    entry = one(entries, "mp4a");
  if (entries.length !== 1 || entry.end - entry.start < 28) {
    throw Error("codec");
  }
  return Math.max(movieMS, trackMS);
}
export async function verifyAudio(bytes: Uint8Array, value: unknown) {
  const d = descriptor(value),
    encoded = encodedMilliseconds(bytes),
    hash = await digest(bytes);
  if (
    bytes.length !== d.byte_count || hash !== d.sha256 ||
    Math.abs(encoded - Number(d.duration_ms)) > 1000
  ) throw Error("integrity");
  return { sha256: hash, byteCount: bytes.length };
}
