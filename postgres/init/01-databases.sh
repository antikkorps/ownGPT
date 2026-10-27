#!/bin/sh
# Runs once, on the first start of an empty data volume.
# One role per application: Open WebUI cannot read LiteLLM's tables and vice versa.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE openwebui LOGIN PASSWORD '${OPENWEBUI_DB_PASSWORD}';
CREATE ROLE litellm   LOGIN PASSWORD '${LITELLM_DB_PASSWORD}';
CREATE DATABASE openwebui OWNER openwebui;
CREATE DATABASE litellm   OWNER litellm;
REVOKE ALL ON DATABASE openwebui FROM PUBLIC;
REVOKE ALL ON DATABASE litellm   FROM PUBLIC;
SQL
