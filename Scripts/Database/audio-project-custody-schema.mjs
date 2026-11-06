import { readFile } from "node:fs/promises";
import {
  childAuthorityMigration,
  loadChildAuthorityDependencies,
} from "./child-task-authority-schema.mjs";
export const audioProjectCustodyMigration =
  "20261102150524_reviewed_audio_project_custody.sql";
export const audioProjectDependencies = [
  childAuthorityMigration,
  "20261030093035_child_record_reviewed_team_transfers.sql",
  "20261101212844_task_bound_file_custody.sql",
];
export const audioProjectLedgerDependencies = [
  "20261028134424_audio_comment_publication_ledger.sql",
  "20261028145414_audio_comment_gateway_boundary.sql",
  "20261028151901_audio_comment_cleanup_fencing.sql",
  "20261028153218_audio_comment_upload_recovery.sql",
  "20261028185429_audio_comment_keyset_pages.sql",
  "20261028191118_audio_comment_shared_reads.sql",
  "20261028212632_audio_owner_publication_status.sql",
  "20261102143104_team_audio_write_authority.sql",
];
export const migrationSQL = (name) =>
  readFile(
    new URL("../../supabase/migrations/" + name, import.meta.url),
    "utf8",
  );
export async function loadAudioProjectCustodyDependencies(pg) {
  await loadChildAuthorityDependencies(pg);
  for (const f of audioProjectDependencies) await pg.raw(await migrationSQL(f));
  await pg.raw(
    "alter table storage.objects add column metadata jsonb,add column version text;alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];alter table storage.buckets enable row level security;create unique index audio_fixture_object_identity on storage.objects(bucket_id,name)",
  );
  for (const f of audioProjectLedgerDependencies) {
    await pg.raw(await migrationSQL(f));
  }
}
