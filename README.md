# Plateforme IA d'entreprise hybride — démo

> **Ce n'est pas « un chat », c'est la plateforme IA de l'entreprise.**
> L'outil (interface, comptes, historique, règles, assistants métier, accès API) est
> **chez nous** ; le moteur (LLM) est **loué via API** chez des fournisseurs français et
> **interchangeable** (modèle *et* fournisseur). Un **seul point d'entrée gouverné**
> sert le chat, les agents de code et les automatisations.

```
                    ┌──────────── serveur (VPS ou maison) — docker compose ─────────────┐
 Navigateur ──┐     │                                                                   │
 OpenCode ────┤ 443 │  Caddy ──► Open WebUI ──┐                                         │
 Claude Code ─┼────►│    │      (chat, RAG     │                                         │     Mistral (UE)
 Scripts/n8n ─┘     │    │       local)        ▼                                         │ ──► Scaleway (Paris)
                    │    └──────────────► LiteLLM ──► Presidio FR (masque / bloque) ─────┼──► (autres : désactivés)
                    │                     clés virtuelles, budgets, journaux sans contenu│
                    │                PostgreSQL (openwebui + litellm) — jamais exposé      │
                    └───────────────────────────────────────────────────────────────────┘
```

Démo sur **données fictives uniquement**. Scénario de présentation : [DEMO.md](DEMO.md).

## Sommaire

1. [Composants et versions](#1-composants-et-versions)
2. [Prérequis et dimensionnement](#2-prérequis-et-dimensionnement)
3. [Clés API des fournisseurs](#3-clés-api-des-fournisseurs)
4. [Installation — serveur maison (Cloudflare Tunnel ou LAN)](#4-installation--serveur-maison)
5. [Installation — VPS (HTTPS automatique)](#5-installation--vps)
6. [Premier démarrage](#6-premier-démarrage)
7. [Gouvernance : permissions, guardrails, budgets, journaux](#7-gouvernance)
8. [Intégrations (OpenCode, Claude Code, automatisations)](#8-intégrations)
9. [Exploitation : mise à jour, sauvegarde, migration maison → VPS, fin de démo](#9-exploitation)
10. [Durcissement minimal du VPS](#10-durcissement-minimal-du-vps)
11. [Coûts estimés en production (30 personnes)](#11-coûts-estimés-en-production)
12. [SSO avec Authentik](#12-sso-avec-authentik-profil-sso-optionnel)
13. [Dépannage et points à vérifier](#13-dépannage-et-points-à-vérifier)

---

## 1. Composants et versions

Toutes les images sont épinglées (vérifiées le 27/10/2026 dans les registres officiels).

| Service | Image | Rôle |
|---|---|---|
| Caddy | `caddy:2.11.7-alpine` | Reverse proxy, HTTPS Let's Encrypt (VPS) ; seul service exposé (80/443) |
| Open WebUI | `ghcr.io/open-webui/open-webui:v0.12.4` | Interface, comptes, historique, assistants, Knowledge (RAG local), prompts, skills |
| LiteLLM | `ghcr.io/berriai/litellm:v1.106.4` | Passerelle unique : formats OpenAI **et** Anthropic, clés virtuelles, budgets, fallbacks |
| Presidio analyzer | `owngpt/presidio-analyzer-fr` (construit depuis `ghcr.io/data-privacy-stack/presidio-analyzer:2.2.366`) | Détection des données personnelles **en français** (spaCy `fr_core_news_lg`, NIR) |
| Presidio anonymizer | `ghcr.io/data-privacy-stack/presidio-anonymizer:2.2.366` | Masquage |
| PostgreSQL | `postgres:17.11-alpine` | Une instance, deux bases et deux rôles séparés (`openwebui`, `litellm`) |
| cloudflared *(profil `tunnel`)* | `cloudflare/cloudflared:2026.10.4` | Accès public au serveur maison sans IP exposée |
| Authentik *(profil `sso`)* | `ghcr.io/goauthentik/server:2026.8.5` + `postgres:16.15-alpine` | SSO OIDC (Authentik 2026.x n'utilise plus Redis) |

> Presidio est désormais publié sur GHCR (`data-privacy-stack`) : le dépôt MCR historique
> n'a plus de tags.

Arborescence :

```
docker-compose.yml   .env.example   caddy/Caddyfile   postgres/init/
litellm/config.yaml  litellm/config.scaleway.yaml
presidio/            Dockerfile + conf/ (NLP fr, reconnaisseurs dont NIR) + test-analyzer.sh
seed/                assistants, prompts, skill, documents fictifs, groupes + import_seed.py
integrations/        opencode/  claude-code/  automation/
scripts/             gen-secrets, create-keys, litellm-api, test-presidio, test-models,
                     list-provider-models, backup, restore, panne-mistral.yml
```

## 2. Prérequis et dimensionnement

- Ubuntu 24.04 (ou toute distribution récente), Docker Engine ≥ 27 avec le plugin Compose v2,
  `git`, `curl`, `openssl`, `python3` (scripts).
- Mode VPS : IP publique, nom de domaine avec deux enregistrements DNS `chat.` et `api.`
  (+ `auth.` pour le SSO).

**Consommation mesurée** (`docker stats`, démo au repos et en usage léger) :

| Service | Mémoire mesurée | Limite Compose |
|---|---|---|
| Open WebUI (dont modèle d'embeddings local) | ~1,3 Go | 2,5 Go |
| LiteLLM | ~0,6 Go | 1,5 Go |
| Presidio analyzer `fr_core_news_lg` | ~1,2 Go (`md` : ~0,5 Go) | 2 Go |
| Presidio anonymizer | ~60 Mo | 256 Mo |
| PostgreSQL | ~80 Mo | 512 Mo |
| Caddy | ~15 Mo | 128 Mo |
| **Total cœur** | **≈ 3,3 Go** | 6,9 Go |
| *Profil `sso` (Authentik server + worker + postgres)* | *≈ +1,2 à 1,5 Go (estimation)* | *2,25 Go* |

| Usage | RAM | vCPU | Disque |
|---|---|---|---|
| **Démo** (quelques testeurs) | **8 Go** (tient avec le profil `sso`) | 2–4 | 40 Go |
| **Production ~30 utilisateurs** | **16 Go conseillés** (pics d'indexation de documents, plusieurs workers LiteLLM, SSO, marge) | 4–8 | 80 Go + sauvegardes externes |

Le serveur maison (64 Go) est largement suffisant. Une offre VPS à 1 Go **ne suffit pas**.
Aucun GPU n'est nécessaire : seuls l'embedding (RAG) et spaCy tournent localement, sur CPU.

## 3. Clés API des fournisseurs

### Mistral AI (obligatoire)

1. Créer un compte sur <https://console.mistral.ai>, choisir le plan gratuit (allocation
   API mensuelle, limites de débit réduites). Les conditions exactes du plan (allocation,
   débit) sont **à vérifier dans la console** au moment de l'inscription : elles évoluent.
2. **Réglage d'entraînement** : sur les plans gratuits, les données envoyées peuvent servir
   à l'entraînement par défaut. Vérifier dans la console (Admin / Privacy ou équivalent)
   et **désactiver** si l'option existe. En démo, seules des données fictives circulent ;
   en production : plan payant sous contrat, DPA signé, zéro rétention, pas d'entraînement.
3. API Keys → *Create new key* → copier dans `MISTRAL_API_KEY`.
4. Vérifier les identifiants servis par votre compte (GLM, Devstral) :
   `./scripts/list-provider-models.sh mistral` (affiche aussi le support de l'appel d'outils).

Identifiants utilisés (table LiteLLM v1.106.4, à confirmer avec la commande ci-dessus) :
`mistral-small-latest`, `mistral-medium-latest`, `zai-glm-5-3` (GLM 5.3 servi par Mistral
en UE ; `zai-glm-5-2` est retiré le 31/10/2026), `devstral-latest` (Devstral 2 est annoncé
en fin de vie au profit de Medium 3.5 : si l'identifiant n'est plus servi, remplacer par
`mistral/mistral-medium-latest` dans `litellm/config.yaml`).

### Scaleway Generative APIs (optionnel : 2e fournisseur + fallback)

1. Compte sur <https://console.scaleway.com>. Les **1 M de tokens offerts** permettent la
   démo ; une carte bancaire et la vérification d'identité (KYC) sont nécessaires pour
   lever les limites normales (conditions à vérifier sur la page tarifs de Scaleway).
2. IAM → API keys → *Generate* (clé secrète) → `SCALEWAY_API_KEY`.
3. Dans `.env` : `LITELLM_CONFIG=config.scaleway.yaml`, puis
   `./scripts/list-provider-models.sh scaleway` pour confirmer les identifiants et ajuster
   `SCALEWAY_MODEL_DEEPSEEK`, `SCALEWAY_MODEL_QWEN`, `SCALEWAY_MODEL_MISTRAL_SMALL`
   (fournisseur natif LiteLLM `scaleway/…`, base URL `https://api.scaleway.ai/v1`, région fr-par).
4. `docker compose up -d litellm && ./scripts/create-keys.sh` (ajoute `deepseek` et `qwen`
   aux clés et à l'équipe).

## 4. Installation — serveur maison

Accès public via **Cloudflare Tunnel** (aucun port ouvert sur la box) ou accès **LAN**.

```bash
git clone <ce-dépôt> ownGPT && cd ownGPT
cp .env.example .env
./scripts/gen-secrets.sh --apply        # remplit tous les secrets vides de .env (chmod 600)
nano .env                               # MISTRAL_API_KEY, domaines, CLOUDFLARE_TUNNEL_TOKEN
```

**Cloudflare Tunnel** (domaine géré par Cloudflare) :
1. Zero Trust → Networks → Tunnels → *Create a tunnel* → Cloudflared → copier le **token**
   dans `CLOUDFLARE_TUNNEL_TOKEN`.
2. *Public hostnames* : `chat.<domaine>` → `HTTP` `caddy:80` ; `api.<domaine>` → `HTTP` `caddy:80`
   (et `auth.<domaine>` pour le SSO).
3. Dans `.env` (déjà le mode par défaut) : `OPENWEBUI_SITE=http://chat.<domaine>`,
   `LITELLM_SITE=http://api.<domaine>`, `OPENWEBUI_URL=https://chat.<domaine>`, `HTTP_BIND=127.0.0.1`.
4. L'administration LiteLLM (`/ui`, `/login`, API `/key`, `/team`, `/config`…) n'est
   accessible qu'aux IP de `ADMIN_ALLOWED_IPS` (défaut : réseaux privés du LAN). Pour
   administrer depuis l'extérieur : ajouter votre IP publique, ou mieux, créer une
   application **Cloudflare Access** sur `api.<domaine>` en excluant les chemins `/v1/*`
   (utilisés par les outils avec leur clé virtuelle).

```bash
docker compose --profile tunnel up -d --build     # 5–7 min au premier lancement
```

> À savoir (et à dire en démo) : Cloudflare termine le TLS et voit donc le trafic en clair.
> Acceptable pour des données fictives ; en production, serveur chez un hébergeur français
> avec HTTPS de bout en bout (mode VPS).

**LAN sans tunnel** : `OPENWEBUI_SITE=http://chat.192-168-1-10.nip.io`,
`LITELLM_SITE=http://api.192-168-1-10.nip.io`, `OPENWEBUI_URL=` idem, `HTTP_BIND=0.0.0.0`,
puis `docker compose up -d --build`. (`nip.io` résout `x-x-x-x.nip.io` vers l'IP `x.x.x.x`.)

Si les ports 80/443 sont déjà pris sur le serveur : `HTTP_PORT` / `HTTPS_PORT` dans `.env`.

## 5. Installation — VPS

Créer le VPS (Ubuntu 24.04, ≥ 8 Go), pointer `chat.` et `api.` (enregistrements A/AAAA,
**sans proxy Cloudflare** si le domaine y est géré) vers son IP, appliquer le
[durcissement](#10-durcissement-minimal-du-vps), puis :

```bash
curl -fsSL https://get.docker.com | sh
git clone <ce-dépôt> /opt/ownGPT && cd /opt/ownGPT
cp .env.example .env && ./scripts/gen-secrets.sh --apply
nano .env
#   OPENWEBUI_SITE=chat.<domaine>      (sans http:// → HTTPS Let's Encrypt automatique)
#   LITELLM_SITE=api.<domaine>
#   OPENWEBUI_URL=https://chat.<domaine>
#   ACME_EMAIL=vous@<domaine>   HTTP_BIND=0.0.0.0   MISTRAL_API_KEY=…
docker compose up -d --build
```

Caddy obtient les certificats au premier accès (ports 80 et 443 ouverts requis).

## 6. Premier démarrage

Toutes les étapes sont scriptées et idempotentes (relançables sans risque).

```bash
docker compose ps                                     # tous « healthy » (Open WebUI : ~3 min la 1re fois)
./scripts/create-keys.sh                              # budgets, équipe « demo », 4 clés virtuelles
docker compose exec openwebui python3 /seed/import_seed.py   # groupes, comptes, droits, assistants…
./scripts/test-presidio.sh && ./scripts/test-models.sh
```

1. **Administrateur Open WebUI** : créé automatiquement au premier démarrage avec
   `OPENWEBUI_ADMIN_EMAIL` / `OPENWEBUI_ADMIN_PASSWORD` (aucun écran d'inscription public :
   `ENABLE_SIGNUP=false`). Connexion sur `https://chat.<domaine>`.
2. **Modèles** : Open WebUI n'a qu'une connexion, `http://litellm:4000/v1`, avec la clé
   virtuelle `openwebui` ; il voit les modèles de LiteLLM. Pour en ajouter un : l'ajouter dans
   `litellm/config.yaml`, `docker compose restart litellm`, relancer `create-keys.sh` et
   `import_seed.py` (droits par groupe), après avoir ajouté le modèle à `seed/groups.json`.
3. **Groupes et permissions** : créés par `import_seed.py` depuis `seed/groups.json`
   (détail et justification en [§7.1](#71-permissions-open-webui)). Ajouter une personne :
   *Admin → Users → +* puis *Admin → Users → Groups → standard/avancé*.
4. **Seed** : 2 assistants, 1 base Knowledge de 3 procédures fictives (indexée localement),
   3 prompts `/compte-rendu`, `/mail-relance`, `/resume`, 1 skill « reclamation-client ».
   Import manuel possible : *Workspace → Models / Prompts / Skills → Import* (le skill
   s'importe directement depuis `seed/skills/reclamation-client.md`).
5. **Comptes de démo** : `standard@demo.example.com` et `avance@demo.example.com`, mot de
   passe `DEMO_USERS_PASSWORD` du `.env`.
6. **Clés des intégrations** : créées par `create-keys.sh` avec les valeurs `LITELLM_KEY_*`
   du `.env` (reproductible : une réinstallation redonne les mêmes clés).

Tableau de bord LiteLLM : `https://api.<domaine>/ui` (identifiants `LITELLM_UI_USERNAME` /
`LITELLM_UI_PASSWORD`), depuis une IP de `ADMIN_ALLOWED_IPS` uniquement.

## 7. Gouvernance

### 7.1 Permissions Open WebUI

Open WebUI **cumule** les droits (OU logique) : droits par défaut de tous les utilisateurs
+ droits de chacun de leurs groupes. Un groupe ne peut donc qu'**ajouter** des droits.
D'où le choix : **les droits par défaut sont ceux du groupe le plus restreint** (variables
`USER_PERMISSIONS_*` du Compose), les groupes n'ajoutent que le différentiel.

| | standard (= défaut) | avancé | admin (rôle) |
|---|---|---|---|
| Modèles | `mistral-small` | tous les modèles actifs | tous + modèles de test `admin-*` (désactivés) |
| Créer assistants, prompts, skills, Knowledge pour soi | ✅ | ✅ | ✅ |
| Partager avec des groupes | ❌ | ✅ | ✅ |
| Partage public | ❌ | ❌ | ✅ |
| **Tools / Functions** (code Python exécuté sur le serveur) | ❌ | ❌ | ✅ réservé aux administrateurs |
| Recherche web, génération d'images, serveurs d'outils directs, clés API Open WebUI | ❌ | ❌ | — |

Pourquoi :
- **Tools / Functions = exécution de code arbitraire sur le serveur** (équivalent d'un accès
  root au conteneur, avec accès à ses secrets). Aucun utilisateur n'y a accès ; testé : création
  refusée (HTTP 401) pour standard et avancé.
- L'accès aux modèles est porté par les **droits d'accès de chaque modèle** (lecture accordée
  à un groupe), posés par `import_seed.py` depuis `seed/groups.json` (`model_access`).
- Le partage est réservé à « avancé » pour éviter la prolifération d'assistants non relus.
- L'exécution de code de l'interpréteur Open WebUI se fait **dans le navigateur** (Pyodide),
  pas sur le serveur.

> Les variables `USER_PERMISSIONS_*`, `ENABLE_SIGNUP`, etc. ne sont lues qu'au **premier
> démarrage** (ensuite, la configuration est en base : *Admin → Settings*).

### 7.2 Guardrails Presidio (données personnelles)

Analyse **avant** l'envoi au fournisseur (`pre_call`, entrée seulement), en français
(image construite avec spaCy `fr_core_news_lg` + reconnaisseurs déclarés pour `fr`).

| Entité | Action | Exemple |
|---|---|---|
| `CREDIT_CARD` | **BLOCK** (HTTP 400) | 4111 1111 1111 1111 |
| `FR_NIR` (n° de sécurité sociale, reconnaisseur Python avec contrôle de la clé mod 97) | **BLOCK** | 1 85 05 78 006 084 91 |
| `IBAN_CODE` | MASK → `<IBAN_CODE>` | FR76 3000 6000 0112 3456 7890 189 |
| `EMAIL_ADDRESS` | MASK | prenom.nom@exemple.fr |
| `PHONE_NUMBER` | MASK | 06 12 34 56 78, +33 6 … |
| `PERSON` | MASK (sauf agents de code) | Camille Durand |

- **S'applique à toutes les clés** : deux guardrails `default_on`. `pii-standard` (tout) pour
  le chat et les automatisations ; `pii-dev` (tout sauf `PERSON`) pour OpenCode et Claude Code,
  car masquer les noms casserait du code (`class CamilleDurand`, auteurs, identifiants).
  La sélection passe par la métadonnée `opted_out_global_guardrails` (l'équipe « demo » se
  retire de `pii-dev`, les clés de dev se retirent de `pii-standard`). Une clé créée sans
  métadonnée passe par **les deux** : protégée par défaut. (Le choix de guardrails par clé
  est une fonction LiteLLM Enterprise ; le retrait est gratuit.)
- **NIR** : seul un numéro dont la clé de contrôle est valide est bloqué ; sans clé, il faut un
  mot de contexte à proximité (« sécurité sociale », « NIR », « assuré »…). Une référence de
  commande à 13–15 chiffres n'est donc pas bloquée par erreur.
- **Fail-closed** (testé) : si Presidio ne répond pas, la requête est refusée (HTTP 500), rien
  ne part chez le fournisseur.
- **Journaux** : seuls le nom du guardrail et le nombre d'entités par type sont stockés
  (`{"PERSON": 1, "PHONE_NUMBER": 1}`), la réponse brute de Presidio est caviardée par LiteLLM
  et le contenu des messages n'est jamais écrit (§7.4). Le fournisseur et les journaux ne
  voient que le texte masqué.
- **Limites** (à annoncer) : détection statistique. Mesuré sur 20 consignes de bureau : 1 faux
  « nom » (« Traduis… » en début de phrase) avec `lg`, 3 avec `md` ; 8 noms sur 8 détectés.
  Un nom rare, mal orthographié ou en minuscules peut passer. Presidio est un **filet de
  sécurité**, pas un substitut à la règle « pas de données sensibles réelles ».
- Tests : `presidio/test-analyzer.sh` (analyseur seul) et `scripts/test-presidio.sh` (bout en bout).
- Masquer aussi les **réponses** du modèle : `presidio_filter_scope: both` dans
  `litellm/config.yaml` (désactivé : masquerait des noms publics dans les réponses).

### 7.3 Budgets

LiteLLM compte en **dollars**. Valeurs de démo (dans l'allocation gratuite Mistral) :

| Niveau | Démo | Où | Production indicative (30 pers.) |
|---|---|---|---|
| Global passerelle | 9 $ / 30 j (≈ 8 €) | `litellm_settings.max_budget` dans `config.yaml` | ~165 $ (≈ 150 €) |
| Équipe « demo » | 9 $ / 30 j | `create-keys.sh` | une équipe par direction |
| Par utilisateur Open WebUI | 2 $ / 30 j | budget `budget-utilisateur` (`max_end_user_budget_id`) | 5–10 $ |
| Clé `openwebui` | 5 $ | `create-keys.sh` | ~120 $ |
| Clés `opencode` / `claude-code` | 2 $ chacune | `create-keys.sh` | 20–50 $ par développeur |
| Clé `automatisation` | 1 $ | `create-keys.sh` | selon le flux |

Régler :
- **UI** : `https://api.<domaine>/ui` → *Virtual Keys* / *Teams* / *Customers* (utilisateurs
  finaux) → *Edit*.
- **API** (master key) :
  ```bash
  ./scripts/litellm-api.sh POST /key/update '{"key":"sk-…clé openwebui…","max_budget":120}'
  ./scripts/litellm-api.sh POST /team/update '{"team_id":"demo","max_budget":165}'
  ./scripts/litellm-api.sh POST /budget/update '{"budget_id":"budget-utilisateur","max_budget":8}'
  ./scripts/litellm-api.sh GET /key/list
  ```
- **Global** : modifier `max_budget` dans `litellm/config.yaml` puis `docker compose restart litellm`.

Le suivi par personne fonctionne parce qu'Open WebUI transmet l'identité de l'utilisateur
(`ENABLE_FORWARD_USER_INFO_HEADERS`) et que LiteLLM la lit (`user_header_mappings` sur
`X-OpenWebUI-User-Email`). Testé : la dépense apparaît sous `standard@demo.example.com`.
Caddy supprime ces en-têtes sur l'API publique, pour qu'un détenteur d'une autre clé ne
puisse pas imputer sa consommation à quelqu'un d'autre.

### 7.4 Journaux

- **Stocké** (base `litellm`, 90 jours) : date, clé, utilisateur final, équipe, modèle,
  fournisseur effectif (dont fallback), tokens, coût, statut, résultat des guardrails (types
  d'entités comptés).
- **Jamais stocké** : prompts et réponses (`store_prompts_in_spend_logs: false`,
  `turn_off_message_logging: true` ; vérifié en base : colonnes `messages`/`response` vides).
- L'**historique des conversations** est dans Open WebUI (base `openwebui`), visible par
  l'utilisateur et supprimable par lui ; c'est le fonctionnement attendu d'un outil de chat.
  Pour une conservation limitée, définir une politique de purge en production.

## 8. Intégrations

Une clé virtuelle **par usage** (budget, modèles autorisés et journaux propres) :

| Clé | Modèles | Guardrail | Doc |
|---|---|---|---|
| `openwebui` | tous les actifs (filtrés par groupe dans Open WebUI) | pii-standard | — |
| `opencode` | glm, devstral, mistral-medium | pii-dev | [integrations/opencode](integrations/opencode/README.md) |
| `claude-code` | glm, devstral, mistral-medium | pii-dev | [integrations/claude-code](integrations/claude-code/README.md) |
| `automatisation` | mistral-small | pii-standard | [integrations/automation](integrations/automation/README.md) |

Endpoints : OpenAI `https://api.<domaine>/v1` · Anthropic `https://api.<domaine>/v1/messages`
(`test-models.sh` teste les deux en mode non streamé ; le streaming `/v1/messages` a été vérifié
à la mise au point). Vérifier les appels : UI LiteLLM → *Logs* (filtre par clé)
et *Usage*.

## 9. Exploitation

**Mise à jour** : modifier les tags dans `docker-compose.yml` (lire les notes de version),
puis `./scripts/backup.sh && docker compose pull && docker compose up -d --build`,
puis `test-presidio.sh` et `test-models.sh`.

**Sauvegarde** : `./scripts/backup.sh` → `backups/ownGPT-<date>.tar.enc` (un dump par base,
Authentik compris si le profil `sso` tourne, + volumes Open WebUI et certificats ; chiffré
AES-256 avec `BACKUP_PASSPHRASE` puis **authentifié** par un HMAC-SHA256 (`.tar.enc.mac`),
rotation `BACKUP_KEEP_DAYS`). Le cache des modèles
d'embeddings (~4 Go) est exclu : il est retéléchargé. Les fichiers intermédiaires non chiffrés
ne sortent jamais du dossier de sauvegarde (droits 700) et sont effacés à la fin. Cron conseillé : `0 3 * * * cd /opt/ownGPT && ./scripts/backup.sh`.
Copier les archives **hors du serveur** et conserver `.env` (ou au moins la phrase de passe
et `LITELLM_SALT_KEY`) séparément.

**Restauration** : `./scripts/restore.sh backups/ownGPT-<date>.tar.enc`. L'archive est
authentifiée (fichier `.mac`) et déchiffrée **avant** tout arrêt de service : une archive
modifiée ou sans `.mac` est refusée et la plateforme continue de tourner
(`./scripts/test-backup.sh` le vérifie). Arrêt à la première erreur SQL ; testée : une donnée
créée après la sauvegarde disparaît. Copier l'archive **et** son `.mac`.

**Migration maison → VPS (< 15 min)** :
1. Maison : `./scripts/backup.sh` ; copier l'archive, son `.mac` et `.env` sur le VPS
   (`scp backups/ownGPT-<date>.tar.enc* .env vps:/opt/ownGPT/backups/` puis déplacer `.env`).
2. VPS (Docker installé, dépôt cloné) : dans `.env`, passer en mode VPS (adresses sans
   `http://`, `OPENWEBUI_URL=https://…`, `ACME_EMAIL`, `HTTP_BIND=0.0.0.0`).
3. DNS : supprimer les *public hostnames* du tunnel, créer les enregistrements A vers le VPS.
4. `docker compose build && docker compose up -d postgres && ./scripts/restore.sh <archive>`
   (relance tout).
5. `./scripts/test-presidio.sh && ./scripts/test-models.sh`.

**Après la démo (VPS)** : `./scripts/backup.sh`, récupérer l'archive et `.env`, faire un
**snapshot** du VPS dans la console Hetzner (facturé tant qu'il existe), puis **supprimer le
serveur**. Révoquer ou régénérer les clés Mistral / Scaleway si elles ont été montrées.

## 10. Durcissement minimal du VPS

```bash
adduser admin && usermod -aG sudo admin            # puis copier sa clé : ssh-copy-id admin@vps
sudo tee /etc/ssh/sshd_config.d/10-durcissement.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
EOF
sudo systemctl restart ssh
sudo apt update && sudo apt install -y ufw unattended-upgrades fail2ban
sudo ufw default deny incoming && sudo ufw allow OpenSSH && sudo ufw allow 80,443/tcp && sudo ufw allow 443/udp
sudo ufw enable
sudo dpkg-reconfigure -plow unattended-upgrades    # mises à jour de sécurité automatiques
```

- **Attention** : les ports publiés par Docker contournent UFW. Ici seuls 80/443 sont publiés
  (les bases et services internes n'ont **aucun** port sur l'hôte) ; ne pas en ajouter.
- Utiliser aussi le pare-feu de la console Hetzner (22 limité à votre IP, 80/443 ouverts).
- Administration LiteLLM et console Authentik : réservées à `ADMIN_ALLOWED_IPS` (défaut :
  réseaux privés). Sur un VPS, mettre `ADMIN_ALLOWED_IPS="<votre IP>/32"` ; seules les routes
  de modèles (`/v1/chat/completions`, `/v1/messages`, `/v1/models`…) restent publiques, avec
  clé virtuelle obligatoire. Caddy ne croit l'IP client transmise que si elle vient de
  cloudflared (`CLOUDFLARED_IP`). Ne jamais ajouter 172.16.0.0/12 (passerelle Docker).
- Les en-têtes d'identité `X-OpenWebUI-*` sont supprimés par Caddy sur l'API publique : seul
  Open WebUI (en interne) peut attribuer une dépense à un utilisateur.
- Vérification hors ligne : `./caddy/test-caddy.sh` (lancé par `scripts/check.sh` et la CI).
- `.env` est créé en 600 par `gen-secrets.sh` (umask 077) ; les scripts le lisent sans
  l'exécuter, et ne passent ni clé ni secret en argument de commande (invisibles dans `ps`).

## 11. Coûts estimés en production

Hypothèses : 30 personnes, 22 jours ouvrés/mois, prix publics en $ par million de tokens
(entrée/sortie) de la table LiteLLM v1.106.4 : Mistral Small 0,15/0,60 · Medium 1,50/7,50 ·
GLM 5.3 1,40/4,40, **à revérifier sur les pages tarifs** avant engagement ; 1 $ ≈ 0,90 €.

| Scénario | Usage par personne et par jour | Répartition | API / mois |
|---|---|---|---|
| **Léger** | 10 requêtes, ~2 500 tokens | 80 % Small, 20 % Medium | **≈ 10–15 €** |
| **Standard** | 30 requêtes avec documents (RAG), ~3 700 tokens | 60 % Small, 30 % Medium, 10 % GLM | **≈ 75–90 €** |
| **Intensif** | 60 requêtes, ~4 800 tokens + 5 développeurs avec agents de code (~3 M tokens/jour chacun sur GLM) | 50/40/10 + agents | **≈ 700–800 €** (dont ~550 € d'agents de code) |

| Poste | Coût mensuel |
|---|---|
| Serveur 16 Go (VPS ou dédié, hébergeur français ou UE) | ≈ 25–60 € selon l'offre (à vérifier, les prix ont augmenté en 2026) |
| Sauvegardes externes (stockage objet) | ≈ 1–5 € |
| API — scénario standard | ≈ 75–90 € |
| **Total indicatif scénario standard** | **≈ 100–150 €/mois** → budget global conseillé 150 € (165 $) |

Le **temps de maintenance n'est pas inclus** (mises à jour mensuelles, supervision,
sauvegardes, support utilisateurs : prévoir quelques heures par mois). Les agents de code
sont le poste qui varie le plus : leur donner des clés et budgets séparés.

## 12. SSO avec Authentik (profil `sso`, optionnel)

```bash
docker compose --profile sso up -d       # + ~1,5 Go de RAM
```
1. Attendre ~2 min (création des flux par le worker), puis ouvrir `https://auth.<domaine>/` :
   redirection vers l'assistant d'installation, créer le compte `akadmin`.
2. *Applications → Create with provider* : **OAuth2/OpenID**, type *Confidential*,
   redirect URI `https://chat.<domaine>/oauth/oidc/login/callback`, scopes
   `openid email profile` ; slug de l'application : `openwebui`. Exiger des **e-mails vérifiés**
   (politique d'inscription Authentik).
3. Dans `.env` : `ENABLE_OAUTH_SIGNUP=true`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`,
   `OPENID_PROVIDER_URL=https://auth.<domaine>/application/o/openwebui/.well-known/openid-configuration`.
   Pour synchroniser les groupes Authentik vers Open WebUI : `ENABLE_OAUTH_GROUP_MANAGEMENT=true`
   et ajouter le claim `groups` (property mapping).
4. `docker compose up -d openwebui` : le bouton « Continuer avec Authentik » apparaît. Les
   nouveaux comptes SSO arrivent en rôle `pending` (validation par un admin).

`OAUTH_MERGE_ACCOUNTS_BY_EMAIL` reste à `false` : sinon un compte SSO avec un e-mail non vérifié
pourrait prendre le contrôle d'un compte local du même e-mail, y compris l'administrateur.

## 13. Dépannage et points à vérifier

| Symptôme | Cause / solution |
|---|---|
| `401 Invalid API Key` (Mistral), puis `429 … in cooldown` quelques secondes | Clé fournisseur invalide ; après un échec LiteLLM met le déploiement en pause quelques secondes. |
| `400 Blocked entity detected: CREDIT_CARD/FR_NIR` | Comportement voulu (guardrail). |
| Une consigne commence par `<PERSON>` | Faux positif spaCy sur un verbe à l'impératif ; reformuler, ou passer la clé concernée en `pii-dev`. |
| `403 Accès refusé` sur `/ui` | IP hors `ADMIN_ALLOWED_IPS`. Depuis le serveur lui-même (`localhost`), la requête arrive par la passerelle Docker, volontairement exclue : utiliser un autre poste du LAN, ou `./scripts/litellm-api.sh` pour l'API. |
| Open WebUI ne voit aucun modèle | Clé `openwebui` non enregistrée : `./scripts/create-keys.sh`. |
| Modifier `config.yaml` n'a aucun effet | `docker compose restart litellm` (un `up -d` ne redémarre pas si seul un fichier monté change). |
| Changement de variable Open WebUI sans effet | Lue au premier démarrage seulement : *Admin → Settings*. |
| Devstral / GLM : `model not found` | Identifiant à jour : `./scripts/list-provider-models.sh mistral`. |

Points **non vérifiables sans compte** au moment de l'écriture (à contrôler une fois les clés
obtenues) : identifiants exacts GLM / Devstral / Scaleway sur votre compte, conditions du plan
gratuit Mistral et des 1 M tokens Scaleway, support réel de l'appel d'outils par chaque modèle
(`test-models.sh` le vérifie).
