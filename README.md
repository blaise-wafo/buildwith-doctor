<div align="center">

<img src="assets/banner.svg" alt="BuildWith Doctor — le stéthoscope numérique de votre Linux" width="100%"/>

<br/>

![Version](https://img.shields.io/badge/version-2.0.0-f43f5e?style=for-the-badge)
![Bash](https://img.shields.io/badge/bash-%E2%89%A5%204.0-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-apt%20%C2%B7%20dnf%20%C2%B7%20pacman-0ea5e9?style=for-the-badge&logo=linux&logoColor=white)
![Modules](https://img.shields.io/badge/modules-15-8b5cf6?style=for-the-badge)
![Sauvegardes](https://img.shields.io/badge/sauvegarde%20avant%20modification-oui-22c55e?style=for-the-badge)
![Dry run](https://img.shields.io/badge/--dry--run-disponible-facc15?style=for-the-badge&labelColor=3f3f46)

### 🩺 Auscultation · 📋 Diagnostic · 💊 Ordonnance · 🏥 Traitement · 🔁 Contre-visite

**Un seul script Bash qui examine la santé de votre machine Linux, vous dit ce qui ne va pas, et la soigne, avec votre accord.**

[🚀 Démarrage rapide](#-démarrage-rapide) ·
[🎛️ Utilisation](#️-utilisation) ·
[🧩 Modules](#-les-15-modules-dauscultation) ·
[💊 Soins](#-le-carnet-de-soins) ·
[🛡️ Garde-fous](#️-garde-fous)

</div>

---

## 📖 Sommaire

1. [🎬 Aperçu](#-aperçu)
2. [🫀 Comment ça marche](#-comment-ça-marche)
3. [🚀 Démarrage rapide](#-démarrage-rapide)
4. [🎛️ Utilisation](#️-utilisation)
5. [🧩 Les 15 modules d'auscultation](#-les-15-modules-dauscultation)
6. [📊 L'indice de santé](#-lindice-de-santé)
7. [💊 Le carnet de soins](#-le-carnet-de-soins)
8. [🛡️ Garde-fous](#️-garde-fous)
9. [📂 Fichiers générés](#-fichiers-générés)
10. [🚦 Codes de sortie](#-codes-de-sortie)
11. [🤖 Automatisation (cron, CI)](#-automatisation-cron-ci)
12. [🐧 Compatibilité](#-compatibilité)
13. [❓ Questions fréquentes](#-questions-fréquentes)

---

## 🎬 Aperçu

<div align="center">
<img src="assets/terminal.svg" alt="Exemple de sortie de BuildWith Doctor dans un terminal" width="92%"/>
</div>

> 🎨 **Les couleurs ont un sens** : <kbd>✔</kbd> vert = tout va bien · <kbd>▲</kbd> jaune = à surveiller · <kbd>✘</kbd> rouge = critique · <kbd>ℹ</kbd> bleu = information · <kbd>Rx →</kbd> cyan = le soin proposé.

---

## 🫀 Comment ça marche

```mermaid
flowchart LR
    A(["🩺 <b>Auscultation</b><br/>15 modules"]):::blue
    B(["📋 <b>Diagnostic</b><br/>indice /100"]):::yellow
    C(["💊 <b>Ordonnance</b><br/>soins proposés"]):::purple
    D(["🏥 <b>Traitement</b><br/>avec confirmation"]):::green
    E(["🔁 <b>Contre-visite</b><br/>nouveau score"]):::cyan
    F(["📄 <b>Rapport</b><br/>.txt + .json"]):::gray

    A --> B --> C --> D --> E --> F

    classDef blue   fill:#0ea5e9,stroke:#0369a1,color:#fff,stroke-width:2px
    classDef yellow fill:#facc15,stroke:#a16207,color:#1c1917,stroke-width:2px
    classDef purple fill:#8b5cf6,stroke:#5b21b6,color:#fff,stroke-width:2px
    classDef green  fill:#22c55e,stroke:#15803d,color:#fff,stroke-width:2px
    classDef cyan   fill:#06b6d4,stroke:#0e7490,color:#fff,stroke-width:2px
    classDef gray   fill:#64748b,stroke:#334155,color:#fff,stroke-width:2px
```

| Étape | Ce qui se passe | Modifie le système ? |
|:--|:--|:-:|
| 🩺 **Auscultation** | Chaque module lit l'état de la machine (`/proc`, `/sys`, journaux, paquets…) | 🟢 Non |
| 📋 **Diagnostic** | Les anomalies sont classées par gravité et un **indice de santé** est calculé | 🟢 Non |
| 💊 **Ordonnance** | Chaque anomalie réparable reçoit un soin (`Rx →`) | 🟢 Non |
| 🏥 **Traitement** | Les soins sont appliqués un à un, après votre accord | 🔴 **Oui** |
| 🔁 **Contre-visite** | Nouvelle auscultation silencieuse : le score avant → après | 🟢 Non |

---

## 🚀 Démarrage rapide

```bash
# 1. Rendre le script exécutable
chmod +x buildwith-doctor.sh

# 2. Lancer le menu interactif
sudo ./buildwith-doctor.sh
```

Besoin d'un premier coup d'œil **sans rien modifier** ?

```bash
sudo ./buildwith-doctor.sh --scan
```

Envie de voir ce que le traitement ferait, **sans l'appliquer** ?

```bash
sudo ./buildwith-doctor.sh --heal --dry-run
```

> 💡 **Pas de `sudo` ?** Si vous lancez une action sans être root, le script se relance tout seul avec `sudo`. Sans `sudo` disponible, il fait un diagnostic partiel.

---

## 🎛️ Utilisation

### 🧭 Le menu interactif

Lancé sans option dans un terminal, le script affiche ce menu :

| Choix | Mode | En clair |
|:-:|:--|:--|
| `1` | 🔍 Consultation complète | Diagnostic seul, **aucune modification** |
| `2` | 💊 Consultation + traitement | Vous validez **chaque soin** |
| `3` | ⚡ Traitement automatique | Soins critiques/importants sans question |
| `4` | 🔬 Consultation approfondie | + intégrité des paquets, journal, fichiers orphelins |
| `5` | 🏃 Consultation rapide | Saute les contrôles lents |
| `6` | 🧪 Simulation du traitement | `--dry-run` : rien ne change |
| `7` | 📄 Lire le dernier rapport | Ouvre `dernier-rapport.txt` |
| `0` | 👋 Quitter | |

### ⚙️ Les options

#### 🎯 Actions

| Option | Effet |
|:--|:--|
| *(aucune)* | Menu interactif (ou `--scan` si le script n'est pas dans un terminal) |
| `--scan` <sub>(`--status`, `--check`)</sub> | 🔍 Diagnostic complet, **aucune modification** |
| `--heal` <sub>(`--fix`, `--repair`)</sub> | 💊 Diagnostic + traitement, confirmation pour chaque soin |
| `--auto` | ⚡ Équivaut à `--heal --yes` |

#### 🔧 Réglages

| Option | Effet |
|:--|:--|
| `--deep` | 🔬 Auscultation approfondie : `dpkg --verify`, `journalctl --verify`, fichiers sans propriétaire |
| `--quick` | 🏃 Saute les contrôles lents (intégrité, recherche de fichiers world-writable, détail des gros dossiers) |
| `--dry-run` | 🧪 Simule les traitements, **rien n'est modifié** |
| `--yes`, `-y` | ✅ Répond « oui » aux soins critiques et importants |
| `--full` | ➕ Avec `--yes` : inclut aussi les soins **optionnels** (niveau info) |
| `--only a,b` | 🎯 N'ausculte que ces modules |
| `--skip a,b` | ⏭️ Ignore ces modules |
| `--list` | 📃 Liste les modules disponibles |
| `--no-reboot` | 🚫 Ne propose jamais de redémarrage |
| `--no-anim` | 🎞️ Désactive les animations |
| `--no-color` | ⬛ Désactive les couleurs (la variable `NO_COLOR` est aussi respectée) |
| `-v`, `--version` | 🏷️ Affiche la version |
| `-h`, `--help` | 📖 Affiche l'aide |

### 🍳 Recettes

```bash
# Contrôle de routine, rapide
sudo ./buildwith-doctor.sh --scan --quick

# Examen complet et approfondi
sudo ./buildwith-doctor.sh --scan --deep

# Ne regarder que la mémoire et le disque
sudo ./buildwith-doctor.sh --scan --only memory,disk

# Tout sauf les conteneurs et l'intégrité
sudo ./buildwith-doctor.sh --scan --skip containers,integrity

# Soigner en validant chaque soin
sudo ./buildwith-doctor.sh --heal

# Soigner sans poser de question, optionnels compris
sudo ./buildwith-doctor.sh --auto --full --no-reboot
```

---

## 🧩 Les 15 modules d'auscultation

Utilisez l'identifiant avec `--only` / `--skip`.

| # | | Identifiant | Ce qui est examiné |
|:-:|:-:|:--|:--|
| 1 | 🖥️ | `system` | Distribution, noyau, uptime, noyau « tainted », UEFI/BIOS, `machine-id` |
| 2 | ⚙️ | `cpu` | Charge par cœur, utilisation instantanée, attente disque (iowait), top des processus |
| 3 | 🧠 | `memory` | RAM disponible, swap, mémoire slab du noyau, OOM-kills, protection anti-saturation |
| 4 | 💾 | `disk` | Espace et inodes, systèmes de fichiers en lecture seule, `fstab`, erreurs d'E/S, RAID, **SMART**, TRIM |
| 5 | 🔧 | `services` | État de systemd, unités en échec, redémarrages en boucle, temps de démarrage |
| 6 | 📦 | `packages` | Base de paquets cassée, mises à jour (dont sécurité), orphelins, anciens noyaux, snaps |
| 7 | 🔐 | `security` | UID 0, comptes sans mot de passe, permissions sensibles, `/tmp`, setuid, SSH, pare-feu, ASLR |
| 8 | 🌐 | `network` | Passerelle, Internet, DNS, nom d'hôte, synchronisation NTP, erreurs d'interface, rfkill |
| 9 | 📜 | `logs` | Erreurs du journal, segfaults, traces noyau, erreurs MCE, firmware manquant, taille de `/var/log` |
| 10 | 🌡️ | `hardware` | Températures, bridage thermique, santé de la batterie, outils de diagnostic |
| 11 | 🧟 | `processes` | Zombies, processus bloqués (état D), descripteurs de fichiers, threads |
| 12 | 👥 | `users` | Syntaxe de `sudoers`, UID dupliqués, cohérence `passwd`/`group`, dossiers personnels |
| 13 | 🚀 | `boot` | `initramfs`, chargeur de démarrage, partition EFI, noyau plus récent installé |
| 14 | 🐳 | `containers` | Docker : espace récupérable, conteneurs arrêtés |
| 15 | 🔬 | `integrity` | Liens cassés ; avec `--deep` : `dpkg --verify`, journal systemd, fichiers orphelins |

```bash
sudo ./buildwith-doctor.sh --list
```

---

## 📊 L'indice de santé

Chaque consultation aboutit à une note sur **100** :

```text
 score = 100 − (12 × critiques) − (4 × avertissements) − (1 × infos)
```

> ⚠️ **Plafond** : dès qu'il y a **au moins une anomalie critique**, le score ne peut pas dépasser **69**.

| Score | État | Visuel |
|:-:|:--|:--|
| **90 – 100** | 🟢 Excellente santé | 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 |
| **75 – 89** | 🟢 Bonne santé | 🟩🟩🟩🟩🟩🟩🟩🟩⬜⬜ |
| **50 – 74** | 🟡 À soigner | 🟨🟨🟨🟨🟨🟨⬜⬜⬜⬜ |
| **0 – 49** | 🔴 État préoccupant | 🟥🟥🟥🟥⬜⬜⬜⬜⬜⬜ |

### 🚨 Les trois niveaux de gravité

| Symbole | Niveau | Poids | Signification |
|:-:|:--|:-:|:--|
| 🔴 **✘** | **Critique** | −12 | Panne ou risque sérieux : disque plein, RAM saturée, compte sans mot de passe… |
| 🟡 **▲** | **Avertissement** | −4 | À corriger bientôt : mises à jour de sécurité, pare-feu absent, swap très utilisé… |
| 🔵 **ℹ** | **Information** | −1 | Amélioration conseillée : orphelins, TRIM, anciens noyaux… |

---

## 💊 Le carnet de soins

Chaque anomalie réparable est associée à un soin. Le traitement les passe **par ordre de gravité** (critiques d'abord) et ne propose chaque soin **qu'une seule fois**.

| 🩹 Soin | Ce qu'il fait |
|:--|:--|
| 🧠 **Libérer la mémoire** | Vide les caches noyau, compacte la mémoire, purge le swap disque **seulement si assez de RAM libre** |
| 🛡️ **Durcir la mémoire** | Installe **zram** (swap compressé), crée un swap de secours si possible, règle `sysctl`, active **earlyoom** |
| 🧹 **Nettoyer le disque** | `apt clean`/`autoremove`, journaux systemd (7 j / 200 Mo), vieux logs, core dumps, tmp > 10 j, miniatures, snaps, Flatpak, Docker |
| ✂️ **TRIM** | Active `fstrim.timer` et lance un TRIM sur les SSD |
| 🔧 **Services en échec** | `reset-failed` puis redémarrage, avec vérification de stabilité et dernières lignes de journal si ça échoue |
| 📦 **Réparer APT** | `dpkg --configure -a` puis `apt-get install -f` |
| ⬆️ **Mises à jour** | `apt` / `dnf` / `pacman` selon la distribution |
| 🗑️ **Orphelins & configs résiduelles** | `autoremove --purge`, purge des paquets « rc » |
| 🔐 **Verrouiller les comptes vides** | `passwd -l` sur les comptes sans mot de passe |
| 🔑 **Permissions** | Rétablit des modes sûrs (`shadow`, `sudoers`, clés SSH, `~/.ssh`…) |
| 📌 **`/tmp` et setuid** | `chmod 1777 /tmp /var/tmp`, retire les bits setuid/setgid des fichiers temporaires |
| 🔒 **Durcir SSH** | `PermitRootLogin` → `prohibit-password`, `PermitEmptyPasswords` → `no`, **validé par `sshd -t`** |
| 🧱 **Pare-feu** | Installe/active **ufw** : entrant refusé, sortant autorisé, SSH et services en écoute autorisés |
| 🌐 **Réseau / DNS / hosts / NTP** | Redémarre le gestionnaire réseau, répare `resolv.conf`, ajoute le nom d'hôte à `/etc/hosts`, active NTP |
| 🧟 **Zombies** | Envoie `SIGCHLD` aux parents pour les faire récolter |
| 🚀 **Démarrage** | Régénère l'initramfs, monte la partition EFI (`mount -a`) |
| 🐳 **Docker** | Supprime images *dangling* et cache de build > 7 jours |
| 🔬 **Réinstaller des paquets altérés** | Réinstalle les paquets dont des binaires diffèrent de l'original (`--deep`) |

### ✅ Quand le script demande-t-il votre avis ?

| Mode | Soins critiques / avertissements | Soins optionnels (info) |
|:--|:-:|:-:|
| `--heal` | ❓ confirmation pour chacun | ❓ confirmation |
| `--auto` ou `--yes` | ✅ appliqués sans question | ⏭️ **ignorés** |
| `--auto --full` | ✅ appliqués | ✅ appliqués |
| `--dry-run` | 🧪 simulés | 🧪 simulés |

> 🐳 Même avec `--yes`, la suppression de **toutes** les images Docker inutilisées n'est **jamais** faite automatiquement : elle exige une confirmation explicite.

---

## 🛡️ Garde-fous

<table>
<tr>
<td width="50%" valign="top">

### 💾 Rien n'est modifié sans filet
Avant d'éditer un fichier, le script en fait une **copie** dans  
`/var/backups/buildwith-doctor/<date>/`

### 🧪 Mode simulation
`--dry-run` affiche chaque action précédée de `[simulation]` et ne touche à rien.

### 🔒 Verrou anti-doublon
Une seule instance à la fois (`flock`) : impossible de lancer deux traitements en parallèle.

</td>
<td width="50%" valign="top">

### ↩️ Retour arrière automatique
La configuration SSH est **testée** (`sshd -t`) ; en cas d'échec, les fichiers d'origine sont **restaurés**.

### 🧯 Précautions intégrées
- Le swap n'est purgé que si la RAM peut l'absorber
- Le pare-feu autorise SSH avant de s'activer
- Les ports de bases de données (3306, 5432, 6379…) ne sont **pas** ouverts automatiquement
- Aucun redémarrage automatique avec `--yes`

### ⌨️ Interruption propre
`Ctrl+C` arrête proprement et restaure le curseur.

</td>
</tr>
</table>

> ⚠️ **À savoir** : `--auto` applique de **vraies modifications** (mises à jour, pare-feu, durcissement SSH, zram…). Lancez d'abord `--heal --dry-run` pour voir ce qui serait fait.

---

## 📂 Fichiers générés

```text
/var/log/buildwith-doctor/
├── 📄 rapport-20261125-143012.txt      ← rapport lisible
├── 🧾 rapport-20261125-143012.json     ← même rapport, pour les machines
├── 📝 actions-20261125-143012.log      ← journal détaillé des actions
├── 🔗 dernier-rapport.txt              ← lien vers le dernier rapport
└── 🔗 dernier-rapport.json

/var/backups/buildwith-doctor/
└── 📁 20261125-143012/                 ← copies des fichiers modifiés
    └── etc/ssh/sshd_config …
```

> 👤 Sans droits root, les journaux vont dans `~/.local/state/buildwith-doctor/`.

<details>
<summary><b>🧾 Aperçu du rapport JSON</b> (cliquer pour déplier)</summary>

```json
{
  "tool": "BuildWith Doctor", "version": "2.0.0", "signature": "by BuildWith",
  "date": "2026-11-25T14:30:12+01:00", "host": "mon-serveur", "kernel": "6.8.0",
  "score": 69, "critical": 1, "warnings": 2, "info": 3, "passed": 38,
  "findings": [
    {
      "severity": "crit",
      "module": "disk",
      "title": "Partition / pleine à 96%",
      "detail": "ext4 (ext4), 3.10 Gio libres",
      "fix": "Nettoyer APT, journaux, caches, snaps, flatpak, anciens fichiers temporaires"
    }
  ]
}
```

</details>

---

## 🚦 Codes de sortie

| Code | | Signification |
|:-:|:-:|:--|
| `0` | 🟢 | **En bonne santé** : aucun avertissement ni critique |
| `1` | 🟡 | **Avertissements** détectés |
| `2` | 🔴 | **Anomalie critique** détectée (ou option/module invalide) |

---

## 🤖 Automatisation (cron, CI)

Hors terminal, le script passe automatiquement en mode `--scan`. Combiné aux codes de sortie et au rapport JSON, il s'intègre facilement à la supervision.

```bash
# Contrôle quotidien à 6 h, sans couleurs ni animations
0 6 * * *  /opt/buildwith-doctor.sh --scan --quick --no-color >/dev/null 2>&1
```

```bash
# Alerte si l'état n'est pas bon
sudo ./buildwith-doctor.sh --scan --quick --no-color
case $? in
  0) echo "✅ Machine en bonne santé" ;;
  1) echo "⚠️  Avertissements : voir le rapport" ;;
  2) echo "🚨 Critique : intervention nécessaire" ;;
esac

# Lire le score depuis le JSON
jq '.score' /var/log/buildwith-doctor/dernier-rapport.json
```

---

## 🐧 Compatibilité

| Élément | Détail |
|:--|:--|
| 🐚 **Shell** | **Bash 4+** obligatoire (tableaux associatifs) |
| 👑 **Droits** | root conseillé : relance via `sudo` si besoin |
| ⚙️ **Init** | systemd recommandé (module `services` ignoré sinon) |
| 📦 **Gestionnaires de paquets** | `apt` ✅ complet · `dnf` 🟡 partiel · `pacman` 🟡 partiel |
| 🐳 **Conteneurs / VM** | Détectés ; les contrôles matériels sont adaptés |

> 🧰 **Outils optionnels** : `smartmontools` (SMART), `lm-sensors`, `ufw`, `earlyoom`. Le soin « Outils de diagnostic matériel » peut installer les deux premiers sur Debian/Ubuntu.

---

## ❓ Questions fréquentes

<details>
<summary><b>Le mode <code>--scan</code> modifie-t-il quelque chose ?</b></summary>

Non. Il ne lit que l'état du système et écrit uniquement ses propres rapports et journaux.

</details>

<details>
<summary><b>Puis-je annuler un soin ?</b></summary>

Les fichiers de configuration modifiés sont sauvegardés dans `/var/backups/buildwith-doctor/<date>/`. Vous pouvez les recopier à leur emplacement d'origine. Les actions sans fichier (mises à jour, nettoyages) ne sont pas réversibles ; utilisez `--dry-run` avant.

</details>

<details>
<summary><b>Pourquoi un redémarrage est-il parfois recommandé ?</b></summary>

Quand des mises à jour du noyau ou de bibliothèques sont installées mais pas encore actives, ou en cas de fuite mémoire noyau probable. Le script ne redémarre jamais tout seul avec `--yes`.

</details>

<details>
<summary><b>Je n'ai pas Debian/Ubuntu, ça marche ?</b></summary>

Oui pour le diagnostic général. Les contrôles et soins liés aux paquets sont les plus complets sur `apt` ; ils sont plus limités sur `dnf` et `pacman`.

</details>

<details>
<summary><b>Les couleurs s'affichent mal.</b></summary>

Utilisez `--no-color` ou définissez `NO_COLOR=1`. Elles sont aussi désactivées automatiquement hors terminal.

</details>

---

<div align="center">

**🩺 Gardez votre Linux en pleine forme.**

<img src="https://img.shields.io/badge/made%20with-%E2%99%A5-f43f5e?style=flat-square"/>
<img src="https://img.shields.io/badge/by-BuildWith-4ade80?style=flat-square"/>

<sub>— by BuildWith —</sub>

</div>
