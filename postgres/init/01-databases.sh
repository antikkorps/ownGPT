#!/bin/sh
# Runs once, on the first start of an empty data volume.
# One role per application: Open WebUI cannot read LiteLLM's tables and vice versa.
# Passwords are psql variables (:'name' quotes them), never spliced into the SQL text.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v owui_pw="$OPENWEBUI_DB_PASSWORD" -v litellm_pw="$LITELLM_DB_PASSWORD" <<'SQL'
CREATE ROLE openwebui LOGIN PASSWORD :'owui_pw';
CREATE ROLE litellm   LOGIN PASSWORD :'litellm_pw';
CREATE DATABASE openwebui OWNER openwebui;
CREATE DATABASE litellm   OWNER litellm;
REVOKE ALL ON DATABASE openwebui FROM PUBLIC;
REVOKE ALL ON DATABASE litellm   FROM PUBLIC;
SQL
