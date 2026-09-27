# claude-life-os

[English](README.md) · [Українська](README.uk.md) · [Deutsch](README.de.md) · [Polski](README.pl.md) · **Français** · [Español](README.es.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Русский](README.ru.md) · [Português](README.pt.md)

Un système personnel pour la paperasse. Il lit votre Gmail et votre Google Drive, tient
un index de chaque document officiel, lettre, contrat et facture dans une base de données
qui vous appartient, et veille à ce qu'aucune échéance, reconduction ou date
d'expiration ne vous échappe. Vous posez vos questions en langage courant, dans n'importe
quelle conversation Claude : « quand expire mon passeport », « puis-je encore résilier
la salle de sport », « que dit le bail sur les animaux ».

Il a été construit par une personne pour sa propre vie, utilisé chaque jour pendant un
mois, et devient maintenant quelque chose que tout le monde peut installer. Aucune
programmation nécessaire : Claude vous guide à chaque étape.

## Installation

Ceci concerne Claude normal : claude.ai dans le navigateur, ou l'application Claude sur
ordinateur ou téléphone.

**1. Téléchargez le skill : [life-os.zip](https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip)** (ne le décompressez pas). C'est un
seul skill qui contient tout : installation, e-mail, fichiers, vérification nocturne,
revue mensuelle et réponses à vos questions. Le lien pointe toujours vers la dernière
version ([toutes les versions](https://github.com/denysovkos/claude-life-os/releases)).

**2. Ajoutez-le à Claude.** Dans Claude, ouvrez **Settings** → **Capabilities**, activez
**Code execution and file creation** (les skills en ont besoin), puis sous **Skills**
cliquez sur **Upload skill** et choisissez `life-os.zip`.

**3. Connectez vos comptes.** **Settings** → **Connectors** : Google Drive, Gmail et
Supabase ; si vous le souhaitez aussi Google Calendar, Todoist, Craft.

**4. Ouvrez une nouvelle conversation et écrivez : `set up life os`.** À partir de là,
Claude vous guide. Il pose quelques questions (votre langue, votre pays, les applications
que vous utilisez), crée la base de données et les dossiers Drive, et vérifie chaque
étape avant la suivante.

**5. Installez le pont Google Apps Script** quand Claude le demande. C'est un fichier qui
s'exécute dans votre compte Google toutes les 15 minutes, même quand Claude ne tourne pas
(libellés en anglais ; Google peut les afficher en français) :

- script.google.com → **New project** → collez le code que Claude vous montre →
  enregistrez ;
- **Project Settings** → **Script Properties** → ajoutez `SUPABASE_URL` et
  `SUPABASE_SECRET_KEY` (Claude vous dit où les trouver ; la clé va uniquement là,
  jamais dans une conversation) ;
- choisissez la fonction `install` → **Run** → **Review permissions** → votre compte →
  « Google hasn't verified this app » → **Advanced** → **Go to Life OS bridge (unsafe)**
  → **Select all** → **Allow**. L'avertissement est normal : c'est votre propre script,
  qui ne s'exécute que dans votre compte.

Pas à pas, avec l'explication de chaque autorisation (en anglais) :
[docs/apps-script.md](docs/apps-script.md).

**6. Laissez-le tourner chaque nuit.** Claude ne démarre pas tout seul : créez quatre
exécutions planifiées, de préférence la nuit et dans cet ordre : e-mail à **01:05**,
fichiers à **02:05**, vérification nocturne avec votre récapitulatif quotidien à
**03:05**, et revue mensuelle le 1er à **04:05**. L'e-mail d'abord, car son tri indique au
pont quelles pièces jointes copier ; les fichiers une heure plus tard les indexent la même
nuit ; la vérification en dernier, pour que le récapitulatif du matin contienne tout. Créez-les comme tâches planifiées dans Claude, chacune avec le prompt de
[docs/scheduling.md](docs/scheduling.md) (en anglais).

C'est tout, environ 30 minutes. Plus tard, à tout moment, écrivez **`life os doctor`** :
il vérifie tout le système et vous dit exactement quoi corriger.

**Mise à jour :** téléchargez le nouveau `life-os.zip` et importez-le de la même façon
(supprimez d'abord l'ancien skill si Claude ne le remplace pas). Écrivez ensuite
`life os doctor` : il applique lui-même les mises à jour de la base et les nouvelles
règles.


### Ce qu'il vous faut

- Un compte Google (Gmail et Google Drive).
- Un abonnement Claude avec skills et connecteurs.
- Un compte [Supabase](https://supabase.com) gratuit. Supabase est la base de données qui
  contient l'index ; l'offre gratuite suffit. Claude crée le projet pour vous.
- En option : Todoist pour les tâches, Craft pour le rapport mensuel. Sans eux, tâches et
  rapports arrivent par e-mail et sous forme de Google Docs.

## Ce qu'il fait pour vous

- **Chaque nuit**, il lit les nouveaux e-mails, les range dans 10 catégories (factures,
  administrations, banque, contrats, voyages, etc.), extrait montants et dates
  d'échéance, et crée une tâche quand vous devez agir. Voyages et rendez-vous deviennent
  des événements d'agenda.
- **Les pièces jointes importantes** (factures, contrats, courriers d'administrations)
  sont copiées automatiquement dans Google Drive, classées dans le bon dossier et
  indexées avec leur texte intégral.
- **Il suit des échéances, pas seulement des dates.** Un titre de séjour qui expire ; une
  décision contestable pendant un mois ; une assurance reconduite sauf résiliation trois
  mois avant : chacun devient une échéance avec des rappels de plus en plus fréquents. Le
  calcul d'une échéance dépend de votre pays.
- **Un bref récapitulatif quotidien**, seulement les jours où quelque chose compte.
  Jamais de message « tout va bien ».
- **Une revue mensuelle** : ce que vous payez chaque mois, ce qui a changé, ce que vous
  pouvez résilier et jusqu'à quand, ce qui va dans votre déclaration d'impôts, et ce qui
  semble anormal.
- **Un dossier d'urgence** : un Google Doc réécrit chaque jour avec vos affaires en
  cours, échéances, contrats, assurances, l'emplacement des originaux et les personnes à
  appeler.

## Les tâches dans votre gestionnaire de tâches

La base de données tient la liste ; le gestionnaire de tâches ne fait que la refléter,
donc rien n'est perdu si vous changez d'application ou n'en utilisez aucune. Avec Todoist :

| Tâche | Quand |
|---|---|
| `📅 Daily brief <date> : <l'essentiel>` | seulement les jours où quelque chose compte ; le récapitulatif est dans la description |
| `💌 <catégorie> <expéditeur> : <quoi faire>` | un courrier demande une action |
| `⚠️ <document> expires <date> : <fichier>` | un document expire dans les 30 jours |
| `🧾 Review <mois> : <décision principale>` | une fois par mois, les décisions que vous seul pouvez prendre |
| `⚠️ <tâche> failed <date>` | une exécution nocturne a eu des erreurs |

Les titres sont dans la langue choisie ; les mots `Daily brief` restent en anglais, car le
système reconnaît ainsi son propre récapitulatif. Terminer une tâche clôt l'échéance
correspondante. Plus de détails dans [docs/tasks.md](docs/tasks.md) (en anglais).

## Réglages

Tous les réglages sont dans une table de votre propre base, `life_settings`, et chaque
modification est enregistrée dans `settings_history`, visible et annulable. Pour changer
quelque chose, dites-le simplement : « passe la langue en anglais », « j'ai déménagé en
Espagne », « ajoute ma sœur au dossier d'urgence ». Quand votre pays ou ses règles
changent, les échéances déjà calculées sont recalculées, après que Claude vous a montré
ce qui bouge. Détails dans [docs/settings.md](docs/settings.md) (en anglais).

## Langues et pays

Le système lit les e-mails dans n'importe quelle langue. Ses propres textes
(récapitulatifs, tâches, rapports, dossier d'urgence, noms de dossiers) existent dans ces
langues :

| Langue | État |
|---|---|
| English, Deutsch, Українська | complètes et testées |
| Polski, Français, Español, Italiano, Nederlands, Русский, Português | traduction de départ, anglais pour le reste |

Les règles juridiques (calcul d'un délai de recours, résiliation d'un forfait mobile,
délai de rétractation, date limite de la déclaration d'impôts) viennent d'un **pack
régional**. L'**Allemagne** est complète. Ailleurs, le système suit quand même chaque date
qu'il lit, mais utilise des valeurs prudentes et vous demande les règles locales. Pour
ajouter une langue ou un pays : [packs/README.md](packs/README.md).

## Confidentialité et sécurité

Vos données restent dans vos propres comptes : votre Gmail, votre Drive, votre projet
Supabase. Il n'y a aucun serveur intermédiaire et personne d'autre n'y a accès. La base
est verrouillée de sorte que son interface publique ne renvoie rien ; seuls Claude (via
votre propre connecteur) et votre propre Apps Script peuvent la lire. Les fichiers ne
passent jamais par l'IA : Google les déplace directement de Gmail vers Drive. Détails dans
[docs/security.md](docs/security.md) (en anglais).

## Fonctionnement

Tout ce qui doit arriver à l'heure est fait par des choses qui n'oublient pas : Google
Apps Script toutes les 15 minutes et des tâches planifiées dans la base chaque nuit.
Claude ne fait que ce qui demande du jugement : lire un courrier et comprendre ce qu'il
signifie. La base est la seule source de vérité ; Todoist, Craft et l'agenda ne font que
la refléter.

- [docs/architecture.md](docs/architecture.md) : composants, modèle de données, parcours d'un courrier.
- [docs/apps-script.md](docs/apps-script.md) : installer le pont.
- [docs/scheduling.md](docs/scheduling.md): le planning nocturne : horaires, ordre.
- [docs/tasks.md](docs/tasks.md) : ce qui arrive dans le gestionnaire de tâches et comment ça se clôt.
- [docs/settings.md](docs/settings.md) : tous les réglages et ce qui se passe quand l'un change.
- [docs/security.md](docs/security.md) : clés, droits, ce que voit l'IA, sauvegardes.
- [docs/troubleshooting.md](docs/troubleshooting.md) : chaque panne de l'original et sa solution.

## État

Version précoce. La base, le pont et l'analyse des e-mails ont tourné chaque jour pendant
un mois dans la version privée d'origine, puis ont été généralisés. Le skill
d'installation et les packs sont nouveaux. Attendez-vous à des imperfections et
signalez-les.
