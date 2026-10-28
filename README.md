# cc-archiver

Systeme d'archives pour **CC: Tweaked** (ComputerCraft). Un serveur stocke les documents, des ordinateurs avances les lisent et les ecrivent, et un ordinateur d'administration gere le tout. Chaque archive garde l'emplacement reel dans Minecraft (identifiant de coffre).

## Installation

Sur chaque ordinateur, avec un modem sans fil :

```
wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
```

Choisis le role (1 serveur, 2 client, 3 administration), puis redemarre.

- **Ordinateur d'administration** : premiere connexion = identifiant + mot de passe. C'est le seul ordinateur d'administration.
- **Client** : premiere connexion = identifiant + **code a 6 chiffres** genere sur l'ordinateur d'administration (menu 9), valable 5 minutes. Ensuite la connexion est automatique.

## Mot de passe administrateur

Le mot de passe de l'ordinateur d'administration sert de **mot de passe maitre** sur tous les ordinateurs : il est demande pour supprimer une archive depuis un client.

## Utilisateurs

Lire, creer et modifier une archive demandent un **identifiant utilisateur**, cree par l'administrateur (menu 6). Un client ne fonctionne donc qu'avec un ordinateur enregistre **et** un utilisateur connecte.

## Droits

| Action | Utilisateur (client) | Administration |
|---|---|---|
| Lister, lire | oui | oui |
| Creer, modifier une archive | oui | oui |
| Supprimer une archive | oui, avec le mot de passe administrateur | oui |
| Gerer les utilisateurs, codes d'enregistrement | non | oui |
| Connexion a distance | non | oui |

## Verrouillage

L'ordinateur d'administration se verrouille avec l'option 0 ; seul le mot de passe administrateur le rouvre. Le verrouillage est un verrou d'ecran : Ctrl+T contourne.

## Connexion a distance

Depuis l'administration (menu 7) : afficher l'etat d'un client (nom, version, utilisateur connecte) ou le redemarrer. Ce n'est **pas** un shell a distance.

## Mises a jour

- Automatiques : au demarrage, chaque programme verifie la version sur le depot.
- Manuelles : option **Mise a jour** dans le menu.

Pour publier une mise a jour : augmenter `VERSION` dans le fichier concerne, puis pousser sur `main`.

## Securite

Les mots de passe et jetons sont hashes avec un sel maison, **non cryptographique**. Le trafic sans fil est en clair. Suffisant pour un reseau de jeu, pas plus.

## Structure

```
server/server.lua   serveur (archives, ordinateurs, utilisateurs)
client/client.lua   ordinateur client
admin/admin.lua     ordinateur d'administration
install.lua         installateur
```

## Donnees serveur

- `/archives/docs/<id>.dat` : une archive
- `/archives/computers.dat` : ordinateurs (sel, hash, admin)
- `/archives/users.dat` : utilisateurs (sel, hash)
- `/archives/counter.dat` : prochain identifiant

Les ordinateurs enregistres avant la 2.1 doivent se re-enregistrer avec un code (le jeton n'existait pas).
