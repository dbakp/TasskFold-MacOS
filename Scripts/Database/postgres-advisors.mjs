// Read-only official advisors on an opt-in owned synthetic fixture. The fixture
// publishes only an ephemeral loopback port, and removes it with the container.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const exec = promisify(execFile);
export async function runPostgresAdvisors(container, ownershipLabel) {
  assert(/^taskfold-task-pg-[0-9a-f]{8}$/.test(container));
  const state =
    JSON.parse((await exec("docker", ["inspect", container])).stdout)[0];
  assert.equal(state.Config.Labels["com.taskfold.fixture"], ownershipLabel);
  const bindings = state.NetworkSettings.Ports["5432/tcp"];
  assert(bindings?.length === 1 && bindings[0].HostIp === "127.0.0.1");
  const port = bindings[0].HostPort;
  assert(/^[0-9]{1,5}$/.test(port));
  const result = await exec("supabase", [
    "db",
    "advisors",
    "--db-url",
    "postgresql://postgres@127.0.0.1:" + port + "/postgres?sslmode=disable",
    "--type",
    "all",
    "--fail-on",
    "none",
    "--output",
    "json",
  ], { timeout: 45000, maxBuffer: 4 * 1024 * 1024 });
  return {
    ran: true,
    source: "supabase db advisors --type all",
    result: JSON.parse(result.stdout),
  };
}
