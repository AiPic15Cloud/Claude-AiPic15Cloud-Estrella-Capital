# Sauvegardes Postgres ATLAS (Railway)

Le compte Railway est sur le plan **Hobby** : l'onglet *Backups* et le PITR
(restauration à la seconde) y sont réservés au plan Pro. En attendant, la base
est protégée par des sauvegardes logiques quotidiennes et un exercice de
restauration hebdomadaire, qui répondent à l'exigence « sauvegardes /
restauration vérifiée » du Lot B (`docs/ATLAS_specifications.md`, dépôt
`AiPic15Cloud/Claude`).

Perte de données maximale (RPO) : **24 h**. Le PITR, s'il est activé plus tard,
la ramènerait à quelques secondes ; les deux mécanismes se complètent.

## Ce qui tourne

Projet Railway `serene-rejoicing`, environnement `production` :

| Élément | Rôle | Planning (UTC) |
|---|---|---|
| bucket `pg-backups` (sjc) | stocke `daily/atlas-AAAAMMJJ-HHMMSS.dump` | — |
| service `pg-backup` | `backup.sh` : `pg_dump` (format custom) → contrôle de lisibilité → envoi → rétention des 30 derniers | tous les jours 02:00 |
| service `pg-restore-drill` | `restore-drill.sh` : restaure le dernier dump dans un Postgres jetable **dans son propre conteneur**, compare le nombre de lignes table par table avec la prod | dimanche 04:00 |

Les deux services utilisent l'image `postgres:18-alpine` (même version majeure
que la base, `postgres-ssl:18`) et installent `aws-cli` au démarrage. La
production n'est jamais écrite : `pg-backup` et `pg-restore-drill` ne font que
lire.

Le script exécuté est stocké dans la variable `JOB_SCRIPT` de chaque service ;
la commande de démarrage l'écrit dans `/tmp/job.sh` puis l'exécute. **Les
fichiers de ce dossier sont la référence** : après toute modification, recopier
le contenu dans `JOB_SCRIPT` du service correspondant.

Variables (références Railway, rien en clair) : `DATABASE_URL=${{Postgres.DATABASE_URL}}`,
`BUCKET`, `ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_DEFAULT_REGION` (depuis `pg-backups`), `RETENTION_COUNT=30` (pg-backup).

## Surveiller

- Service `pg-backup` → *Deployments* : chaque exécution doit finir en succès
  avec `[backup] terminé`. Un échec (code ≠ 0) signifie qu'aucun dump n'a été
  envoyé ce jour-là.
- Service `pg-restore-drill` → dernière exécution : `[drill] RÉSULTAT : OK`.
  Les écarts marqués `≠` sont normaux (écritures faites depuis le dump).
  `ÉCHEC` si la restauration plante, si une table de prod manque dans la copie
  (par ex. migration déployée après le dump du jour — l'échec disparaît au
  dump suivant) ou si une table restaurée est vide alors qu'elle est pleine en
  prod.
- Lancer à la main : bouton *Deploy* / *Run now* du service concerné.

## Restaurer (incident réel)

On ne restaure **jamais** par-dessus la base de production en place. On
restaure dans une nouvelle base, on vérifie, puis on bascule.

1. **Choisir le dump** : bucket `pg-backups` → `daily/`. Le nom donne l'heure
   UTC de la sauvegarde.
2. **Créer une base cible** : sur le canvas Railway, *New → Database →
   PostgreSQL* (nommer par ex. `Postgres-restored-AAAAMMJJ`). Ne pas y brancher
   l'application tout de suite.
3. **Restaurer** depuis un conteneur ayant accès au réseau privé du projet
   (le plus simple : dupliquer `pg-restore-drill`, retirer le cron, et mettre
   comme `JOB_SCRIPT`) :

   ```sh
   set -eu
   apk add --no-cache aws-cli >/dev/null
   aws s3 cp "s3://${BUCKET}/daily/<NOM_DU_DUMP>" /tmp/r.dump --endpoint-url "$ENDPOINT"
   pg_restore --no-owner --no-acl --exit-on-error -d "$TARGET_URL" /tmp/r.dump
   echo restauré
   ```

   avec la variable `TARGET_URL=${{Postgres-restored-AAAAMMJJ.DATABASE_URL}}`.
4. **Vérifier** : ouvrir la nouvelle base (onglet *Database*) et contrôler les
   tables clés (dossiers, prêts, `_prisma_migrations`).
5. **Basculer** : sur les services `Claude` et `crowdfunding-worker`, remplacer
   la référence `${{Postgres.DATABASE_URL}}` par celle de la base restaurée
   (redéploiement automatique). Conserver l'ancienne base tant que la bascule
   n'est pas validée, puis la supprimer.
6. **Rebrancher les sauvegardes** : mettre à jour `DATABASE_URL` de
   `pg-backup` et `pg-restore-drill` vers la nouvelle base.

Restaurer une seule table : ajouter `--table=<nom>` à `pg_restore`, en ciblant
une base temporaire, puis recopier les lignes voulues.

## Tester localement

Les scripts ont été validés avec `postgres:18-alpine` (Docker) contre une base
de test : 3 sauvegardes + rétention, exercice OK, et deux cas d'échec (table
ajoutée en prod après le dump, pleine ou vide) qui sortent bien en code 1.

## Historique des vérifications

| Date (UTC) | Dump | Résultat |
|---|---|---|
| 2026-09-27 23:29 | `atlas-20260927-232349.dump` (4,2 Mo, 780 entrées) | **OK** — toutes les tables présentes, 22 030 lignes, comptages identiques à la prod |

## Passage au PITR (plus tard)

Nécessite le plan Pro. Puis : service Postgres → *Backups* → *Enable PITR*
(redémarrage de Postgres de quelques secondes). Garder `pg-backup` en place :
il reste une copie indépendante, lisible par n'importe quel Postgres ≥ 18.
