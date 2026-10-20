# pg-backup

A sidecar that backs up a Postgres database every hour, encrypted with [age](https://age-encryption.org) before it
touches disk. Each dump is `pg_dump --clean --if-exists | gzip | age`, so no plaintext copy ever lands on the volume,
which is usually a NAS mount.

```
ghcr.io/haitrr/pg-backup:17      # also :16 and :18; match your server's major version
ghcr.io/haitrr/pg-backup:17-<sha>
```

Images are rebuilt weekly to pick up Postgres patch releases. `docker compose up` keeps whichever copy it pulled first,
so run `docker compose pull postgres-backup` when you deploy to get them.

## What it keeps

| Directory      | What                                      | Kept (default)          |
| -------------- | ----------------------------------------- | ----------------------- |
| `hourly/`      | one at start, then one every hour         | 48 (`BACKUP_KEEP_HOURS`)  |
| `daily/`       | the first dump of each day                | 7 (`BACKUP_KEEP_DAYS`)    |
| `weekly/`      | the first dump of each ISO week           | 4 (`BACKUP_KEEP_WEEKS`)   |
| `monthly/`     | the first dump of each month              | 6 (`BACKUP_KEEP_MONTHS`)  |
| `deployments/` | one per `pg-backup now`, e.g. pre-deploy  | 20 (`BACKUP_KEEP_DEPLOYS`) |

The daily, weekly and monthly copies are hard links to hourly dumps, so they cost no extra space. A dump is written as
`.part` and renamed only once `pg_dump`, `gzip` and `age` have all succeeded. A failed dump is retried after 5 minutes,
and the loop waits for Postgres to come back after a restart.

## Setup

Make a key pair on your own machine. The server only ever gets the public half:

```shell
age-keygen -o myapp-backup.key        # keep this file offline; it is the only way to read a backup
grep 'public key' myapp-backup.key    # the age1… value for BACKUP_AGE_RECIPIENT
```

Add the service to your compose file:

```yaml
services:
  postgres-backup:
    image: ghcr.io/haitrr/pg-backup:17
    restart: always
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_USER: myapp
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: myapp
      # The container refuses to start without it, rather than write plaintext.
      BACKUP_AGE_RECIPIENT: ${BACKUP_AGE_RECIPIENT:-}
    volumes:
      - postgres-backups:/backups
volumes:
  postgres-backups:
    driver: local
    driver_opts:
      type: nfs
      o: 'addr=nas.local,rw,noatime,nolock,intr,tcp,actimeo=1800,nfsvers=3'
      device: ':/volume/backups/myapp'
```

| Variable               | Default          |                                                   |
| ---------------------- | ---------------- | ------------------------------------------------- |
| `BACKUP_AGE_RECIPIENT` | required         | public key the dumps are encrypted to             |
| `POSTGRES_HOST`        | `postgres`       |                                                   |
| `POSTGRES_PORT`        | `5432`           |                                                   |
| `POSTGRES_USER`        | required         |                                                   |
| `POSTGRES_PASSWORD`    |                  |                                                   |
| `POSTGRES_DB`          | required         |                                                   |
| `BACKUP_PREFIX`        | `$POSTGRES_DB`   | file name prefix; keep it fixed, since pruning matches on it |
| `BACKUP_DIR`           | `/backups`       |                                                   |

## Backing up before a deploy

```shell
docker compose exec -T postgres-backup pg-backup now </dev/null
```

It prints the path of the new dump, in `deployments/`. On a first deploy the service isn't running yet, so this fails;
treat that as "nothing to back up".

## Restoring

List the dumps:

```shell
docker compose exec -T postgres-backup pg-backup list
```

Restore one in a throwaway container with the private key mounted at `/run/age.key`, so the long-running service
never sees it. It asks you to type the database name, since it replaces the database's contents; set
`RESTORE_ASSUME_YES=1` to skip that. The restore runs in one transaction, so a failure leaves the database as it was.

```shell
docker compose run --rm -v ~/myapp-backup.key:/run/age.key:ro \
  postgres-backup pg-backup restore /backups/daily/20261020.sql.gz.age
```

To restore a dump you have on the host, mount it too:

```shell
docker compose run --rm -v ~/myapp-backup.key:/run/age.key:ro -v ./dump.sql.gz.age:/run/dump.sql.gz.age:ro \
  postgres-backup pg-backup restore /run/dump.sql.gz.age
```

Without Docker, a dump is just `age -d -i myapp-backup.key dump.sql.gz.age | gunzip | psql …`.

## Testing

```shell
PG_MAJOR=17 test/roundtrip.sh
```

builds the image and checks the whole cycle against a real Postgres: it refuses to start without a recipient, the
tiers fill, the dumps are ciphertext, a wrong key or a wrong confirmation changes nothing, and a restore brings the data
back.
