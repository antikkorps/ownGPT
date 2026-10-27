# Claude Code → passerelle LiteLLM (endpoint Anthropic `/v1/messages`)

LiteLLM expose le format Anthropic sur `https://api.<domaine>/v1/messages` et le
traduit vers n'importe quel modèle de la passerelle. Claude Code s'y connecte avec la
clé virtuelle **claude-code** (modèles `glm`, `devstral`, `mistral-medium`, budget
2 $/30 j).

Sources vérifiées : <https://code.claude.com/docs/en/llm-gateway-connect> et
<https://docs.litellm.ai/docs/proxy/client_setup/claude_code>.

## Installation

Le plus simple : le bloc `env` de `~/.claude/settings.json` (s'applique aussi aux agents
en arrière-plan). Copier [`settings.example.json`](settings.example.json) vers
`~/.claude/settings.json` (jamais dans le dépôt : il contiendra une clé), remplacer le domaine
et la clé (`LITELLM_KEY_CLAUDECODE` du `.env`), puis :

```bash
unset ANTHROPIC_API_KEY   # sinon Claude Code l'enverrait à la place de la clé virtuelle
claude                    # puis /status : « Anthropic base URL » doit montrer la passerelle
```

Ou en variables de shell, pour un essai :

```bash
export ANTHROPIC_BASE_URL="https://api.exemple.fr"
export ANTHROPIC_AUTH_TOKEN="sk-…"          # clé virtuelle claude-code
export ANTHROPIC_MODEL="glm"
export ANTHROPIC_DEFAULT_OPUS_MODEL="glm" ANTHROPIC_DEFAULT_SONNET_MODEL="glm"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="mistral-medium"   # tâches de fond (titres…)
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1          # champs bêta refusés hors Anthropic
```

Test de connexion sans Claude Code :

```bash
curl -sS "$ANTHROPIC_BASE_URL/v1/messages" -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"glm","max_tokens":20,"messages":[{"role":"user","content":"Dis OK"}]}'
```

**Mapping des modèles** : Claude Code demande des noms de modèles Claude ; chaque nom
qu'il envoie doit exister comme `model_name` dans LiteLLM, sinon `Invalid model name`.
Les variables `ANTHROPIC_DEFAULT_*_MODEL` font envoyer `glm` / `mistral-medium` à la place.

## Limites à annoncer honnêtement

- **Anthropic ne prend pas en charge Claude Code avec des modèles non-Claude** (doc
  officielle des passerelles). Ça fonctionne techniquement, mais Claude Code est optimisé
  pour Claude : avec GLM, attendre plus d'erreurs d'outils, des plans moins fiables et
  des fonctions indisponibles (réflexion adaptative, vision selon le modèle).
- Pour un usage de développement sérieux avec des modèles non-Claude, **OpenCode** est
  mieux adapté (conçu multi-fournisseurs).
- **Option groupe « dev »** : décommenter le bloc Anthropic de `litellm/config.yaml`
  (`claude-sonnet`, `ANTHROPIC_API_KEY`), puis créer une clé dédiée limitée à ce modèle :
  ```bash
  ./scripts/litellm-api.sh POST /key/generate '{"key_alias":"claude-code-dev","team_id":"demo",
    "models":["claude-sonnet"],"max_budget":50,"budget_duration":"30d",
    "metadata":{"usage":"dev"}}'
  ./scripts/litellm-api.sh POST /team/update '{"team_id":"demo","models":["mistral-small","mistral-medium","glm","devstral","claude-sonnet"]}'
  ```
  (une clé ne peut utiliser que des modèles autorisés aussi pour son équipe).
  Les données partent alors chez Anthropic (DPA à signer, hébergement hors UE par défaut) :
  à valider avec la RSSI avant toute donnée réelle.

## Vérifier

Tableau de bord LiteLLM → **Logs** (filtre clé `claude-code`) : route `/v1/messages`,
modèle `glm`, tokens et coût. Budget : **Virtual Keys** → `claude-code`.
