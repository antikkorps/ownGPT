# OpenCode → passerelle LiteLLM

OpenCode parle le format OpenAI : il pointe sur `https://api.<domaine>/v1` avec la
clé virtuelle **opencode** (modèles `glm`, `devstral`, `mistral-medium` uniquement,
budget 2 $/30 j, masquage des noms désactivé mais cartes / NIR / IBAN / e-mails /
téléphones toujours filtrés).

## Installation

```bash
# 1. Clé : déjà créée par ./scripts/create-keys.sh (valeur LITELLM_KEY_OPENCODE du .env)
export OWNGPT_OPENCODE_KEY="sk-…"

# 2. Config : globale (~/.config/opencode/opencode.json) ou dans un projet (./opencode.json)
cp integrations/opencode/opencode.json ~/.config/opencode/opencode.json
sed -i 's#https://api.exemple.fr#https://api.VOTRE-DOMAINE#' ~/.config/opencode/opencode.json

# 3. Lancer
opencode            # puis /models pour vérifier que « passerelle/glm » est sélectionné
```

## Vérifier

- Tableau de bord LiteLLM (`https://api.<domaine>/ui`) → **Logs** : filtrer par clé
  `opencode` ; chaque appel montre modèle, tokens, coût et guardrail `pii-dev`.
- **Virtual Keys** → `opencode` : dépense cumulée et budget restant.

## Ajuster le budget ou les modèles

```bash
./scripts/litellm-api.sh POST /key/update '{"key":"sk-…clé opencode…","max_budget":10,"models":["glm","devstral"]}'
```
(ou dans l'UI : Virtual Keys → opencode → Edit).
