# The postgres image supplies a pg_dump and psql that match the server (tag the
# image with the server's major version); age does the encryption; bash is here
# for `set -o pipefail`, which turns a failed pg_dump into a failed backup rather
# than an encrypted empty file.
ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-alpine

RUN apk add --no-cache age bash

COPY bin/pg-backup /usr/local/bin/pg-backup

# The base image's entrypoint would try to initialise a database cluster.
ENTRYPOINT []
CMD ["pg-backup", "loop"]
