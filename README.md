# cc-archiver

Systeme d'archives pour **CC: Tweaked** (ComputerCraft). Un serveur stocke les documents, des ordinateurs avances les lisent et les ecrivent, et un ordinateur d'administration gere le tout. Chaque archive garde l'emplacement reel dans Minecraft (identifiant de coffre).

```
[Client] Ordinateur avance ──┐
                             ├── (modem sans fil) ── [Serveur] EliteCompute
[Admin]  Ordinateur admin  ──┘
```

## Installation

Sur chaque ordinateur, avec un modem sans fil :

```
wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
```

Choisis le role (1 serveur, 2 client, 3 administration), puis redemarre.

- **Premiere connexion d'un client** : identifiant de l'ordinateur + mot de passe administrateur de cet ordinateur.
- **Premiere connexion de l'administration** : elle devient l'ordinateur d'administration. Il n'y en a qu'un.

## Utilisateurs

Lire, creer et modifier une archive demandent un **identifiant utilisateur**, cree par l'administrateur (menu 6). Un ordinateur client ne fonctionne donc qu'avec un ordinateur enregistre **et** un utilisateur connecte.

## Droits

| Action | Utilisateur (client) | Administration |
|---|---|---|
| Lister, lire | oui | oui |
| Creer, modifier une archive | oui | oui (librement) |
| Supprimer une archive | seulement celles de son ordinateur | oui (librement) |
| Gerer les utilisateurs | non | oui |
| Connexion a distance | non | oui |

## Connexion a distance

Depuis l'administration (menu 7), on liste les ordinateurs du reseau et on peut :
- afficher leur etat (nom, version, utilisateur connecte) ;
- les redemarrer.

Ce n'est **pas** un shell a distance. Un client ne peut executer que ces deux commandes, et seulement pour l'administrateur.

## Mises a jour

- Automatiques : au demarrage, chaque programme verifie la version sur le depot et se met a jour si besoin.
- Manuelles : option **Mise a jour** dans le menu.

Pour publier une mise a jour : augmenter `VERSION` dans le fichier concerne, puis pousser sur `main`.

## Securite

Le hash des mots de passe est maison et sale. Il suffit pour un reseau de jeu, mais il n'est **pas cryptographique**. Les mots de passe transitent en clair sur le reseau sans fil. Ne reutilise pas un mot de passe important.

## Structure

```
server/server.lua   serveur (archives, ordinateurs, utilisateurs)
client/client.lua   ordinateur client
admin/admin.lua     ordinateur d'administration
install.lua         installateur
```

## Donnees serveur

- `/archives/docs/<id>.dat` : une archive
- `/archives/computers.dat` : ordinateurs enregistres (sel, hash, admin)
- `/archives/users.dat` : utilisateurs (sel, hash)
- `/archives/counter.dat` : prochain identifiant

Une installation en 1.x est convertie automatiquement au premier demarrage.
