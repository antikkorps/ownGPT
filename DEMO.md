# Scénario de démonstration — CODIR & RSSI (15 minutes)

Préparer **deux fenêtres** : navigateur sur `https://chat.<domaine>` (onglet admin + onglet
privé pour le compte standard) et `https://api.<domaine>/ui` (tableau de bord LiteLLM, page
*Logs*). Un terminal ouvert dans le dossier du projet. Toutes les données sont **fictives**.

---

## 0. Introduction (30 s)

> « Ce que vous allez voir tourne sur des comptes de test, avec le plan gratuit des
> fournisseurs et uniquement des données fictives. En production, nous prendrions des
> comptes payants sous contrat, avec DPA signé, zéro rétention des données et aucun
> entraînement sur nos données. »

## 1. Connexion, interface, historique (1 min)

Se connecter (compte admin). Montrer : la liste des conversations, la recherche, le
choix du modèle en haut, l'espace *Workspace*.

> « Les comptes sont créés par nous, pas d'inscription libre. L'historique reste chez nous,
> dans notre base. Demain, on branche le SSO de l'entreprise. »

## 2. Le moteur est interchangeable (2 min)

Nouvelle conversation, modèle **mistral-small** :

```
Explique en 5 lignes à un comité de direction ce qu'est le RGPD et ce que cela change pour un projet d'IA.
```

Cliquer sur le nom du modèle → **glm** → *Regénérer* (même question).

> « Même question, autre modèle : rien d'autre ne change pour l'utilisateur. GLM est un
> modèle chinois, mais servi par Mistral sur son infrastructure européenne. »

*Si Scaleway est configuré* : même question avec **deepseek**.

> « Là, ce n'est plus le même fournisseur : Scaleway, à Paris. Changer de fournisseur, c'est
> une ligne de configuration, pas un projet. Et si Mistral tombe, mistral-small bascule
> automatiquement chez Scaleway. »

(Option spectaculaire, 1 min, **uniquement si Scaleway est configuré** : `docker compose -f docker-compose.yml -f scripts/panne-mistral.yml up -d --wait litellm`,
reposer une question à mistral-small, montrer dans *Logs* le modèle `mistral-small-secours`,
puis `docker compose up -d --wait litellm`.)

## 3. Protection des données personnelles (2 min)

Modèle **mistral-small** :

```
Prépare un message pour rappeler Camille Durand au 06 12 34 56 78 au sujet de son dossier, et propose-lui un rendez-vous jeudi.
```

La réponse parle d'un « <PERSON> » et d'un « <PHONE_NUMBER> ». Aller dans LiteLLM → *Logs* →
dernière ligne → *Guardrails* : `pii-standard`, `PERSON: 1`, `PHONE_NUMBER: 1`.

> « Le nom et le téléphone ont été masqués **avant** de quitter notre serveur. Le fournisseur
> ne les a jamais vus. Et nos journaux ne gardent même pas le texte : seulement le fait qu'un
> nom et un téléphone ont été masqués. »

Puis :

```
Peux-tu régler la facture avec ma carte 4111 1111 1111 1111, expiration 12/28 ?
```

→ message d'erreur « Blocked entity detected: CREDIT_CARD ».

> « Une carte bancaire, ou un numéro de sécurité sociale, ne sort pas : la requête est
> bloquée. »

## 4. Assistant métier sur nos documents (2 min)

Sélectionner **Assistant procédures internes** :

```
Je pars 4 jours à Paris pour un salon. Quel est le plafond pour l'hôtel et le repas, et sous quel délai dois-je saisir ma note ?
```

puis :

```
Combien de jours de télétravail puis-je faire, et quels jours suis-je obligé de venir ?
```

Montrer les **sources citées** (procédure notes de frais, charte télétravail).

> « L'assistant répond à partir de nos procédures, et cite ses sources. Les documents sont
> indexés sur notre serveur : rien n'est envoyé à un service externe pour la recherche. »

## 5. Créer un assistant en 2 minutes, sans développement (2 min 30)

*Workspace → Models → +* :
- Nom : `Assistant accueil RH`
- Modèle de base : `mistral-small`
- Consigne système :
  ```
  Tu aides les managers à préparer l'arrivée d'un nouveau collaborateur. Réponds en liste de tâches datées (J-15, J, J+7, J+30), à partir du document joint uniquement.
  ```
- Knowledge : joindre `accueil-nouvel-arrivant.md` (ou la collection « Procédures internes »)
- Enregistrer, puis :
  ```
  Un développeur arrive lundi 2 novembre dans mon équipe. Que dois-je faire et quand ?
  ```

Puis, dans une conversation avec **Rédacteur de comptes rendus**, taper **`/compte-rendu`**
et remplir les champs :
- objet : `Point d'avancement projet Atlas`
- date : `27/10/2026`
- participants : `direction des opérations, DSI, qualité`
- notes :
  ```
  retard de 2 semaines sur la recette - prestataire relancé - go/no-go repoussé au 15/11 - qualité veut un test de charge avant - DSI ok pour un environnement de préprod d'ici le 05/11 - budget inchangé
  ```

> « Chaque métier peut créer ses assistants et ses modèles de prompts, sans développement ni
> ticket à la DSI. Ceux qui ont les droits les partagent avec leur équipe. »

## 6. Droits par groupe (1 min 30)

Onglet privé, compte **standard@demo.example.com** :
- liste des modèles : **mistral-small** et les assistants seulement ;
- *Workspace* : pas d'entrée **Tools** ni **Functions** ;
- *Workspace → Models* : création possible, mais pas de partage.

> « Le droit d'utiliser un modèle plus cher, de partager un assistant, et surtout d'exécuter
> du code sur le serveur, se donne par groupe. L'exécution de code est réservée aux
> administrateurs : personne d'autre n'y a accès. »

## 7. Au-delà du chat : même passerelle (2 min)

Terminal :

```bash
export OWNGPT_OPENCODE_KEY=…   # LITELLM_KEY_OPENCODE
opencode run "Écris une fonction Python qui valide un IBAN français, avec ses tests."
```

Puis l'automatisation :

```bash
export OWNGPT_API_URL=https://api.<domaine> OWNGPT_AUTOMATION_KEY=…   # LITELLM_KEY_AUTOMATION
python3 integrations/automation/resume_document.py integrations/automation/document-exemple.txt
```

> « Les développeurs et les scripts passent par la même porte : même filtrage, même
> journalisation, même budget. Pas de clés de fournisseurs qui traînent sur les postes. »

## 8. Tableau de bord : tout au même endroit (1 min)

LiteLLM → *Usage* : dépense par clé (`openwebui`, `opencode`, `automatisation`), par
utilisateur (*Customers* : `standard@demo.example.com`…), par modèle ; budgets restants
(*Virtual Keys*, *Teams*).

> « On voit qui consomme quoi, avec quel outil, et combien. Chaque usage a son plafond. »

## 9. Conclusion (30 s)

> « Ce n'est pas un chat, c'est notre plateforme IA : l'outil est à nous, le moteur est
> interchangeable, et il y a un seul point d'entrée gouverné. La suite : contractualiser
> avec un ou deux fournisseurs français, et ajuster les modèles selon l'usage réel qu'on
> mesurera ici. »

---

## Questions probables de la RSSI

**Où vont les données ?**
Interface, comptes, historique, documents et index de recherche restent sur notre serveur.
Seul le texte de la requête, après masquage, part chez le fournisseur choisi : Mistral
(France/UE) ou Scaleway (Paris). Pendant la démo, le serveur de démonstration est hébergé hors datacenter et l'accès passe par
Cloudflare Tunnel : Cloudflare termine le chiffrement HTTPS et voit donc le trafic en clair.
Acceptable pour des données fictives ; en production, hébergement français avec HTTPS de bout
en bout jusqu'à notre serveur, sans intermédiaire.

**Qui y a accès ?**
Les utilisateurs voient leurs propres conversations. Les administrateurs de la plateforme ont
accès à la base (comme pour tout outil métier) : à encadrer par la charte admin et la
journalisation système. Côté fournisseur : contrat, DPA, zéro rétention en production.

**Que contiennent les logs ?**
LiteLLM : date, clé, utilisateur, modèle, tokens, coût, et le résultat du filtrage
(« 1 nom, 1 téléphone masqués »). **Pas le contenu** des messages ni des réponses (vérifié en
base). Conservation : 90 jours.

**Et si Presidio rate quelque chose ?**
C'est une détection statistique : un filet de sécurité, pas une garantie. Il analyse le texte
des messages (chat, documents injectés, résultats d'outils au format OpenAI), mais pas les
images, ni le prompt système de premier niveau et les résultats d'outils du format Anthropic
utilisé par Claude Code : ces usages-là restent sous la règle « pas de données réelles ». Mesuré : tous les
noms courants détectés, quelques faux positifs. Ce qui passe ne part que chez un fournisseur
sous contrat (DPA, zéro rétention, UE). La règle reste : pas de données sensibles réelles sans
validation, et formation des utilisateurs. Les cartes et NIR (clé de contrôle vérifiée) sont
**bloqués**, et si Presidio est indisponible, **tout est refusé** (fail-closed, testé).

**Qui peut exécuter du code sur le serveur ?**
Personne, sauf le rôle administrateur (Tools / Functions d'Open WebUI). Testé : la création est
refusée aux utilisateurs standard et avancés. L'interpréteur de code du chat s'exécute dans le
navigateur de l'utilisateur, pas sur le serveur.

**Comment sont protégées les clés API ?**
Les clés des fournisseurs n'existent qu'à un endroit, la passerelle (fichier `.env` non
versionné, droits 600). Les outils reçoivent des **clés virtuelles** propres à chaque usage,
avec budget et modèles autorisés, révocables à tout moment sans toucher aux clés des
fournisseurs. Les bases de données ne sont pas exposées sur le réseau.

**Pourquoi un modèle chinois comme GLM peut-il être acceptable ?**
Le risque ne tient pas à l'origine des poids du modèle, mais à **qui l'exécute et où vont les
données**. Ici, GLM est exécuté par Mistral, sur son infrastructure européenne, sous son contrat
et son DPA : les données ne vont ni en Chine ni chez l'éditeur Z.ai. Un modèle ne « téléphone »
pas à son créateur ; c'est un fichier de poids. À l'inverse, les API de Moonshot (Kimi) ou de
DeepSeek en direct stockent les données en Chine : elles sont désactivées, réservées à des tests
d'administrateur, jamais avec des données réelles. Reste à évaluer les biais du modèle, comme
pour tout modèle.

---

## Checklist « veille de démo »

- [ ] Serveur à jour : `sudo apt update && sudo apt upgrade -y`, redémarrage si noyau mis à jour
- [ ] `docker compose ps` : tous les services `healthy`
- [ ] `./scripts/test-presidio.sh` → **RÉSULTAT : OK**
- [ ] `./scripts/test-models.sh` → **RÉSULTAT : OK** (fallback Scaleway inclus s'il est configuré)
- [ ] Comptes de démo : connexion `standard@demo.example.com` et `avance@demo.example.com`
- [ ] Seed présent : 2 assistants, 3 prompts, 1 skill, Knowledge « Procédures internes »
      (`docker compose exec openwebui python3 /seed/import_seed.py` est relançable)
- [ ] Clés des intégrations testées : `opencode run "dis bonjour"`, `resume_document.py`
- [ ] Budget restant suffisant : LiteLLM → *Usage* (global < 9 $) et console Mistral
      (allocation du mois)
- [ ] Supprimer les conversations de répétition (admin) pour partir d'un historique propre
- [ ] Sauvegarde fraîche : `./scripts/backup.sh`
- [ ] Plan B réseau : partage de connexion 4G testé (le tunnel n'a besoin d'aucun port ouvert)
- [ ] Onglets prêts : chat (admin), chat privé (standard), LiteLLM *Logs*, terminal
