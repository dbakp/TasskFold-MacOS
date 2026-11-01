// Existing acceptance suites with the complete mapping migration installed.
// Each suite owns and removes its isolated PostgreSQL fixture, sequentially.
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';

const exec = promisify(execFile), here = fileURLToPath(new URL('.', import.meta.url));
const directory = resolve(process.env.TASKFOLD_MAPPING_REGRESSION_DIR ?? join(tmpdir(), 'taskfold-copy-mapping-regressions'));
await mkdir(directory, {recursive: true});
await writeFile(join(directory, 'verification.json'), JSON.stringify({passed: false, state: 'running'}) + '\n');
const scratch = await mkdtemp(join(tmpdir(), 'taskfold-mapping-sql-'));
const names = ['20261101101059_reviewed_saved_copy_reconciliation.sql', '20261101123154_reviewed_child_history_reconciliation.sql', '20261101124928_atomic_child_copy_mapping.sql'];
const fields = ['20261031204437_child_field_activity_details.sql', '20261101041509_child_order_activity.sql'];
const load = name => readFile(new URL('../../supabase/migrations/' + name, import.meta.url), 'utf8');
const sourceSHA256 = {};
try {
    const sql = {};
    for (const name of [...fields, ...names]) {
        sql[name] = await load(name);
        sourceSHA256[name] = createHash('sha256').update(sql[name]).digest('hex');
    }
    const copySQL = join(scratch, 'copy.sql'), legacySQL = join(scratch, 'legacy.sql');
    await writeFile(copySQL, names.map(n => sql[n]).join('\n'));
    await writeFile(legacySQL, [...fields, ...names].map(n => sql[n]).join('\n'));
    const suites = [
        {name: 'copy-choice', script: 'test-child-copy-choice.mjs', env: {TASKFOLD_COPY_CHOICE_SQL: copySQL, TASKFOLD_COPY_CHOICE_REPORT: join(directory, 'copy-choice.json')}},
        {name: 'legacy-repair', script: 'test-child-duplicate-history.mjs', env: {TASKFOLD_COPY_CHOICE_REGRESSION_SQL: legacySQL, TASKFOLD_REPAIR_REPORT: join(directory, 'legacy-repair.json')}},
    ];
    const results = [];
    for (const suite of suites) {
        const run = await exec(process.execPath, [join(here, suite.script)], {env: {...process.env, ...suite.env}, maxBuffer: 1024 * 1024});
        const result = JSON.parse(await readFile(join(directory, suite.name + '.json'), 'utf8'));
        assert.equal(result.passed, true, suite.name); assert.equal(result.fixtureRemoved, true, suite.name);
        results.push({name: suite.name, assertions: Object.keys(result.checks).length, passed: true, fixtureRemoved: true});
        console.log(run.stdout.trim());
    }
    const report = {passed: true, deployed: false, sourceSHA256, suites: results};
    await writeFile(join(directory, 'verification.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report));
} finally {
    await rm(scratch, {recursive: true, force: true});
}
