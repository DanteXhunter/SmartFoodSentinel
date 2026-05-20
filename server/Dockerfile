FROM postgres:16

LABEL maintainer="Smart Supermarket Discount System"
LABEL description="PostgreSQL 16 with auto-initialised supermarket discount schema"

# Copy the init script into the Docker entrypoint directory.
# PostgreSQL's entrypoint runs *.sql files here automatically on first start
# (only when the data directory is empty — i.e. a fresh named volume).
COPY init.sql /docker-entrypoint-initdb.d/01_init.sql

# Default port — kept explicit for clarity
EXPOSE 5432
