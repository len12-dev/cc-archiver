# cc-archiver

Système d'archives pour **CC: Tweaked** (ComputerCraft) : un serveur qui stocke les documents et des clients (ordinateurs avancés) qui les lisent et les écrivent. Chaque archive garde l'emplacement réel dans Minecraft (identifiant de coffre).

```
[Client] Advanced Computer  ──(modem sans fil, rednet)──  [Serveur] EliteCompute
```

## Installation

### Serveur (EliteCompute)
Prérequis : un modem sans fil (ou filaire relié au réseau).

```
wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
```
Choisis `1`, puis redémarre. Les données sont dans `/archives/`.

### Client (ordinateur avancé)
Prérequis : un modem sans fil dans portée du serveur.

```
wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
```
Choisis `2`, puis redémarre.

**Première connexion** : tu définis l'identifiant de l'ordinateur et son mot de passe administrateur. Les connexions suivantes demandent seulement le mot de passe.

## Utilisation

| Touche | Action |
|---|---|
| 1 | Lister les archives |
| 2 | Lire une archive |
| 3 | Nouvelle archive : nom, puis identifiant du coffre, puis texte (`/fin` pour terminer) |
| 4 | Modifier : ajouter à la fin, ou tout réécrire |
| 5 | Supprimer (mot de passe administrateur + confirmation `SUPPRIMER`) |

## Règles d'accès

- Tout ordinateur enregistré peut **créer et modifier** des archives.
- **Supprimer** exige le mot de passe administrateur de l'ordinateur **et** être l'ordinateur qui a créé l'archive.

## Sécurité

Le hash des mots de passe est maison et salé. Il suffit pour un réseau de jeu, mais ce n'est **pas cryptographique**. Les mots de passe transitent en clair sur le réseau sans fil de Minecraft. Ne réutilise pas un mot de passe important.

## Structure

```
server/server.lua   serveur (archives + comptes)
client/client.lua   client (interface terminal)
install.lua         installateur
```

## Données serveur

- `/archives/docs/<id>.dat` : une archive (nom, coffre, auteur, lignes)
- `/archives/users.dat` : comptes (sel + hash)
- `/archives/counter.dat` : prochain identifiant

## Mises à jour automatiques

Au démarrage, serveur et client vérifient la version sur le dépôt. Si une version plus récente existe, elle est téléchargée, installée et relancée automatiquement. Sans connexion, le programme démarre avec la version locale.

Pour publier une mise à jour : changer `VERSION` dans `server/server.lua` et/ou `client/client.lua`, puis pousser sur `main`.
