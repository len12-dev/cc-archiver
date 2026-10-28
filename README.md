# cc-archiver

Systeme d'archives pour **CC: Tweaked** (ComputerCraft), deployable sur tout un serveur Minecraft. Un **serveur central** stocke toutes les donnees et tous les journaux. Chaque **zone** a son **sous-serveur** relie au central. Les clients, serveurs d'impression et ordinateurs d'administration de la zone sont relies au sous-serveur. Chaque archive garde l'emplacement reel dans Minecraft (identifiant de coffre).

## Installation

Sur chaque ordinateur, avec un modem sans fil :

```
wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
```

Choisis le role, puis redemarre :

1. Serveur central (un seul sur tout le serveur Minecraft)
2. Serveur de zone (un par zone)
3. Client
4. Ordinateur d'administration
5. Serveur d'impression

Les serveurs de zone et le serveur central sont relies par **modem ender**. Les clients, serveurs d'impression et ordinateurs d'administration de la zone sont relies **en cable reseau** au serveur de zone, qui sert de passerelle.

## Mise en place d'une zone

1. Sur le **serveur central**, lance l'administration : premiere connexion = *administrateur central* (identifiant + mot de passe). Menu **9** : code de type *serveur de zone* avec un **code de zone** (majuscules et chiffres).
2. Sur le **serveur de zone** : entre le code de zone et le code a 6 chiffres genere par le central (valable 5 minutes).
3. Sur un ordinateur de la zone (menu **9** du central, type *administrateur de zone*) : premiere connexion = *administrateur de zone*, avec le code, puis un **mot de passe maitre de zone** choisi par l'administrateur de la zone.

Pour les clients et serveurs d'impression, le code est genere sur l'administration de **leur** zone (menu 9) : identifiant + code a 6 chiffres, valable 5 minutes.

## Mots de passe maitres

- Le mot de passe de l'**administrateur central** est le mot de passe maitre de tout le reseau.
- Chaque **administrateur de zone** a son propre mot de passe maitre, valable pour sa zone.
- Le mot de passe maitre est demande pour supprimer une archive depuis un client.

## Droits

| Action | Utilisateur (client) | Admin de zone | Admin central |
|---|---|---|---|
| Lister, lire les archives (toutes zones, lecture seule hors zone) | oui | oui | oui |
| Creer, modifier une archive de sa zone | oui | oui | oui |
| Ajouter en fin d'archive hors ligne | oui | - | - |
| Supprimer une archive de sa zone | oui, avec mot de passe maitre, en ligne | oui | oui |
| Imprimer une archive | oui (imprimante de sa zone) | oui | oui |
| Gerer les utilisateurs, codes, journal de sa zone | non | oui (sa zone) | oui (tout) |
| Zones, codes de zone, journal global | non | non | oui |

Un utilisateur d'une zone peut **lire** les archives des autres zones, sans les modifier.

## Utilisateurs

Lire, creer et modifier une archive demandent un **identifiant utilisateur**, cree par l'administrateur de la zone (menu 6).

## Journal

Le serveur central enregistre chaque action de toutes les zones. Chaque sous-serveur garde aussi le journal de sa zone. L'administration le consulte dans le menu **A** (historique ou en direct).

## Impression

- Le client demande l'impression au serveur, qui la note dans le journal.
- Le client envoie le travail au **premier serveur d'impression de sa zone** qui repond.
- Chaque page porte en haut et en bas : qui a imprime, et depuis quel ordinateur.
- Le serveur d'impression recupere le contenu sur le serveur (ticket a usage unique) ; il ne fait pas confiance au client.
- Un serveur d'impression traite un travail a la fois, sur sa premiere imprimante libre.

## Hors ligne

- Un client garde en cache les archives lues. Il les montre meme sans serveur.
- Si le **central** est injoignable, le sous-serveur continue : il fait tourner sa zone avec la copie des donnees de sa zone.
- Sans serveur, un client permet seulement les **ajouts** : nouvelle archive, ou ajout de lignes en fin d'archive. Il ne peut ni supprimer, ni reecrire.
- Les ajouts sont gardes et envoyes, dans l'ordre, au retour du serveur.
- Un ajout en conflit est refuse et signale dans **7. Attente et refus**. Conflit = l'archive a ete modifiee entre-temps.
  - L'administrateur est toujours prioritaire : si l'administration a modifie l'archive, l'ajout hors ligne est refuse.
  - Deux utilisateurs qui ajoutent ne se contredisent pas : les deux ajouts sont gardes, dans l'ordre d'envoi.
- Connexion hors ligne : seulement pour un utilisateur deja connecte sur cet ordinateur.

## Connexion a distance

Depuis l'administration (menu 7) : afficher l'etat d'un client (nom, version, utilisateur connecte) ou le redemarrer. Ce n'est **pas** un shell a distance. La commande ne fonctionne que depuis le **meme cable reseau** (la meme zone).

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
server/server.lua   serveur central ou de zone (archives, comptes, journal, tickets, federation)
client/client.lua   ordinateur client (cache, file d'attente, impression)
admin/admin.lua     ordinateur d'administration (central ou zone)
print/print.lua     serveur d'impression
install.lua         installateur
```

## Donnees serveur

Serveur central :
- `/archives/server.cfg` : mode (`central`)
- `/archives/zones.dat` : zones et codes
- `/archives/docs/<zone>-<n>.dat` : une archive (identifiant = zone + numero)
- `/archives/computers.dat` : ordinateurs (sel, hash, role, zone)
- `/archives/users.dat` : utilisateurs
- `/archives/logs.txt` : journal global
- `/archives/counter.dat` : compteurs de numeros par zone

Sous-serveur de zone :
- `/archives/server.cfg` : mode (`zone`) et code de zone
- Copie des archives, comptes et journal de sa zone
- `/archives/queue.dat` : ajouts recus hors ligne, et refus a signaler aux utilisateurs
