// Real Storage schema plus unchanged owning Taskfold migrations.
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";
import { createPostgresFixture } from "./postgres-fixture.mjs";
import { createStorageProvider } from "./storage-provider-fixture.mjs";
import {
  childAuthorityMigration,
  loadChildAuthorityDependencies,
} from "./child-task-authority-schema.mjs";
export async function createTaskFileProviderDatabase() {
  let pg, storage;
  try {
    pg = await createPostgresFixture({ advisors: true });
    const raw = pg.raw;
    pg.raw = async (sql) => {
      // Replace only the two explicitly minimal bootstrap stubs. All production
      // migrations execute unchanged against Storage's actual schema and policies.
      if (sql.startsWith("-- Minimal owned local schema.")) {
        const stub =
          "create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid,owner_id text);";
        assert(sql.includes(stub));
        const [before, after] = sql.split(stub);
        await raw(before);
        storage = await createStorageProvider(pg);
        await raw(after);
        return "";
      }
      const buckets =
        "create table storage.buckets(id text primary key,public boolean not null);insert into storage.buckets values('avatars',true),('task-attachments',false);";
      if (sql.startsWith(buckets)) {
        for (
          const [id, publicBucket] of [["avatars", true], [
            "task-attachments",
            false,
          ]]
        ) {
          const response = await storage.request("/bucket", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ id, name: id, public: publicBucket }),
          });
          assert.equal(response.status, 200, await response.text());
        }
        return raw(sql.slice(buckets.length));
      }
      return raw(sql);
    };
    await loadChildAuthorityDependencies(pg);
    for (
      const file of [
        childAuthorityMigration,
        "20261030093035_child_record_reviewed_team_transfers.sql",
        "20261101212844_task_bound_file_custody.sql",
        "20261101220633_task_file_upload_admission.sql",
        "20261101225002_task_file_sender_stop.sql",
        "20261101232206_task_file_upload_cleanup.sql",
      ]
    ) {
      await pg.raw(
        await readFile(
          new URL("../../supabase/migrations/" + file, import.meta.url),
          "utf8",
        ),
      );
    }
    return { pg, storage };
  } catch (error) {
    try {
      if (storage) await storage.close();
    } finally {
      if (pg) await pg.close();
    }
    throw error;
  }
}
