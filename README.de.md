<p align="center">
  <img src="brand/logo.png" width="120" alt="Life OS">
</p>

<h1 align="center">Life OS</h1>

<p align="center">
  <b>Ihr Papierkram, erledigt.</b><br>
  Ein Open-Source-Skill für Claude mit Gmail, Google Drive und Supabase
</p>

<p align="center">
  <a href="https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip"><img src="https://img.shields.io/badge/Herunterladen-life--os.zip-D97757?style=for-the-badge&logo=anthropic&logoColor=white" alt="life-os.zip herunterladen"></a>
</p>

<p align="center">
  <a href="https://github.com/denysovkos/claude-life-os/releases/latest"><img src="https://img.shields.io/github/v/release/denysovkos/claude-life-os?style=flat-square&color=D97757&label=release" alt="Latest release"></a>
  <a href="https://github.com/denysovkos/claude-life-os/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/denysovkos/claude-life-os/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/denysovkos/claude-life-os?style=flat-square&color=1F2937" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/languages-10-4C8BD9?style=flat-square" alt="10 languages">
  <img src="https://img.shields.io/badge/countries-11-3FA37A?style=flat-square" alt="11 countries">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.uk.md">Українська</a> · <b>Deutsch</b> · <a href="README.pl.md">Polski</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.ru.md">Русский</a> · <a href="README.pt.md">Português</a></p>

<p align="center">
  <img src="brand/linkedin-card.png" width="100%" alt="Life OS: Tagesbriefing und Antworten in jedem Claude-Chat">
</p>

Ein persönliches System für Papierkram. Es liest Gmail und Google Drive, führt einen
Index aller formellen Dokumente, Briefe, Verträge und Rechnungen in einer Datenbank, die
Ihnen gehört, und sorgt dafür, dass keine Frist, keine automatische Verlängerung und
kein Ablaufdatum untergeht. Fragen stellen Sie in normaler Sprache, in jedem
Claude-Chat: „Wann läuft mein Pass ab?“, „Kann ich das Fitnessstudio noch kündigen?“,
„Was steht im Mietvertrag über Haustiere?“

Gebaut hat es eine Person für ihr eigenes Leben, einen Monat lang im täglichen Einsatz.
Jetzt wird daraus etwas, das jede und jeder installieren kann. Programmieren ist nicht
nötig: Claude führt durch jeden Schritt.

## Installation

Das ist für das normale Claude: claude.ai im Browser oder die Claude-App auf Computer
oder Handy.

**1. Den Skill herunterladen: [life-os.zip](https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip)** (nicht entpacken). Es ist ein
Skill, der alles enthält: Einrichtung, Mail, Dateien, nächtliche Prüfung, Monatsrückblick
und die Antworten auf Ihre Fragen. Der Link zeigt immer auf die neueste Version
([alle Releases](https://github.com/denysovkos/claude-life-os/releases)).

**2. In Claude hinzufügen.** In Claude **Settings** → **Capabilities** öffnen,
**Code execution and file creation** einschalten (Skills brauchen das), dann unter
**Skills** auf **Upload skill** klicken und `life-os.zip` wählen.

**3. Konten verbinden.** **Settings** → **Connectors**: Google Drive, Gmail und Supabase;
nach Wunsch auch Google Calendar, Todoist, Craft.

**4. Neuen Chat öffnen und schreiben: `richte Life OS ein`.** Ab hier führt Claude. Es
stellt ein paar Fragen (Sprache, Land, welche Apps Sie nutzen), legt die Datenbank und
die Drive-Ordner an und prüft jeden Schritt vor dem nächsten.

**5. Die Google-Apps-Script-Bridge installieren**, wenn Claude darum bittet. Das ist eine
Datei, die alle 15 Minuten in Ihrem Google-Konto läuft, auch wenn Claude nicht läuft:

- script.google.com → **Neues Projekt** (New project) → den Code einfügen, den Claude
  zeigt → speichern;
- **Projekteinstellungen** (Project Settings) → **Skripteigenschaften** (Script
  Properties) → `SUPABASE_URL` und `SUPABASE_SECRET_KEY` hinzufügen (Claude sagt, wo es
  sie gibt; der Schlüssel gehört nur dorthin, nie in einen Chat);
- Funktion `install` wählen → **Ausführen** (Run) → **Berechtigungen überprüfen**
  (Review permissions) → Ihr Konto → „Google hat diese App nicht überprüft“ →
  **Erweitert** (Advanced) → **Weiter zu Life OS bridge (unsicher)** → **Alle auswählen**
  (Select all) → **Zulassen** (Allow). Die Warnung ist normal: Es ist Ihr eigenes Skript
  und läuft nur in Ihrem Konto.

Schritt für Schritt, mit Erklärung jeder Berechtigung (auf Englisch):
[docs/apps-script.md](docs/apps-script.md).

**6. Jede Nacht laufen lassen.** Claude startet nicht von selbst, also legen Sie vier
geplante Läufe an, am besten nachts und in dieser Reihenfolge: Mail um **01:05**, Dateien
um **02:05**, die nächtliche Prüfung mit Ihrem Tagesbriefing um **03:05** und der
Monatsrückblick am 1. um **04:05**. Mail zuerst, weil ihre Einordnung der Bridge sagt,
welche Anhänge sie kopieren soll; die Dateien eine Stunde später indexieren diese noch in
derselben Nacht; die Prüfung zuletzt, damit das Morgenbriefing alles enthält. Legen Sie sie als geplante Aufgaben in Claude an, jede mit dem Prompt aus
[docs/scheduling.md](docs/scheduling.md) (Englisch).

Das ist alles, etwa 30 Minuten. Später jederzeit **`life os doctor`** schreiben: Es prüft
das ganze System und sagt genau, was zu beheben ist.

**Aktualisieren:** die neue `life-os.zip` herunterladen und genauso hochladen (falls
Claude den Skill nicht ersetzt, den alten vorher entfernen). Dann `life os doctor`
schreiben: Es spielt Datenbank-Updates und neue Regeln selbst ein.


### Was Sie brauchen

- Ein Google-Konto (Gmail und Google Drive).
- Einen Claude-Tarif mit Skills und Konnektoren.
- Ein kostenloses [Supabase](https://supabase.com)-Konto. Supabase ist die Datenbank, in
  der der Index liegt; der kostenlose Tarif reicht. Das Projekt legt Claude selbst an.
- Optional: Todoist für Aufgaben, Craft für den Monatsbericht. Ohne sie kommen Aufgaben
  und Berichte per E-Mail und als Google Docs.

## Was es für Sie tut

- **Jede Nacht** liest es neue Mails, ordnet sie in 10 Kategorien ein (Rechnungen,
  Behörden, Bank, Verträge, Reisen usw.), zieht Beträge und Fälligkeiten heraus und legt
  eine Aufgabe an, wenn Sie etwas tun müssen. Reisen und Termine werden zu
  Kalendereinträgen.
- **Wichtige Anhänge** (Rechnungen, Verträge, Behördenpost) werden automatisch in Google
  Drive kopiert, in den richtigen Ordner abgelegt und mit vollem Text indexiert.
- **Es verfolgt Fristen, nicht nur Daten.** Ein Aufenthaltstitel, der abläuft; ein
  Bescheid, gegen den man einen Monat lang Widerspruch einlegen kann; eine Versicherung,
  die sich verlängert, wenn man nicht drei Monate vorher kündigt: Aus jedem wird eine
  Frist mit Erinnerungen, die häufiger werden, je näher sie rückt. Wie eine Frist
  berechnet wird, hängt von Ihrem Land ab.
- **Ein kurzes tägliches Briefing**, nur an Tagen, an denen etwas zählt. Keine
  „Alles in Ordnung“-Nachrichten.
- **Ein Monatsrückblick**: was Sie monatlich zahlen, was sich geändert hat, was Sie bis
  wann kündigen können, was in die Steuererklärung gehört und was auffällig ist.
- **Ein Notfallordner**: ein Google Doc, täglich neu geschrieben, mit offenen
  Angelegenheiten, Fristen, Verträgen, Versicherungen, dem Ort der Originale und
  Kontakten.

## Aufgaben in Ihrer Aufgaben-App

Die Datenbank führt die Liste, die Aufgaben-App spiegelt sie nur. Wechseln Sie die App
oder nutzen keine, geht nichts verloren. Mit Todoist erhalten Sie:

| Aufgabe | Wann |
|---|---|
| `📅 Daily brief <Datum>: <das Wichtigste>` | nur an Tagen, an denen etwas zählt; das Briefing steht in der Beschreibung |
| `💌 <Kategorie> <Absender>: <was zu tun ist>` | ein Brief verlangt eine Handlung |
| `⚠️ <Dokument> expires <Datum>: <Datei>` | ein Dokument läuft in 30 Tagen ab |
| `🧾 Review <Monat>: <wichtigste Entscheidung>` | einmal im Monat, die Entscheidungen, die nur Sie treffen können |
| `⚠️ <Job> failed <Datum>` | ein nächtlicher Lauf hatte Fehler |

Die Titel erscheinen in Ihrer gewählten Sprache; die Wörter `Daily brief` bleiben
Englisch, weil das System daran sein eigenes Briefing erkennt. Wer eine Aufgabe
abhakt, schließt auch die Frist dahinter. Mehr in [docs/tasks.md](docs/tasks.md)
(Englisch).

## Einstellungen

Alle Einstellungen liegen in einer Tabelle Ihrer eigenen Datenbank, `life_settings`, und
jede Änderung wird in `settings_history` festgehalten, sichtbar und rückgängig zu
machen. Um etwas zu ändern, sagen Sie es einfach: „Stell die Sprache auf Englisch“, „Ich
bin nach Spanien gezogen“, „Nimm meine Schwester in den Notfallordner auf“. Ändern sich
Ihr Land oder dessen Regeln, werden bereits berechnete Fristen neu berechnet, nachdem
Claude Ihnen gezeigt hat, was sich verschiebt. Details in
[docs/settings.md](docs/settings.md) (Englisch).

## Sprachen und Länder

Mails liest das System in jeder Sprache. Die eigenen Ausgaben (Briefings, Aufgaben,
Berichte, Notfallordner, Ordnernamen) gibt es in diesen Sprachen:

| Sprache | Stand |
|---|---|
| English, Deutsch, Українська | vollständig und getestet |
| Polski, Français, Español, Italiano, Nederlands, Русский, Português | erste Übersetzung, sonst Englisch |

Rechtliche Regeln (wie eine Widerspruchsfrist berechnet wird, wann ein Vertrag kündbar
ist, bis wann man einen Kauf widerrufen kann, wann die Steuererklärung fällig ist) kommen
in einem **Regionalpaket**:

| Land | Stand |
|---|---|
| 🇩🇪 Deutschland | vollständig und getestet |
| 🇦🇹 🇫🇷 🇪🇸 🇮🇹 🇳🇱 🇵🇹 🇵🇱 🇬🇧 🇺🇸 🇺🇦 Österreich, Frankreich, Spanien, Italien, Niederlande, Portugal, Polen, Vereinigtes Königreich, USA, Ukraine | Beta: nach den in jeder Regel zitierten Gesetzen geschrieben, noch nicht vor Ort geprüft |

Überall sonst verfolgt das System weiterhin jedes gelesene Datum, verwendet aber
vorsichtige Platzhalter und fragt nach den lokalen Regeln. Korrekturen an Beta-Paketen
oder ein neues Land sind sehr willkommen: [packs/README.md](packs/README.md).

## Datenschutz und Sicherheit

Ihre Daten bleiben in Ihren eigenen Konten: Ihr Gmail, Ihr Drive, Ihr Supabase-Projekt.
Dazwischen gibt es keinen Server, niemand sonst hat Zugriff. Die Datenbank ist so
gesperrt, dass ihre öffentliche Schnittstelle gar nichts liefert; lesen können sie nur
Claude (über Ihren eigenen Konnektor) und Ihr eigenes Apps Script. Dateien laufen nie
durch die KI: Google verschiebt sie direkt von Gmail nach Drive. Details in
[docs/security.md](docs/security.md) (Englisch).

## Wie es funktioniert

Alles, was pünktlich passieren muss, erledigen Dinge, die nicht vergessen: Google Apps
Script alle 15 Minuten und geplante Jobs in der Datenbank jede Nacht. Claude macht nur,
was Urteilsvermögen braucht: einen Brief lesen und verstehen, was er bedeutet. Die
Datenbank ist die einzige Quelle der Wahrheit; Todoist, Craft und der Kalender spiegeln
sie nur.

- [docs/architecture.md](docs/architecture.md): Komponenten, Datenmodell, der Weg eines Briefs.
- [docs/apps-script.md](docs/apps-script.md): die Bridge installieren.
- [docs/scheduling.md](docs/scheduling.md): der nächtliche Zeitplan: Uhrzeiten, Reihenfolge.
- [docs/tasks.md](docs/tasks.md): was in der Aufgaben-App landet und wie es sich schließt.
- [docs/settings.md](docs/settings.md): alle Einstellungen und was passiert, wenn sich eine ändert.
- [docs/security.md](docs/security.md): Schlüssel, Rechte, was die KI sieht, Backups.
- [docs/troubleshooting.md](docs/troubleshooting.md): jeder Fehler des Originals und was ihn behebt.

## Stand

Früh. Datenbank, Bridge und E-Mail-Intake liefen einen Monat täglich in der privaten
Originalversion und wurden dann verallgemeinert. Der Einrichtungs-Skill und die Pakete
sind neu. Mit Ecken und Kanten ist zu rechnen, bitte melden.
