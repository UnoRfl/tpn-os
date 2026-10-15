// TPN OS database tests.
//
//   cd tests/db && npm install      (once)
//   node run.mjs                    every migration + every t_*.sql
//   node run.mjs t_31_payments.sql  migrations + just that test file
//
// Replays sql/*.sql in name order into an in-memory Postgres (PGlite) on
// top of a small Supabase stand-in (supabase-stub.sql: auth.uid(), the
// anon/authenticated roles, default grants). prod-drift-after-17.sql adds
// the columns production has that no migration creates.
//
// Test files: blocks separated by a blank line. A block ending in a
// `select name, ok, detail ...` prints PASS/FAIL per row. Convention:
// write results into public.t_results (created by the first test file
// that needs it).
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const sqlDir = path.resolve(here, '../../sql');
const args = process.argv.slice(2);
const tests = (args.length ? args : fs.readdirSync(here).filter(f => /^t_.*\.sql$/.test(f)).sort())
  .map(f => path.isAbsolute(f) ? f : path.join(here, f));

const db = new PGlite();
await db.exec(fs.readFileSync(path.join(here, 'supabase-stub.sql'), 'utf8'));

let ok = true;
const migrations = fs.readdirSync(sqlDir).filter(f => f.endsWith('.sql')).sort();
for (const f of migrations) {
  try {
    await db.exec(fs.readFileSync(path.join(sqlDir, f), 'utf8'));
    if (f.startsWith('17-')) await db.exec(fs.readFileSync(path.join(here, 'prod-drift-after-17.sql'), 'utf8'));
    if (process.env.VERBOSE) console.log('migrated', f);
  } catch (e) { ok = false; console.log('MIGRATION FAIL', f, '->', e.message); break; }
}
if (ok) console.log(`migrations: ${migrations.length} applied`);

let pass = 0, fail = 0;
for (const t of ok ? tests : []) {
  const blocks = fs.readFileSync(t, 'utf8').split(/\r?\n\s*\r?\n/).filter(b => b.trim());
  for (const b of blocks) {
    try {
      const r = await db.exec(b);
      const last = r[r.length - 1];
      if (/^\s*select\s+name\s*,\s*ok/i.test(b.trim().split('\n').pop()) && last && last.rows) {
        for (const row of last.rows) {
          if (row.ok === true) pass++; else { fail++; ok = false; }
          if (row.ok !== true || process.env.VERBOSE) console.log(row.ok === true ? 'PASS' : 'FAIL', path.basename(t), '·', row.name, row.ok === true ? '' : '-> ' + (row.detail || ''));
        }
        await db.exec('truncate public.t_results');
      }
    } catch (e) {
      ok = false; fail++;
      const hint = b.split('\n').find(l => /t_results values \('/.test(l)) || b.split('\n')[0];
      console.log('ERROR', path.basename(t), e.message, '| near:', hint.trim().slice(0, 110));
    }
  }
}
console.log(`tests: ${pass} passed, ${fail} failed`);
process.exit(ok ? 0 : 1);
