# cc-archiver

Systeme d'archives pour **CC: Tweaked** (ComputerCraft). Un serveur stocke les documents, des ordinateurs clients les lisent et les ecrivent, un ordinateur d'administration gere le tout, et un serveur d'impression imprime les archives. Chaque archive garde l'emplacement reel dans Minecraft (identifiant de coffre).

## Installation

Sur chaque ordinateur, avec un modem sans fil :

```
wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
```

Choisis le role (1 serveur, 2 client, 3 administration, 4 serveur d'impression), puis redemarre.

- **Administration** : premiere connexion = identifiant + mot de passe. C'est le seul ordinateur d'administration.
- **Client et serveur d'impression** : premiere connexion = identifiant + **code a 6 chiffres** genere sur l'administration (menu 9), valable 5 minutes. Ensuite la connexion est automatique.

## Mot de passe administrateur

Le mot de passe de l'administration sert de **mot de passe maitre** sur tous les ordinateurs : il est demande pour supprimer une archive depuis un client.

## Utilisateurs

Lire, creer et modifier une archive demandent un **identifiant utilisateur**, cree par l'administrateur (menu 6).

## Droits

| Action | Utilisateur (client) | Administration |
|---|---|---|
| Lister, lire | oui | oui |
| Creer, modifier une archive | oui | oui |
| Ajouter en fin d'archive hors ligne | oui | - |
| Supprimer une archive | oui, avec le mot de passe administrateur, en ligne seulement | oui |
| Imprimer une archive | oui | oui |
| Gerer les utilisateurs, codes, journal | non | oui |

## Journal

Le serveur enregistre chaque action : qui, quoi, reussi ou echoue. Il l'affiche aussi en direct sur son ecran. L'administration le consulte dans le menu **A** (historique ou en direct).

## Impression

- Le client demande l'impression au serveur, qui la note dans le journal.
- Le client envoie le travail au **premier serveur d'impression qui repond**.
- Chaque page porte en haut et en bas : qui a imprime, et depuis quel ordinateur.
- Le serveur d'impression recupere le contenu sur le serveur (ticket a usage unique) ; il ne fait pas confiance au client.
- Un serveur d'impression traite un travail a la fois, sur sa premiere imprimante libre.

## Hors ligne

- Un client garde en cache les archives lues. Il les montre meme sans serveur.
- Sans serveur, il permet seulement les **ajouts** : nouvelle archive, ou ajout de lignes en fin d'archive. Il ne peut ni supprimer, ni reecrire.
- Les ajouts sont gardes et envoyes, dans l'ordre, au retour du serveur.
- Un ajout en conflit est refuse et signale dans **7. Attente et refus**. Conflit = l'archive a ete modifiee entre-temps.
  - L'administrateur est toujours prioritaire : si l'administration a modifie l'archive, l'ajout hors ligne est refuse.
  - Deux utilisateurs qui ajoutent ne se contredisent pas : les deux ajouts sont gardes, dans l'ordre d'envoi.
- Connexion hors ligne : seulement pour un utilisateur deja connecte sur cet ordinateur.

## Connexion a distance

Depuis l'administration (menu 7) : afficher l'etat d'un client (nom, version, utilisateur connecte) ou le redemarrer. Ce n'est **pas** un shell a distance.

## Verrouillage

L'administration se verrouille avec l'option **0** ; seul le mot de passe administrateur la rouvre. C'est un verrou d'ecran : Ctrl+T le contourne.

## Mises a jour

- Automatiques : au demarrage, chaque programme verifie la version sur le depot.
- Manuelles : option **Mise a jour** dans le menu.

Pour publier une mise a jour : augmenter `VERSION` dans le fichier concerne, puis pousser sur `main`.

## Securite

Les mots de passe et jetons sont hashes avec un sel maison, **non cryptographique**. Le trafic sans fil est en clair. Suffisant pour un reseau de jeu, pas plus.

## Structure

```
server/server.lua   serveur (archives, comptes, journal, tickets)
client/client.lua   ordinateur client (cache, file d'attente, impression)
admin/admin.lua     ordinateur d'administration
print/print.lua     serveur d'impression
install.lua         installateur
```

## Donnees serveur

- `/archives/docs/<id>.dat` : une archive
- `/archives/computers.dat` : ordinateurs (sel, hash, admin, role)
- `/archives/users.dat` : utilisateurs (sel, hash)
- `/archives/logs.txt` : journal
