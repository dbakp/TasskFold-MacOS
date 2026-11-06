// Compile a pinned upstream pg_cron in an owned disposable container. No new
// Docker image or build cache; only the extension artifacts mount into the fixture.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, postgresImage } from "./postgres-fixture.mjs";
const exec = promisify(execFile);
export const cronSource = {
  version: "1.6.8",
  commit: "5cedfa472ccc83567aa23ec645925ed8489a7797",
  sha256: "cba185da9308d2c624ded35a596937ce391badd60665ab6badc55bd8e78a1e94",
  url:
    "https://codeload.github.com/citusdata/pg_cron/tar.gz/5cedfa472ccc83567aa23ec645925ed8489a7797",
};
export async function createCronPostgresFixture(
  { backgroundWorkers = false, advisors = false } = {},
) {
  const directory = await mkdtemp(join(tmpdir(), "taskfold-email-cron-"));
  const name = "taskfold-email-cron-build-" + randomUUID().slice(0, 8),
    label = randomUUID();
  let created = false, pg;
  const docker = (args, timeout = 15000) =>
    exec("docker", args, { timeout, maxBuffer: 256 * 1024 });
  async function removeBuilder() {
    if (!created) return;
    const state = JSON.parse((await docker(["inspect", name])).stdout)[0];
    if (state.Config.Labels["com.taskfold.fixture"] !== label) {
      throw new Error("Cron fixture ownership mismatch");
    }
    await docker(["rm", "--force", name]);
    created = false;
  }
  try {
    const response = await fetch(cronSource.url, {
      signal: AbortSignal.timeout(20000),
    });
    if (!response.ok) throw new Error("Unable to read pinned pg_cron source");
    const reader = response.body.getReader();
    let length = 0;
    const parts = [];
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        length += value.length;
        if (length > 1024 * 1024) throw new Error("Oversize pg_cron source");
        parts.push(value);
      }
    } finally {
      await reader.cancel();
    }
    const source = Buffer.concat(parts);
    if (
      createHash("sha256").update(source).digest("hex") !== cronSource.sha256
    ) throw new Error("pg_cron source fingerprint mismatch");
    const archive = join(directory, "source.tar.gz");
    await writeFile(archive, source);
    await docker([
      "create",
      "--name",
      name,
      "--label",
      "com.taskfold.fixture=" + label,
      "--memory",
      "512m",
      "--cpus",
      "1",
      "--entrypoint",
      "sh",
      postgresImage,
      "-c",
      "set -e; apk add --no-cache build-base; mkdir /tmp/pg_cron; tar -xzf /tmp/source.tar.gz -C /tmp/pg_cron --strip-components=1; make -C /tmp/pg_cron with_llvm=no; make -C /tmp/pg_cron install with_llvm=no",
    ]);
    created = true;
    await docker(["cp", archive, name + ":/tmp/source.tar.gz"]);
    await docker(["start", "--attach", name], 120000);
    const state = JSON.parse((await docker(["inspect", name])).stdout)[0];
    if (state.State.ExitCode !== 0) {
      throw new Error("Pinned pg_cron build failed");
    }
    await docker([
      "cp",
      name + ":/usr/local/lib/postgresql/pg_cron.so",
      join(directory, "pg_cron.so"),
    ]);
    await docker([
      "cp",
      name + ":/usr/local/share/postgresql/extension",
      join(directory, "extension"),
    ]);
    await removeBuilder();
    await rm(archive);
    pg = await createPostgresFixture({
      cronDirectory: directory,
      advisors,
      cronBackgroundWorkers: backgroundWorkers,
    });
    return {
      ...pg,
      cronSource,
      librarySha256: createHash("sha256").update(
        await readFile(join(directory, "pg_cron.so")),
      ).digest("hex"),
      close: async () => {
        const removed = await pg.close();
        await rm(directory, { recursive: true });
        return removed;
      },
    };
  } catch (e) {
    if (pg) await pg.close();
    await removeBuilder();
    await rm(directory, { recursive: true, force: true });
    throw e;
  }
}
