-- Exact row count of every table that moves (MIGRATION.md, steps B1 and B6).
-- Run it on the OLD project before the move and on the NEW one after it.
-- Save both results; every line must match. Read-only.
select table_schema || '.' || table_name as "table",
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint as "rows"
  from information_schema.tables
 where table_type = 'BASE TABLE'
   and (table_schema in ('public', 'private')
        or (table_schema, table_name) in (('auth', 'users'), ('auth', 'identities'),
                                          ('storage', 'buckets'), ('storage', 'objects')))
 order by 1;
