// Real pinned Storage API and ephemeral file backend, attached only to an owned
// PostgreSQL fixture. No hosted credentials, host mounts or persistent volumes.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
const exec = promisify(execFile);
export const storageImage =
  "supabase/storage-api@sha256:0194c53a03977e8ca0194636a27172158b39e3ae7a5e12da1dca5717086dd849";
export async function createStorageProvider(pg) {
  const { name: database, label: owner } = pg.containerIdentity;
  const suffix = randomUUID().slice(0, 8),
    name = "taskfold-storage-" + suffix,
    network = "taskfold-storage-net-" + suffix,
    label = randomUUID();
  const secret = randomBytes(48).toString("hex");
  const token = (claims) => {
    const h = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" }))
        .toString("base64url"),
      p = Buffer.from(
        JSON.stringify({
          iss: "taskfold-storage-fixture",
          iat: Math.floor(Date.now() / 1000),
          exp: Math.floor(Date.now() / 1000) + 3600,
          ...claims,
        }),
      ).toString("base64url");
    return h + "." + p + "." +
      createHmac("sha256", secret).update(h + "." + p).digest("base64url");
  };
  const service = token({ role: "service_role" }),
    anon = token({ role: "anon" });
  let networkCreated = false, created = false, connected = false, url;
  const inspect = async (target) =>
    JSON.parse(
      (await exec("docker", ["inspect", target], { timeout: 5000 })).stdout,
    )[0];
  async function close() {
    if (created) {
      const state = await inspect(name);
      if (state.Config.Labels["com.taskfold.storage.fixture"] !== label) {
        throw Error("Storage ownership mismatch");
      }
      await exec("docker", ["rm", "--force", name], { timeout: 10000 });
      created = false;
    }
    if (connected) {
      const state = await inspect(database);
      if (state.Config.Labels["com.taskfold.fixture"] !== owner) {
        throw Error("Database ownership mismatch");
      }
      await exec("docker", ["network", "disconnect", network, database], {
        timeout: 5000,
      });
      connected = false;
    }
    if (networkCreated) {
      const state = JSON.parse(
        (await exec("docker", ["network", "inspect", network], {
          timeout: 5000,
        })).stdout,
      )[0];
      if (state.Labels["com.taskfold.storage.fixture"] !== label) {
        throw Error("Network ownership mismatch");
      }
      await exec("docker", ["network", "rm", network], { timeout: 5000 });
      networkCreated = false;
    }
    return true;
  }
  async function request(path, init = {}, authorization = service) {
    if (!url || !path.startsWith("/") || path.startsWith("//")) {
      throw Error("Local Storage path required");
    }
    const abort = new AbortController(),
      timer = setTimeout(() => abort.abort(), 15000);
    try {
      const response = await fetch(url + path, {
        ...init,
        redirect: "error",
        signal: abort.signal,
        headers: {
          ...init.headers,
          Authorization: "Bearer " + authorization,
          apikey: authorization,
        },
      });
      const chunks = [];
      let length = 0;
      const reader = response.body?.getReader();
      if (reader) {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          if ((length += value.length) > 5308416) {
            await reader.cancel();
            throw Error("Bounded Storage response exceeded");
          }
          chunks.push(value);
        }
      }
      return new Response(length ? Buffer.concat(chunks) : null, {
        status: response.status,
        headers: response.headers,
      });
    } finally {
      clearTimeout(timer);
    }
  }
  try {
    const db = await inspect(database);
    if (db.Config.Labels["com.taskfold.fixture"] !== owner) {
      throw Error("Database ownership mismatch");
    }
    await exec("docker", ["image", "inspect", storageImage], { timeout: 5000 });
    await exec("docker", [
      "network",
      "create",
      "--label",
      "com.taskfold.storage.fixture=" + label,
      network,
    ], { timeout: 5000 });
    networkCreated = true;
    await exec("docker", ["network", "connect", network, database], {
      timeout: 5000,
    });
    connected = true;
    // These synthetic fixture roles mirror the provider's ordinary role setup.
    await pg.raw("alter role service_role bypassrls");
    const env = {
      DATABASE_URL: "postgresql://postgres@" + database + ":5432/postgres",
      AUTH_JWT_SECRET: secret,
      AUTH_JWT_ALGORITHM: "HS256",
      DB_INSTALL_ROLES: "true",
      DB_SUPER_USER: "postgres",
      STORAGE_BACKEND: "file",
      STORAGE_FILE_BACKEND_PATH: "/var/lib/storage",
      TENANT_ID: "taskfold-fixture",
      REGION: "local",
      GLOBAL_S3_BUCKET: "taskfold-fixture",
      FILE_SIZE_LIMIT: "5242880",
      UPLOAD_FILE_SIZE_LIMIT: "5242880",
      SERVER_PORT: "5000",
      SERVER_HOST: "0.0.0.0",
      PG_QUEUE_ENABLE: "false",
      ENABLE_IMAGE_TRANSFORMATION: "false",
      IMAGE_TRANSFORMATION_ENABLED: "false",
      LOG_LEVEL: "error",
    };
    await exec("docker", [
      "run",
      "--detach",
      "--rm",
      "--name",
      name,
      "--label",
      "com.taskfold.storage.fixture=" + label,
      "--network",
      network,
      "--publish",
      "127.0.0.1::5000",
      "--memory",
      "768m",
      "--cpus",
      "1",
      "--tmpfs",
      "/var/lib/storage:rw,size=64m,mode=1777",
      "--tmpfs",
      "/tmp:rw,size=64m,mode=1777",
      ...Object.entries(env).flatMap(([k, v]) => ["-e", k + "=" + v]),
      storageImage,
    ], { timeout: 15000 });
    created = true;
    const info = await inspect(name);
    const port = Number(info.NetworkSettings.Ports["5000/tcp"]?.[0]?.HostPort);
    if (!Number.isInteger(port) || port < 1) {
      throw Error(
        "Storage loopback port missing; state=" + JSON.stringify(info.State),
      );
    }
    url = "http://127.0.0.1:" + port;
    let ready = false;
    for (let n = 0; n < 100; n++) {
      try {
        const response = await request("/status");
        await response.arrayBuffer();
        if (response.ok) {
          ready = true;
          break;
        }
      } catch {
        /* Storage may still be starting; the bounded probe will retry. */
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    if (!ready) {
      const logs = (await exec("docker", ["logs", "--tail", "30", name], {
        timeout: 5000,
      })).stdout;
      throw Error("Owned Storage did not initialize: " + logs.slice(-6000));
    }
    return { request, token, service, anon, url, close, image: storageImage };
  } catch (error) {
    await close();
    throw error;
  }
}
