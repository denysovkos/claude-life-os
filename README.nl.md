<p align="center">
  <img src="brand/logo.png" width="120" alt="Life OS">
</p>

<h1 align="center">Life OS</h1>

<p align="center">
  <b>Je papierwerk, geregeld.</b><br>
  Een open-source Claude-skill voor Gmail, Google Drive en Supabase
</p>

<p align="center">
  <a href="https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip"><img src="https://img.shields.io/badge/Downloaden-life--os.zip-D97757?style=for-the-badge&logo=anthropic&logoColor=white" alt="life-os.zip downloaden"></a>
</p>

<p align="center">
  <a href="https://github.com/denysovkos/claude-life-os/releases/latest"><img src="https://img.shields.io/github/v/release/denysovkos/claude-life-os?style=flat-square&color=D97757&label=release" alt="Latest release"></a>
  <a href="https://github.com/denysovkos/claude-life-os/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/denysovkos/claude-life-os/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/denysovkos/claude-life-os?style=flat-square&color=1F2937" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/languages-10-4C8BD9?style=flat-square" alt="10 languages">
  <img src="https://img.shields.io/badge/countries-11-3FA37A?style=flat-square" alt="11 countries">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.uk.md">Українська</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pl.md">Polski</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> · <a href="README.it.md">Italiano</a> · <b>Nederlands</b> · <a href="README.ru.md">Русский</a> · <a href="README.pt.md">Português</a></p>

<p align="center">
  <img src="brand/linkedin-card.png" width="100%" alt="Life OS: dagelijkse samenvatting en antwoorden in elke Claude-chat">
</p>

Een persoonlijk systeem voor papierwerk. Het leest je Gmail en Google Drive, houdt een
index bij van elk officieel document, elke brief, elk contract en elke rekening in een
database die van jou is, en zorgt dat geen termijn, stilzwijgende verlenging of
vervaldatum je ontgaat. Je stelt vragen in gewone taal, in elke Claude-chat: "wanneer
verloopt mijn paspoort", "kan ik de sportschool nog opzeggen", "wat staat er in het
huurcontract over huisdieren".

Eén persoon bouwde het voor het eigen leven en gebruikte het een maand lang elke dag. Nu
wordt het iets dat iedereen kan installeren. Programmeren is niet nodig: Claude begeleidt
je bij elke stap.

## Installatie

Dit is voor de gewone Claude: claude.ai in de browser, of de Claude-app op computer of
telefoon.

**1. Download de skill: [life-os.zip](https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip)** (niet uitpakken). Het is één skill met
alles erin: installatie, mail, bestanden, de nachtelijke controle, de maandelijkse review
en de antwoorden op je vragen. De link wijst altijd naar de nieuwste versie
([alle releases](https://github.com/denysovkos/claude-life-os/releases)).

**2. Voeg hem toe aan Claude.** Open in Claude **Settings** → **Capabilities**, zet
**Code execution and file creation** aan (skills hebben dat nodig) en klik dan onder
**Skills** op **Upload skill** en kies `life-os.zip`.

**3. Koppel je accounts.** **Settings** → **Connectors**: Google Drive, Gmail en Supabase;
desgewenst ook Google Calendar, Todoist, Craft.

**4. Open een nieuwe chat en schrijf: `set up life os`.** Vanaf hier leidt Claude. Het
stelt een paar vragen (je taal, je land, welke apps je gebruikt), maakt de database en
de Drive-mappen aan en controleert elke stap voor de volgende.

**5. Installeer de Google Apps Script-brug** wanneer Claude erom vraagt. Het is één
bestand dat elke 15 minuten in je Google-account draait, ook als Claude niet draait
(knopnamen in het Engels; Google kan ze in het Nederlands tonen):

- script.google.com → **New project** → plak de code die Claude laat zien → opslaan;
- **Project Settings** → **Script Properties** → voeg `SUPABASE_URL` en
  `SUPABASE_SECRET_KEY` toe (Claude zegt waar je ze vindt; de sleutel hoort alleen daar,
  nooit in een chat);
- kies de functie `install` → **Run** → **Review permissions** → je account → "Google
  hasn't verified this app" → **Advanced** → **Go to Life OS bridge (unsafe)** →
  **Select all** → **Allow**. De waarschuwing is normaal: het is je eigen script en het
  draait alleen in je eigen account.

Stap voor stap, met uitleg van elke toestemming (in het Engels):
[docs/apps-script.md](docs/apps-script.md).

**6. Laat het elke nacht draaien.** Claude start niet vanzelf, dus maak vier geplande
runs aan, het liefst 's nachts en in deze volgorde: mail om **01:05**, bestanden om
**02:05**, de nachtelijke controle met je dagelijkse samenvatting om **03:05** en de
maandelijkse review op de 1e om **04:05**. Mail eerst, omdat de indeling ervan de brug
vertelt welke bijlagen te kopiëren; de bestanden een uur later indexeren ze nog dezelfde
nacht; de controle als laatste, zodat de ochtendsamenvatting alles bevat. Maak ze aan als geplande taken in Claude, elk met de prompt uit
[docs/scheduling.md](docs/scheduling.md) (in het Engels).

Dat is alles, ongeveer 30 minuten. Later kun je altijd **`life os doctor`** schrijven: het
controleert het hele systeem en zegt precies wat je moet oplossen.

**Bijwerken:** download de nieuwe `life-os.zip` en upload hem op dezelfde manier
(verwijder eerst de oude skill als Claude hem niet vervangt). Schrijf daarna
`life os doctor`: het voert database-updates en nieuwe regels zelf door.


### Wat je nodig hebt

- Een Google-account (Gmail en Google Drive).
- Een Claude-abonnement met skills en connectors.
- Een gratis [Supabase](https://supabase.com)-account. Supabase is de database met de
  index; het gratis abonnement volstaat. Claude maakt het project voor je aan.
- Optioneel: Todoist voor taken, Craft voor het maandrapport. Zonder die apps komen taken
  en rapporten per e-mail en als Google Docs.

## Wat het voor je doet

- **Elke nacht** leest het nieuwe mail, verdeelt die over 10 categorieën (rekeningen,
  overheid, bank, contracten, reizen enzovoort), haalt bedragen en betaaldata eruit en
  maakt een taak aan als je iets moet doen. Reizen en afspraken worden
  agenda-afspraken.
- **Belangrijke bijlagen** (rekeningen, contracten, brieven van instanties) worden
  automatisch naar Google Drive gekopieerd, in de juiste map gezet en met hun volledige
  tekst geïndexeerd.
- **Het volgt termijnen, niet alleen data.** Een verblijfsvergunning die verloopt; een
  besluit waartegen je binnen een termijn bezwaar kunt maken; een verzekering die
  stilzwijgend verlengt tenzij je drie maanden vooraf opzegt: elk wordt een termijn met
  herinneringen die vaker komen naarmate hij dichterbij komt. Hoe een termijn wordt
  berekend, hangt af van je land.
- **Een korte dagelijkse samenvatting**, alleen op dagen dat er iets toe doet. Nooit een
  "alles in orde".
- **Een maandelijkse review**: wat je elke maand betaalt, wat er veranderd is, wat je tot
  wanneer kunt opzeggen, wat in je belastingaangifte hoort en wat vreemd lijkt.
- **Een noodmap**: een Google Doc, dagelijks herschreven, met lopende zaken, termijnen,
  contracten, verzekeringen, waar de originelen liggen en wie je moet bellen.

## Taken in je takenapp

De database houdt de lijst bij; de takenapp spiegelt die alleen, dus er gaat niets
verloren als je van app wisselt of er geen gebruikt. Met Todoist krijg je:

| Taak | Wanneer |
|---|---|
| `📅 Daily brief <datum>: <het belangrijkste>` | alleen op dagen dat er iets toe doet; de samenvatting staat in de beschrijving |
| `💌 <categorie> <afzender>: <wat te doen>` | een brief vraagt om actie |
| `⚠️ <document> expires <datum>: <bestand>` | een document verloopt binnen 30 dagen |
| `🧾 Review <maand>: <belangrijkste beslissing>` | eens per maand, de beslissingen die alleen jij kunt nemen |
| `⚠️ <taak> failed <datum>` | een nachtelijke run had fouten |

De titels staan in de taal die je kiest; de woorden `Daily brief` blijven Engels, omdat
het systeem daaraan zijn eigen samenvatting herkent. Een taak afvinken sluit ook de
termijn erachter. Meer in [docs/tasks.md](docs/tasks.md) (in het Engels).

## Instellingen

Alle instellingen staan in één tabel van je eigen database, `life_settings`, en elke
wijziging wordt vastgelegd in `settings_history`, zichtbaar en terug te draaien. Om iets
te veranderen, zeg je het gewoon: "zet de taal op Engels", "ik ben naar Duitsland
verhuisd", "zet mijn zus in de noodmap". Als je land of de regels daar veranderen, worden
al berekende termijnen opnieuw berekend, nadat Claude je heeft laten zien wat er
verschuift. Details in [docs/settings.md](docs/settings.md) (in het Engels).

## Talen en landen

Het systeem leest mail in elke taal. Zijn eigen teksten (samenvattingen, taken,
rapporten, noodmap, mapnamen) bestaan in deze talen:

| Taal | Status |
|---|---|
| English, Deutsch, Українська | volledig en getest |
| Polski, Français, Español, Italiano, Nederlands, Русский, Português | eerste vertaling, Engels waar die ontbreekt |

Juridische regels (hoe een bezwaartermijn wordt berekend, wanneer een contract opzegbaar
is, tot wanneer je een aankoop kunt terugsturen, wanneer de aangifte moet worden
ingediend) komen in een **regiopakket**:

| Land | Status |
|---|---|
| 🇩🇪 Duitsland | volledig en getest |
| 🇦🇹 🇫🇷 🇪🇸 🇮🇹 🇳🇱 🇵🇹 🇵🇱 🇬🇧 🇺🇸 🇺🇦 Oostenrijk, Frankrijk, Spanje, Italië, Nederland, Portugal, Polen, Verenigd Koninkrijk, Verenigde Staten, Oekraïne | bèta: geschreven op basis van de wetten die elke regel noemt, nog niet ter plaatse gecontroleerd |

Elders volgt het systeem nog steeds elke datum die het leest, maar gebruikt het
voorzichtige standaardwaarden en vraagt het je naar de lokale regels. Correcties op
bètapakketten of een nieuw land zijn zeer welkom: [packs/README.md](packs/README.md).

## Privacy en veiligheid

Je gegevens blijven in je eigen accounts: je Gmail, je Drive, je Supabase-project. Er zit
geen server tussen en niemand anders heeft toegang. De database is zo afgesloten dat de
openbare interface helemaal niets teruggeeft; alleen Claude (via je eigen connector) en
je eigen Apps Script kunnen hem lezen. Bestanden gaan nooit door de AI: Google verplaatst
ze rechtstreeks van Gmail naar Drive. Details in [docs/security.md](docs/security.md) (in
het Engels).

## Hoe het werkt

Alles wat op tijd moet gebeuren, wordt gedaan door dingen die niet vergeten: Google Apps
Script elke 15 minuten en geplande taken in de database elke nacht. Claude doet alleen
wat oordeel vraagt: een brief lezen en begrijpen wat hij betekent. De database is de
enige bron van waarheid; Todoist, Craft en de agenda spiegelen hem alleen.

- [docs/architecture.md](docs/architecture.md): onderdelen, datamodel, de weg van een brief.
- [docs/apps-script.md](docs/apps-script.md): de brug installeren.
- [docs/scheduling.md](docs/scheduling.md): het nachtschema: tijden, volgorde.
- [docs/tasks.md](docs/tasks.md): wat er in de takenapp komt en hoe het wordt afgesloten.
- [docs/settings.md](docs/settings.md): alle instellingen en wat er gebeurt als er een verandert.
- [docs/security.md](docs/security.md): sleutels, rechten, wat de AI ziet, back-ups.
- [docs/troubleshooting.md](docs/troubleshooting.md): elke storing van het origineel en de oplossing.

## Status

Vroeg. De database, de brug en de mailverwerking draaiden een maand lang dagelijks in de
oorspronkelijke privéversie en zijn daarna algemeen gemaakt. De installatieskill en de
pakketten zijn nieuw. Verwacht ruwe randjes en meld ze graag.
