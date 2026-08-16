# pgshuttle

**Copy a large PostgreSQL database onto your machine — resumably — and share the result as a single file.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![PostgreSQL 13+](https://img.shields.io/badge/PostgreSQL-13%2B-336791)
![Docker required](https://img.shields.io/badge/Docker-required-2496ED)
![Shell](https://img.shields.io/badge/Shell-bash-4EAA25)

`pg_dump` has no resume. If the connection drops at 90% of a three-hour dump, you
start over — and while it runs, you get no signal at all telling a working
transfer apart from a hung one.

pgshuttle dumps **one table per process** into its own file. A dropped connection
costs one table, not the run. Re-run the same command and it continues from where
it stopped. A second command shows byte-level progress and tells you when the
connection has actually died.

The result lands in a throwaway Postgres container, so nothing about the Postgres
you already run gets touched.

```bash
./pgshuttle preflight    # is the source reachable, and is this worth starting?
./pgshuttle dump         # pull the data — re-run any time to resume
./pgshuttle restore      # load it locally
./pgshuttle verify       # compare row counts against the source
```

## Knowing whether it is actually working

`./pgshuttle watch`, in a second terminal. A real recording — throughput per
table while it streams, then the connection is cut and it says so:

![pgshuttle watch: live per-table throughput, then a stall being detected](docs/watch.svg)

Byte-level progress is the point. A dump prints a line only when a table
*finishes*, so one large table looks exactly like a dead connection for minutes.
Here the rate decays, growth stops, the display goes yellow, and after the stall
threshold it turns red and tells you what to do — while the dump itself is still
sitting there, not yet aware it is dead.

---

## Who this is for

You need a realistic copy of a big Postgres database on your laptop for
debugging, and getting it there is the hard part:

- The connection is **slow, metered, or unreliable** — a VPN, an SSH tunnel, a
  cross-region link, or just home internet.
- The database is **big enough that restarting hurts** — tens of GB, hundreds of
  tables, thousands of indexes.
- You're on **macOS**, where `pgcopydb` — the usual answer to resumable copies —
  segfaults (see [below](#why-one-pg_dump-per-table)).
- The network you use to reach the database **cuts off everything else**, so
  tooling has to be in place before you connect.
- Your teammates need the same copy and shouldn't each repeat the download.

If your database is small, or you're on a fast reliable link, plain
`pg_dump -Fc` is simpler and you should use it.

---

## What you get

| | |
|---|---|
| **Resumable dump** | One `pg_dump` per table. Re-run the same command; finished tables are skipped. No limit on retries. |
| **Resumable restore** | Each table loads in a single transaction, so an interrupted restore never leaves half a table behind. |
| **Real progress** | `watch` reports per-table byte throughput and flags a stall, instead of leaving you guessing. |
| **Preflight** | Reachability, version compatibility, size, extensions and largest tables — answered in seconds, before a long run. |
| **Works offline** | Images are built and pulled up front, so the transfer needs nothing but the database itself. |
| **Isolated target** | Restores into its own container. No `postgresql.conf` edit, no `pg_hba.conf` edit, no port conflict, no risk to local work. |
| **Shareable output** | `export` produces one standard `pg_dump` archive your teammates restore with plain `pg_restore` or pgAdmin. |
| **Verification** | Row-count comparison against the source, plus index, foreign-key and sequence totals. |
| **Multi-database** | Namespaced by project, so several databases can be set up side by side. |

---

## Requirements

- **Docker** (Desktop or Engine), running
- **bash** — macOS and Linux; on Windows use WSL2
- Disk space for roughly **3× the compressed dump**

You do *not* need Postgres installed locally. Client tools and the restore target
are both containers.

---

## Why one `pg_dump` per table

Three approaches, and where each breaks:

**`pg_dump` in one shot** (what pgAdmin's backup dialog wraps) has no resume. A
dropped connection means starting from zero, and it emits no progress, so a stall
is indistinguishable from work.

**`pgcopydb`** does support `--resume`, and on Linux it is the right tool. On
macOS it segfaults: its worker pool coordinates through SysV message queues, and
macOS caps a queue at 2 KB. There is no sysctl to raise it — `kern.sysv.msg*` are
not tunable OIDs on current macOS. Queueing hundreds of tables and thousands of
indexes through 2 KB fails the send, the return value goes unchecked, and the
supervisor dies the instant it forks its workers.

**One `pg_dump` per table** — this tool. No IPC, no worker pool, no shared
snapshot, nothing that can segfault. A table either lands on disk or it doesn't,
and re-running skips the ones that landed.

The trade-off is honest: per-table transactions mean the copy is **not a
point-in-time snapshot**. See [Caveats](#caveats).

---

# Part 1 — First-time setup

Do this while you have **internet access**. It is the only part that needs it.

### 1. Get the code

```bash
git clone https://github.com/DholaSain/pgshuttle.git
cd pgshuttle
```

### 2. Create your config

```bash
./pgshuttle init
```

Creates `.env` from the template, mode 600. It is gitignored — it will hold a
database password.

### 3. Point it at your source

Open `.env` and set `SRC_DB_URL`:

```
SRC_DB_URL=postgresql://USER:PASSWORD@db.example.com:5432/your_db
```

Two things that bite people:

- **Percent-encode special characters in the password**: `@` → `%40`, `#` →
  `%23`, `:` → `%3A`, `/` → `%2F`, `?` → `%3F`, `%` → `%25`. Otherwise the URL
  parses wrong and you get a confusing authentication error.
- **ORM-style extras are fine to leave in.** `?schema=…`, `?connection_limit=…`,
  `?pgbouncer=true` are not libpq parameters and `pg_dump` rejects them outright.
  pgshuttle strips them, and adds TLS, TCP keepalives and timeouts.

Everything else has a working default:

| Setting | Default | What it does |
|---|---|---|
| `TARGET_DB` | `appdb` | name of the local copy — match the source so URLs line up |
| `TARGET_PORT` | `5433` | where the copy listens |
| `PG_MAJOR` | `16` | client version; must be ≥ the source server version |
| `PG_IMAGE` | `postgres:16` | image for the copy; swap for `postgis/postgis` etc. |
| `JOBS_DUMP` | `2` | concurrent connections to the source |
| `JOBS_RESTORE` | `4` | parallel local restore jobs |
| `EXACT_COUNTS` | `0` | `1` = exact `count(*)` for a stricter `verify` |

### 4. Download everything, ahead of time

```bash
./pgshuttle prepare
```

Builds the toolbox image and pulls Postgres. **Run this before you connect to a
restricted network** — nothing after it downloads anything.

### 5. Confirm it can run offline

```bash
./pgshuttle doctor
```

Checks both images are cached, the config is filled in, the toolbox runs, and
there is disk space. All green means everything needed is already local.

Setup never repeats unless you change `PG_MAJOR` or move machines.

---

# Part 2 — Taking a copy

The loop: check, pull, load, verify.

## Step 1 — Check the source is reachable *before* starting

Connect to whatever network reaches the database, then:

```bash
./pgshuttle preflight
```

In seconds, it tells you whether the run is worth starting:

- can a container actually reach the source
- is `pg_dump` new enough for the server (it refuses to read a newer server)
- how big the database is and how many tables
- which extensions the local copy will need to provide
- whether there are large objects (not copied — it warns)
- your ten largest tables, i.e. what a dropped connection will cost you

It writes nothing and does nothing heavier than catalog queries. Don't skip it —
discovering a version mismatch an hour into a dump is what this prevents.

On failure it names the likely cause: link down, Docker not inheriting the host
route, or a password needing percent-encoding.

## Step 2 — Pull the data

```bash
./pgshuttle dump          # resumes the current run
./pgshuttle dump --new    # starts a fresh copy
```

Writes to `backups/run-<timestamp>/`:

| File | Contents |
|---|---|
| `pre-data.dump` | schemas, types, functions, table definitions |
| `data/NNNN__schema.table.dump` | one file per table, smallest first |
| `post-data.dump` | indexes, primary keys, foreign keys, triggers |
| `sequences.sql` | sequence positions |
| `source_counts.tsv` | row counts, for `verify` |
| `meta.env`, `tables.tsv`, `logs/` | run metadata and per-table error logs |

Smallest tables go first on purpose: more tables finish before a flaky link
drops.

To stop the machine sleeping mid-run (macOS):

```bash
caffeinate -is ./pgshuttle dump
```

## Step 3 — Watch it, from a second terminal

```bash
./pgshuttle watch
```

```
watching run-20260816-0241   02:41:16

  tables dumped   43/197
  on disk         312M
  in flight       2

    0044__public.transactions      84M   +1584 KB/s   idle 0s
    0045__public.ledger            12M   +892 KB/s    idle 0s

  last change 0s ago -- progressing
```

The dump prints a line only when a table *finishes*, so one large table looks
identical to a dead connection for minutes. `watch` measures bytes instead:

| What you see | What it means |
|---|---|
| `last change Ns ago -- progressing` | working normally |
| a `.part` file with `+NNN KB/s` | that table is actively streaming |
| `quiet for 50s` (yellow) | normal on a big table; keep an eye on it |
| `no growth` on every file | nothing is arriving |
| `STALLED` (red, after 90s) | the connection is dead — see Step 4 |

`Ctrl-C` stops watching; it does not affect the dump.

To ask the **server** what it thinks is happening:

```bash
./pgshuttle activity
```

Shows the live `COPY … TO stdout` queries, and how to read them:

- `wait_event = ClientWrite` — the server has data ready and is blocked sending
  it to you. That's the network, not the database.
- `wait_event` empty or `IO` — the server is genuinely reading. Wait.
- **no rows at all** — the server already dropped your connections. The dump is
  dead even if the terminal still looks busy.

## Step 4 — When it stops, or stalls

**If the dump exits**, it says so plainly:

```
5/6 tables dumped, 1 failed this pass
restore the connection and re-run the same command -- finished tables are skipped
```

**If it hangs**, `watch` shows `STALLED` after 90 seconds of no bytes. A dead
link takes roughly 1–3 minutes to surface as a real error on its own (Docker's
network proxy answers the TCP keepalives that would otherwise catch it sooner),
so `watch` tells you before the dump does. You don't have to wait it out.

Either way the fix is the same:

1. `Ctrl-C` if it is still hanging. Always safe.
2. Restore the connection.
3. `./pgshuttle preflight` — confirm the source is back.
4. `./pgshuttle dump` — same command, no flags.

Finished tables are skipped. A table mid-write leaves a `.part` file, which is
deleted and re-pulled — you never get a silently truncated table. Repeat until it
prints `dump complete`.

Per-table failures are logged under `backups/<run>/logs/failed/`.

## Step 5 — Restore

Everything from here is local; the source is no longer needed.

```bash
./pgshuttle restore
./pgshuttle restore --fresh   # wipe the target and load from scratch
```

Starts the target container, creates the source's extensions, loads the schema,
loads tables in parallel, builds indexes and constraints, sets sequence
positions, and runs `ANALYZE`.

Index building is the slow part — on thousands of indexes it takes longer than
the data load. That's why indexes are built after the data rather than
maintained during it.

Resumable: each table loads in a single transaction, so an interrupted restore
never leaves half a table. Re-run and it continues.

## Step 6 — Verify

```bash
./pgshuttle verify
```

Compares each table's row count against the source at dump time, and reports
index, foreign-key and sequence totals.

- `MISSING` or `EMPTY` — a real problem. Re-run `./pgshuttle restore`.
- `SHORT` — expected on busy tables, and on any table whose statistics are stale.

By default the source numbers come from `pg_class.reltuples`, which is a planner
**estimate** and drifts badly on churn-heavy tables. Set `EXACT_COUNTS=1` in
`.env` before dumping for a definitive comparison.

---

# Part 3 — Using the copy

The copy lives in a container and stays up between sessions.

```
Host      localhost
Port      5433
Database  appdb          (whatever you set TARGET_DB to)
User      postgres
Password  postgres
```

```
postgresql://postgres:postgres@localhost:5433/appdb
```

**A psql shell**

```bash
./pgshuttle psql
```

It also works non-interactively, so you can script against the copy:

```bash
./pgshuttle psql -At -c "select count(*) from orders"
```

**GUI clients** — pgAdmin, DBeaver, TablePlus, DataGrip: add a server at
`localhost:5433`. Any Postgres you already run on 5432 is untouched.

**Your application** — point `DATABASE_URL` at the string above.

**Container lifecycle**

```bash
./pgshuttle up      # start it (restore does this for you)
./pgshuttle down    # stop it — data survives in a Docker volume
./pgshuttle reset   # delete the copy entirely; dump files are kept
```

`reset` followed by `restore` rebuilds from the dump files without touching the
source.

**Restoring elsewhere.** To load into a Postgres you already run, set
`TGT_DB_URL` in `.env`. That path needs `listen_addresses='*'` and a `pg_hba.conf`
rule for the Docker bridge — the setup friction the container exists to avoid.

---

# Part 4 — Sharing the copy

A slow pull is worth doing once, not once per teammate. Once *you* have the local
copy, hand them a single file.

```bash
./pgshuttle export
```

This dumps your **local copy**, not the source — so it runs at disk speed and
needs no connection to the database. On a 2.4 GB copy it takes well under a
minute.

Produces three files in `exports/`:

| File | Purpose |
|---|---|
| `appdb-YYYYMMDD.dump` | the archive — this is what you share |
| `…dump.sha256` | tells a corrupt download from a bad file |
| `…dump.HOW-TO-RESTORE.txt` | instructions generated for that exact file |

The output is a plain `pg_dump -Fc` archive. **Recipients need nothing from this
repo** — `pg_restore` or pgAdmin is enough. Ownership and grants are stripped, so
it loads under whatever role they have.

**Make it smaller.** Ship bulky tables as schema-only:

```bash
./pgshuttle export --out slim.dump \
  --exclude '"public".audit_log' --exclude '"public".event_history_*'
```

Tables keep their columns, indexes and foreign keys — only the rows are dropped,
so applications still start. `--exclude` is repeatable and takes `*` wildcards.

**What recipients run:**

```bash
createdb -h localhost -U postgres appdb
pg_restore -h localhost -U postgres -d appdb -j 4 --no-owner --no-acl appdb-20260816.dump
```

In **pgAdmin**: create an empty database, right-click → Restore, format *Custom or
tar*, pick the file, and under Restore Options enable *Do not save Owner* and *Do
not save Privileges*.

They need client tools at least as new as the archive — `pg_restore` refuses one
written by a newer version.

If a recipient has this repo, there's a shortcut that also verifies the checksum:

```bash
./pgshuttle import appdb-20260816.dump
```

**Before you send it.** This is real data leaving your machine: use an
access-controlled destination, `--exclude` tables holding personal data the
recipient doesn't need, and delete stale exports. `exports/` is gitignored so it
can't be committed by accident.

---

## Reusing this for another database

**Replacing the current copy** — edit `SRC_DB_URL` and `TARGET_DB` in `.env`:

```bash
./pgshuttle reset && ./pgshuttle dump --new && ./pgshuttle restore
```

**Keeping both** — give the second database its own config and project, which
namespaces the container, volume, compose project and directories:

```bash
cp .env.example .env.staging
```

```
SRC_DB_URL=postgresql://…/staging_db
TARGET_DB=staging_db
TARGET_PORT=5434
PROJECT=pgshuttle-staging
BACKUPS_DIR=backups-staging
EXPORTS_DIR=exports-staging
```

```bash
PGSHUTTLE_ENV=.env.staging ./pgshuttle dump
PGSHUTTLE_ENV=.env.staging ./pgshuttle restore
```

Both run side by side on different ports. Any `.env.*` file is gitignored.

---

## Command reference

```
Setup, once                                             (needs internet)
  ./pgshuttle init          create .env from the template
  ./pgshuttle prepare       build the toolbox image, pull Postgres
  ./pgshuttle doctor        confirm nothing else needs downloading

Every copy
  ./pgshuttle preflight     check the source is reachable      needs source
  ./pgshuttle dump          pull the data (re-run to resume)   needs source
  ./pgshuttle dump --new    start a fresh run instead of resuming
  ./pgshuttle restore       load into the local container      offline
  ./pgshuttle restore --fresh   wipe the target first
  ./pgshuttle verify        compare row counts                 offline

Share it
  ./pgshuttle export        one file anyone can pg_restore
  ./pgshuttle export --exclude '"schema".big_table'
  ./pgshuttle import FILE   load a shared file locally

Is it still working?  (second terminal)
  ./pgshuttle watch         live byte-level progress, warns on stall
  ./pgshuttle activity      what the source server is doing    needs source
  ./pgshuttle status        one-shot summary

Around it
  ./pgshuttle psql          psql on the local copy
  ./pgshuttle up | down     start / stop the target container
  ./pgshuttle reset         delete the local copy
  ./pgshuttle prune         list runs and their sizes
  ./pgshuttle shell         bash inside the toolbox image
```

---

## Troubleshooting

**Preflight can't connect, but `psql` works on the host.**
Docker isn't inheriting the host's routing. pgshuttle already resolves the source
hostname on the host and passes it in with `--add-host`, which fixes most cases.
If it still fails, run the scripts natively — they only need `bash`, `psql` and
`pg_dump`:

```bash
SRC_DB_URL='postgresql://…' RUN_DIR=./backups/native JOBS=2 bash scripts/dump.sh
```

Then `./pgshuttle restore` as usual.

**`pg_dump` is older than the server.**
Set `PG_MAJOR` to the server's major version and re-run `./pgshuttle prepare`.

**Dumps keep dying on big tables.**
Set `JOBS_DUMP=1`. If that isn't enough and you're on a VPN, lower the tunnel
MTU — fragmentation kills large transfers while small queries keep working, which
is why `psql` feels fine and the dump doesn't:

```bash
sudo ifconfig utun4 mtu 1400          # macOS; find the interface with ifconfig
sudo ip link set dev tun0 mtu 1400    # Linux
```

**An extension is missing on restore.**
Restore runs offline, so pull an image that has it: set
`PG_IMAGE=postgis/postgis:16-3.4`, then `./pgshuttle reset && ./pgshuttle restore`.

**"Some tables refused the load because they already contain rows."**
The target and the dump have drifted. Nothing was corrupted — each load is a
single transaction, so rejected tables rolled back cleanly. Run
`./pgshuttle restore --fresh`.

**Port 5433 already in use.**
Change `TARGET_PORT`, then `./pgshuttle down && ./pgshuttle restore`.

---

## Caveats

- **Not a point-in-time snapshot.** Each table is dumped in its own transaction —
  that's what makes resuming possible. Tables pulled in different sessions
  reflect slightly different moments, so a row can exist in one table without its
  counterpart in another. Fine for debugging; not a backup of record. For true
  consistency, snapshot the database at the storage layer and dump from a
  restored copy.
- **Large objects are not copied.** `preflight` warns if the source has any.
- **The target runs with `fsync=off`.** It loads much faster and the data is
  disposable. Never point those settings at anything you care about.
- **`backups/` and `exports/` hold real data**, and `.env` holds a password. All
  three are gitignored. Delete old runs when you're done — `./pgshuttle prune`
  lists them with sizes.
- **Row counts default to estimates.** Set `EXACT_COUNTS=1` for exact ones.

---

## How it works

```
source ──┐
         │  one pg_dump per table, smallest first, .part → rename on success
         ▼
  backups/run-<ts>/
    pre-data.dump      schema, types, functions, tables
    data/*.dump        one custom-format archive per table
    post-data.dump     indexes, constraints, triggers
         │
         │  pre-data → data (parallel, one txn each) → post-data → sequences
         ▼
  container on :5433   ──  ./pgshuttle export ──▶  one .dump file to share
```

Client tools run in a purpose-built image so the host needs no Postgres install
and the client version is pinned independently of the server. The target is an
ordinary `postgres` image with durability traded for load speed.

---

## Contributing

Issues and pull requests are welcome. The code is plain bash — `pgshuttle` is the
CLI, `scripts/` holds what runs inside the container. Run `bash -n` on anything
you change.

## License

[MIT](LICENSE)
