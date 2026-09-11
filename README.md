# DoltgreSQL 1.3.1: a CHECK constraint that calls regexp_like with a cast argument refuses every row

On DoltgreSQL 1.3.1, a table accepts a CHECK constraint such as `regexp_like(z::text, '^[0-9]+$')`, and
then refuses every row, whether or not the row satisfies the check:

```
ERROR:  at or near "as": syntax error
```

PostgreSQL 18.6 stores a row that satisfies the check and refuses one that does not.

## Reproduce it

You need Docker and a POSIX shell: Linux, macOS, or Windows with WSL. The first run downloads the images.

```sh
git clone https://github.com/Reliable-Collaboration/repro-doltgresql-bug-regexp-like-check.git
cd repro-doltgresql-bug-regexp-like-check
./repro.sh
```

`repro.sh` starts PostgreSQL 18.6 and DoltgreSQL 1.3.1 in throwaway containers, waits until both accept
connections, runs [`repro.sql`](repro.sql) on each with the `psql` client inside its container, prints the
two outputs side by side, and removes the containers. It exits 0 when DoltgreSQL's output is identical to
PostgreSQL's and 1 when it differs; with DoltgreSQL 1.3.1 it exits 1.

To try another DoltgreSQL release, name its image (`POSTGRES_IMAGE` does the same for PostgreSQL):

```sh
DOLTGRESQL_IMAGE=dolthub/doltgresql:latest ./repro.sh
```

### Without the script

The same steps by hand, from the repository directory:

```sh
docker run -d --name repro-doltgresql-bug-regexp-like-check-postgres -e POSTGRES_PASSWORD=password postgres:18.6-bookworm
docker run -d --name repro-doltgresql-bug-regexp-like-check-doltgresql -e DOLTGRES_PASSWORD=password dolthub/doltgresql:1.3.1
docker cp repro.sql repro-doltgresql-bug-regexp-like-check-postgres:/tmp/repro.sql
docker cp repro.sql repro-doltgresql-bug-regexp-like-check-doltgresql:/tmp/repro.sql
docker exec -t -e PGPASSWORD=password repro-doltgresql-bug-regexp-like-check-postgres psql -X -P pager=off -h 127.0.0.1 -U postgres -d postgres --echo-all -f /tmp/repro.sql
docker exec -t -e PGPASSWORD=password repro-doltgresql-bug-regexp-like-check-doltgresql psql -X -P pager=off -h 127.0.0.1 -U postgres -d postgres --echo-all -f /tmp/repro.sql
docker rm -f repro-doltgresql-bug-regexp-like-check-postgres repro-doltgresql-bug-regexp-like-check-doltgresql
```

If `docker exec` answers that the connection was refused, the server is still starting: wait a few seconds
and run it again.

## The test

[`repro.sql`](repro.sql):

```sql
-- A check that calls regexp_like with a cast argument.
CREATE TABLE t (
    z text CHECK (regexp_like(z::text, '^[0-9]+$'))
);

-- A value that satisfies the check.
INSERT INTO t VALUES ('12345');

SELECT z FROM t;
```

## Expected behavior

The row satisfies the check, so it is stored. This is what PostgreSQL 18.6 prints:

```
-- A check that calls regexp_like with a cast argument.
CREATE TABLE t (
    z text CHECK (regexp_like(z::text, '^[0-9]+$'))
);
CREATE TABLE
-- A value that satisfies the check.
INSERT INTO t VALUES ('12345');
INSERT 0 1
SELECT z FROM t;
   z   
-------
 12345
(1 row)
```

## Actual behavior

The `CREATE TABLE` succeeds, but the `INSERT` fails, and the table stays empty. This is what DoltgreSQL
1.3.1 prints:

```
-- A check that calls regexp_like with a cast argument.
CREATE TABLE t (
    z text CHECK (regexp_like(z::text, '^[0-9]+$'))
);
CREATE TABLE
-- A value that satisfies the check.
INSERT INTO t VALUES ('12345');
psql:/tmp/repro.sql:7: ERROR:  at or near "as": syntax error
SELECT z FROM t;
 z 
---
(0 rows)
```

## Side by side

The output of `./repro.sh`. The view cuts long lines at the width of their column, so DoltgreSQL's error
is shortened here; the two sections above show both outputs whole.

```
Starting postgres:18.6-bookworm@sha256:1c59e2c3c818eaa0f0628f695b36e7c9e362d6b219b36a54a32df645cbd7e1af
Starting dolthub/doltgresql:1.3.1@sha256:6c85cb1f35beabf47f094336a420255130b841b1645f36d79ef046276af36851

Left: PostgreSQL. Right: DoltgreSQL. Lines that differ are marked with |.

-- A check that calls regexp_like with a cast argument.       -- A check that calls regexp_like with a cast argument.
CREATE TABLE t (                                              CREATE TABLE t (
    z text CHECK (regexp_like(z::text, '^[0-9]+$'))               z text CHECK (regexp_like(z::text, '^[0-9]+$'))
);                                                            );
CREATE TABLE                                                  CREATE TABLE
-- A value that satisfies the check.                          -- A value that satisfies the check.
INSERT INTO t VALUES ('12345');                               INSERT INTO t VALUES ('12345');
INSERT 0 1                                                  | psql:/tmp/repro.sql:7: ERROR:  at or near "as": syntax erro
SELECT z FROM t;                                              SELECT z FROM t;
   z                                                        |  z 
-------                                                     | ---
 12345                                                      | (0 rows)
(1 row)                                                     <


Result: DoltgreSQL's output differs from PostgreSQL's on 4 line(s), marked with |.
```

## Other observations

Each was run on DoltgreSQL 1.3.1 and on PostgreSQL 18.6. PostgreSQL ran every statement below without an
error, except the rows that break a check, which it refused with a check violation.

- A row that breaks the check, `INSERT INTO t VALUES ('abcde')`, gets the same syntax error, not a check
  violation.
- Added to a table that already holds a row, `ALTER TABLE ... ADD CONSTRAINT u_z_check CHECK (regexp_like(z::text, '^[0-9]+$'))`
  succeeds, and then `INSERT`, `UPDATE` and `COPY ... FROM stdin` fail with the same error.
- `information_schema.check_constraints` shows the test's check stored as
  `regexp_like("z"::TEXT as z,'^[0-9]+$')`; PostgreSQL shows `regexp_like(z, '^[0-9]+$'::text)`.
- Other arguments trigger it too: `CAST(z AS text)`, a cast on the pattern only
  (`regexp_like(z, '^[0-9]+$'::text)`), `regexp_like((z)::text, '^[0-9]+$'::text)` on a `character(5)`
  column, and arguments without a cast, `lower(z)` and `z || ''`.
- Other regular expression functions with a cast argument trigger it: `regexp_replace(z::text, '[0-9]', '', 'g') = ''`,
  `regexp_substr(z::text, '[0-9]+') = z` and `regexp_instr(z::text, '[a-z]') = 0`.
- Not triggered: `regexp_like(z, '^[0-9]+$')`, which accepts `'12345'` and refuses `'abcde'`;
  `regexp_like(z, '^[0-9]+' || '$')`; `length(z::text) = 5`; `upper(z::text) = z`; `z::text ~ '^[0-9]+$'`.
- Outside a check, the same call works: `SELECT z, regexp_like(z::text, '^[0-9]+$') FROM s` answers `t`, and
  a column `GENERATED ALWAYS AS (regexp_like(z::text, '^[0-9]+$')) STORED` accepts the row.
- pg_dump 18.6 writes a check declared without any cast, `CHECK (regexp_like(z, '^[0-9]+$'))`, as
  `CHECK (regexp_like(z, '^[0-9]+$'::text))`, the pattern-cast form above that triggers the error.
- Possibly related: [dolthub/doltgresql#3323](https://github.com/dolthub/doltgresql/issues/3323), where a
  saved generated-column expression also carries an `as` alias and fails with the same syntax error.

## Environment

- DoltgreSQL 1.3.1, the newest release when this was written: image `dolthub/doltgresql:1.3.1`, digest
  `sha256:6c85cb1f35beabf47f094336a420255130b841b1645f36d79ef046276af36851`. Its bundled `psql` is 17.11.
- PostgreSQL 18.6: image `postgres:18.6-bookworm`, digest
  `sha256:1c59e2c3c818eaa0f0628f695b36e7c9e362d6b219b36a54a32df645cbd7e1af`. Its `psql` is 18.6.
- Reproduced on 2026-09-11 (UTC) with Docker 29.7.2 on Linux x86_64 (Ubuntu 26.04.1 LTS under WSL 2).
