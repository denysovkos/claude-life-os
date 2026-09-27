# claude-life-os

[English](README.md) · [Українська](README.uk.md) · [Deutsch](README.de.md) · **Polski** · [Français](README.fr.md) · [Español](README.es.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Русский](README.ru.md) · [Português](README.pt.md)

Osobisty system do papierów. Czyta Twój Gmail i Dysk Google, prowadzi indeks wszystkich
formalnych dokumentów, listów, umów i rachunków w bazie danych, która należy do Ciebie,
i pilnuje, żeby żaden termin, automatyczne przedłużenie ani koniec ważności nie umknął.
Pytasz zwykłym językiem, w dowolnym czacie Claude: „kiedy wygasa mój paszport”, „czy
mogę jeszcze wypowiedzieć siłownię”, „co umowa najmu mówi o zwierzętach”.

Zbudowała go jedna osoba dla własnego życia i przez miesiąc używała go codziennie. Teraz
staje się czymś, co każdy może zainstalować. Programowanie nie jest potrzebne: Claude
prowadzi przez każdy krok.

## Instalacja

To jest dla zwykłego Claude: claude.ai w przeglądarce albo aplikacja Claude na komputer
lub telefon.

**1. Pobierz skill: [life-os.zip](https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip)** (nie rozpakowuj go). To jeden skill, który
zawiera wszystko: konfigurację, pocztę, pliki, nocną kontrolę, miesięczny przegląd i
odpowiedzi na Twoje pytania. Link zawsze prowadzi do najnowszej wersji
([wszystkie wydania](https://github.com/denysovkos/claude-life-os/releases)).

**2. Dodaj go do Claude.** W Claude otwórz **Settings** → **Capabilities**, włącz
**Code execution and file creation** (skille tego potrzebują), potem w sekcji **Skills**
kliknij **Upload skill** i wybierz `life-os.zip`.

**3. Połącz konta.** **Settings** → **Connectors**: Google Drive, Gmail i Supabase;
opcjonalnie także Google Calendar, Todoist, Craft.

**4. Otwórz nowy czat i napisz: `set up life os`.** Dalej prowadzi Claude. Zada kilka
pytań (język, kraj, z jakich aplikacji korzystasz), utworzy bazę danych i foldery na
Dysku i sprawdzi każdy krok przed następnym.

**5. Zainstaluj most Google Apps Script**, gdy Claude poprosi. To jeden plik, który
działa na Twoim koncie Google co 15 minut, nawet gdy Claude nie działa (nazwy przycisków
po angielsku; Google może je pokazać po polsku):

- script.google.com → **New project** → wklej kod pokazany przez Claude → zapisz;
- **Project Settings** → **Script Properties** → dodaj `SUPABASE_URL` i
  `SUPABASE_SECRET_KEY` (Claude powie, skąd je wziąć; klucz wpisujesz tylko tam, nigdy do
  czatu);
- wybierz funkcję `install` → **Run** → **Review permissions** → Twoje konto → „Google
  hasn't verified this app” → **Advanced** → **Go to Life OS bridge (unsafe)** →
  **Select all** → **Allow**. Ostrzeżenie jest normalne: to Twój własny skrypt,
  działający tylko na Twoim koncie.

Krok po kroku, z wyjaśnieniem każdego uprawnienia (po angielsku):
[docs/apps-script.md](docs/apps-script.md).

**6. Niech działa co noc.** Claude sam się nie uruchamia, więc utwórz cztery zaplanowane
uruchomienia, najlepiej w nocy i w tej kolejności: poczta o **01:05**, pliki o **02:05**,
nocna kontrola z codziennym briefem o **03:05** i miesięczny przegląd 1. dnia miesiąca o
**04:05**. Poczta najpierw, bo jej kategorie mówią mostowi, które załączniki skopiować;
pliki godzinę później indeksują je tej samej nocy; kontrola na końcu, żeby poranny brief
zawierał wszystko. Utwórz je jako zaplanowane zadania w Claude, każde z promptem z
[docs/scheduling.md](docs/scheduling.md) (po angielsku).

To wszystko, około 30 minut. Później w dowolnej chwili napisz **`life os doctor`**:
sprawdzi cały system i powie dokładnie, co naprawić.

**Aktualizacja:** pobierz nowy `life-os.zip` i wgraj go tak samo (jeśli Claude nie
zastąpi skilla, najpierw usuń stary). Potem napisz `life os doctor`: sam wprowadzi
aktualizacje bazy i nowe przepisy.


### Czego potrzebujesz

- Konta Google (Gmail i Dysk Google).
- Planu Claude ze skillami i konektorami.
- Darmowego konta [Supabase](https://supabase.com). Supabase to baza danych z indeksem;
  darmowy plan wystarczy. Projekt Claude utworzy sam.
- Opcjonalnie: Todoist na zadania, Craft na miesięczny raport. Bez nich zadania i raporty
  przychodzą mailem i jako dokumenty Google.

## Co robi

- **Każdej nocy** czyta nową pocztę, dzieli ją na 10 kategorii (rachunki, urzędy, bank,
  umowy, podróże itd.), wyciąga kwoty i terminy płatności i tworzy zadanie, gdy musisz
  coś zrobić. Podróże i wizyty trafiają do kalendarza.
- **Ważne załączniki** (rachunki, umowy, pisma z urzędów) są automatycznie kopiowane na
  Dysk Google, odkładane do właściwego folderu i indeksowane z pełnym tekstem.
- **Śledzi terminy, nie tylko daty.** Karta pobytu, która wygasa; decyzja, od której
  można się odwołać w ciągu miesiąca; ubezpieczenie, które przedłuża się samo, jeśli nie
  wypowiesz go trzy miesiące wcześniej: każde staje się terminem z przypomnieniami, które
  pojawiają się coraz częściej. Sposób liczenia terminu zależy od Twojego kraju.
- **Krótki codzienny brief**, tylko w dni, gdy coś jest ważne. Bez wiadomości „wszystko
  w porządku”.
- **Miesięczny przegląd**: ile płacisz co miesiąc, co się zmieniło, co i do kiedy możesz
  wypowiedzieć, co trafi do zeznania podatkowego i co wygląda podejrzanie.
- **Teczka awaryjna**: dokument Google, odświeżany codziennie, z otwartymi sprawami,
  terminami, umowami, ubezpieczeniami, miejscem przechowywania oryginałów i kontaktami.

## Zadania w menedżerze zadań

Listę prowadzi baza, menedżer zadań tylko ją odzwierciedla, więc nic nie ginie, gdy
zmienisz aplikację albo nie używasz żadnej. Z Todoist dostajesz:

| Zadanie | Kiedy |
|---|---|
| `📅 Daily brief <data>: <najważniejsze>` | tylko w dni, gdy coś jest ważne; brief jest w opisie |
| `💌 <kategoria> <nadawca>: <co zrobić>` | list wymaga działania |
| `⚠️ <dokument> expires <data>: <plik>` | dokument wygasa w ciągu 30 dni |
| `🧾 Review <miesiąc>: <główna decyzja>` | raz w miesiącu, decyzje, które możesz podjąć tylko Ty |
| `⚠️ <zadanie> failed <data>` | nocne uruchomienie miało błędy |

Tytuły są w wybranym przez Ciebie języku; słowa `Daily brief` zostają po angielsku, bo
po nich system rozpoznaje własny brief. Zamknięcie zadania zamyka też termin za nim.
Więcej w [docs/tasks.md](docs/tasks.md) (po angielsku).

## Ustawienia

Wszystkie ustawienia są w jednej tabeli Twojej własnej bazy, `life_settings`, a każda
zmiana zapisuje się w `settings_history`, więc widać ją i można ją cofnąć. Żeby coś
zmienić, po prostu powiedz: „zmień język na angielski”, „przeprowadziłem się do
Hiszpanii”, „dodaj siostrę do teczki awaryjnej”. Gdy zmienia się kraj albo jego przepisy,
już policzone terminy są przeliczane, po tym jak Claude pokaże, co się przesunie.
Szczegóły w [docs/settings.md](docs/settings.md) (po angielsku).

## Języki i kraje

Pocztę system czyta w każdym języku. Własne komunikaty (briefy, zadania, raporty, teczka
awaryjna, nazwy folderów) są dostępne w tych językach:

| Język | Stan |
|---|---|
| English, Deutsch, Українська | kompletne i przetestowane |
| Polski, Français, Español, Italiano, Nederlands, Русский, Português | wstępne tłumaczenie, braki po angielsku |

Przepisy (jak liczyć termin na odwołanie, kiedy można wypowiedzieć umowę na telefon, do
kiedy zwrócić zakup, kiedy złożyć zeznanie) przychodzą w **pakiecie regionalnym**.
**Niemcy** są kompletne. Wszędzie indziej system nadal śledzi każdą przeczytaną datę,
ale używa ostrożnych wartości zastępczych i pyta Cię o lokalne przepisy. Jak dodać język
albo kraj: [packs/README.md](packs/README.md).

## Prywatność i bezpieczeństwo

Twoje dane zostają na Twoich kontach: Twój Gmail, Twój Dysk, Twój projekt Supabase.
Pomiędzy nimi nie ma żadnego serwera i nikt inny nie ma dostępu. Baza jest zamknięta
tak, że jej publiczny interfejs nie zwraca niczego; czytać ją mogą tylko Claude (przez
Twój konektor) i Twój własny Apps Script. Pliki nigdy nie przechodzą przez AI: Google
przenosi je bezpośrednio z Gmaila na Dysk. Szczegóły w
[docs/security.md](docs/security.md) (po angielsku).

## Jak to działa

Wszystko, co musi się wydarzyć na czas, robią rzeczy, które nie zapominają: Google Apps
Script co 15 minut i zaplanowane zadania w bazie co noc. Claude robi tylko to, co wymaga
osądu: przeczytać list i zrozumieć, co znaczy. Baza jest jedynym źródłem prawdy; Todoist,
Craft i kalendarz tylko ją odzwierciedlają.

- [docs/architecture.md](docs/architecture.md): komponenty, model danych, droga jednego listu.
- [docs/apps-script.md](docs/apps-script.md): instalacja mostu.
- [docs/scheduling.md](docs/scheduling.md): nocny harmonogram: godziny, kolejność.
- [docs/tasks.md](docs/tasks.md): co trafia do menedżera zadań i jak się zamyka.
- [docs/settings.md](docs/settings.md): wszystkie ustawienia i co się dzieje, gdy się zmieniają.
- [docs/security.md](docs/security.md): klucze, uprawnienia, co widzi AI, kopie zapasowe.
- [docs/troubleshooting.md](docs/troubleshooting.md): każda awaria oryginału i co ją naprawia.

## Stan

Wczesna wersja. Baza, most i przetwarzanie poczty działały codziennie przez miesiąc w
prywatnej wersji oryginalnej, a potem zostały uogólnione. Skill instalacyjny i pakiety
są nowe. Spodziewaj się niedoskonałości i zgłaszaj je.
