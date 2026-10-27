# Automatisations → passerelle LiteLLM

Tout script, ETL ou outil no-code appelle la **même** passerelle que le chat, avec la clé
virtuelle **automatisation** (modèle `mistral-small` seul, budget 1 $/30 j, journalisée sans
contenu).

```bash
export OWNGPT_API_URL=https://api.exemple.fr
export OWNGPT_AUTOMATION_KEY=sk-…        # LITELLM_KEY_AUTOMATION du .env

./exemple-curl.sh                                        # appel minimal
python3 resume_document.py document-exemple.txt          # résumé d'un document
```

## n8n (optionnel)

`n8n-resume-document.json` : Webhook → appel passerelle → extraction du résumé.
Importer dans n8n (Workflows → Import from file), définir `OWNGPT_API_URL` et
`OWNGPT_AUTOMATION_KEY` dans l'environnement de n8n, activer, puis :

```bash
curl -X POST https://n8n.exemple.fr/webhook/resume-document \
  -H 'Content-Type: application/json' -d '{"texte":"…"}'
```

Le webhook de l'exemple n'est **pas authentifié** : avant toute exposition, activer
l'authentification du nœud Webhook (*Header Auth*). Et `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`
rend la clé lisible par tout éditeur de workflows : en production, préférer un *Credential*
n8n (type Header Auth) à une variable d'environnement.

n8n n'est pas inclus dans le Compose (hors périmètre de la démo) ; pour l'essayer en
local : `docker run --rm -p 5678:5678 -e OWNGPT_API_URL -e OWNGPT_AUTOMATION_KEY n8nio/n8n:2.0.0`
(dans ce cas, autoriser l'accès aux variables : `-e N8N_BLOCK_ENV_ACCESS_IN_NODE=false`).

## Créer une clé par automatisation, fixer son budget

Une clé par flux permet de couper ou de plafonner un flux sans toucher aux autres :

```bash
./scripts/litellm-api.sh POST /key/generate '{"key_alias":"auto-crm","team_id":"demo",
  "models":["mistral-small"],"max_budget":2,"budget_duration":"30d","rpm_limit":30,
  "metadata":{"usage":"automatisation"}}'
```

## Vérifier

Tableau de bord LiteLLM → **Logs** : filtrer par clé ; **Usage** : dépense par clé
et par modèle. Le contenu des requêtes n'est jamais stocké, seulement les métadonnées.
