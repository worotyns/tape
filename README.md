# TABULA — rejestrator, który niczego nie kasuje

Appka na Maca do nagrywania głosu. **Bez okna głównego**: ikona w pasku
systemu jest wyświetlaczem, a interfejs to globalne skróty i dźwięk. Jedyne
okno to Preferencje, otwierane z menu w pasku.

Do codziennego użytku wystarczą trzy gesty:

- **`⌃⌥R`** — nagrywaj / stop.
- **`⌃⌥M`** — zaznacz moment. W trakcie nagrywania stawia marker; poza nim
  cofa taśmę o ~2,5 s i odsłuchuje.
- **`⌃⌥↑` / `⌃⌥↓`** — idź po cue. Kursor od razu gra to, na co trafił.

## Koncept: nagranie, nie plik

Nagranie nie jest plikiem, który się otwiera, zapisuje i zamyka. Jest **taśmą**,
na którą się pisze i z której nic nie wolno zgubić. Z tego wynikają wszystkie
decyzje w appce — także te, które na pierwszy rzut oka wyglądają na brak
funkcji:

1. **Nic nie kasuje.** Nie ma delete, nie ma nadpisywania, nie ma „zapisz
   jako”. Archiwum rośnie w jedną stronę — i to jest funkcja, nie zaległość.
2. **Zapis jest append-only i naprawialny.** Metadane lądują przez `.tmp` +
   `F_FULLFSYNC` + atomowy `rename`, a każdy marker trafia do dziennika
   zdarzeń. Jeśli proces padnie w środku nagrania, `recover()` odtworzy je
   z rozmiaru pliku i z dziennika — i jest idempotentny, więc wolno go puścić
   dwa razy.
3. **Nawigacja idzie po cue, nie po plikach.** Cue to start nagrania plus każdy
   marker MEM. Nie ma listy plików ani folderów do przeklikiwania: jest jedna
   liniowa taśma z punktami, po której chodzi kursor.
4. **Ruch kursora to odsłuch.** Przesunięcie kursora nie „wybiera” pozycji —
   od razu ją gra. Momentu w nagraniu szukasz więc słuchem, nie wzrokiem.
5. **MEM to przewijanie taśmy.** MEM nie ma własnej akcji nawigacyjnej (nie
   duplikuje kursora), przez co jest wolny i służy jako modyfikator precyzji:
   przytrzymany kręci o kilka sekund w obrębie nagrania, a poza nagrywaniem
   cofa ~2,5 s — jak cofnięcie taśmy kciukiem, żeby usłyszeć to jeszcze raz.
6. **Archiwum jest fizyczne.** Całe archiwum to jeden folder (albo karta):
   `manifest.json` + dziennik zdarzeń + WAV-y. Format jest ten sam co
   w symulatorze JS, więc oba czytają ten sam folder.

To **koncept**, nie symulator sprzętu. Wypadły bateria, quota karty, deep sleep,
wkładanie i wyjmowanie karty oraz dioda RGB jako model — zostało zachowanie,
które ma sens na desktopie.

## Instalacja

```bash
./scripts/install.sh          # buduje i instaluje do /Applications
```

Albo **bez terminala:** dwuklik na `Install TABULA.command` w Finderze.

Po instalacji TABULA jest zwykłą appką: uruchamiasz ją z Findera, Spotlighcie
albo Launchpada. Nie ma ikony w Docku (jest akcesorium, `LSUIElement`) i nigdy
nie przejmuje focusu — zamyka się z własnego menu w pasku.

| Flaga | Efekt |
|---|---|
| `--user` | instaluje do `~/Applications` zamiast do `/Applications` |
| `--login` | dodaje `LaunchAgent`, żeby startowała przy logowaniu |
| `--dmg` | buduje `dist/TABULA-0.1.dmg` (przeciągnij-do-Applications) |
| `--no-launch` | instaluje bez uruchamiania |
| `--uninstall` | usuwa appkę i login item |

`--uninstall` **nie rusza nagrań** — one żyją w `~/Documents/TABULA` i nic ich nie
kasuje, ani instalacja, ani odinstalowanie.

### Uruchamianie z katalogu builda

```bash
./scripts/run.sh              # build release + .app + launch
./scripts/run.sh --log        # w pierwszym planie, widać stderr
```

`.app` jest obowiązkowe, nie kosmetyczne: TCC czyta
`NSMicrophoneUsageDescription` z `Info.plist`, więc gołe `swift run` dostaje
odmowę dostępu do mikrofonu **bez żadnego pytania**.

### Zgoda na mikrofon przy aktualizacjach

macOS wiąże zgodę na mikrofon z sygnaturą kodu. Przy podpisie ad-hoc każdy
rebuild to nowy cdhash, więc TCC pyta ponownie (albo po cichu odmawia — co jest
gorsze). Instalator ostrzega, gdy update zmieni sygnaturę. Stała tożsamość
usuwa problem na zawsze:

1. Keychain Access › Certificate Assistant › Create a Certificate
2. nazwa `TABULA Dev`, Identity Type `Self Signed Root`, Certificate Type `Code Signing`
3. `TABULA_SIGN_IDENTITY="TABULA Dev" ./scripts/install.sh`

Alternatywnie darmowy certyfikat „Apple Development" z Xcode (personal team).

## Skróty

Wszystkie skróty są edytowalne: **menu w pasku → Preferencje… → Global
shortcuts**. Poniżej wartości domyślne.

| Skrót | Akcja |
|---|---|
| `⌃⌥R` | nagrywanie on/off (przy pierwszym razie poprosi o mikrofon) |
| `⌃⌥M` | **podczas nagrywania:** marker · **poza:** cofnij 2,5 s i odsłuchaj |
| `⌃⌥↑` albo `⌃⌥←` | poprzedni cue (z odsłuchem) |
| `⌃⌥↓` albo `⌃⌥→` | następny cue (z odsłuchem) |
| `⌃⌥⇧↑` / `⌃⌥⇧↓` | drobne przewijanie ∓5 s (w obrębie nagrania) |
| `⌃⌥⏎` | play / pause w bieżącym miejscu |
| `⌃⌥H` | „gdzie jestem" — wysokość tonu = pozycja w archiwum |

**Cue na obu osiach.** Pierwsza wersja dawała cue na `←`/`→`, a scrub na
`↑`/`↓` — co było błędem, bo w symulatorze koło *jest* na `↑`/`↓`, a ręka sama
sięga po strzałki w pionie. Teraz dowolna strzałka chodzi po cue: w górę i
w lewo do tyłu, w dół i w prawo do przodu. `Shift` to ta sama oś o ziarno
drobniej: przewijanie w bieżącym nagraniu.

### Trzy rzeczy, które sprawiają, że nawigacja "nie działa"

1. **Ściana była cicha.** Na pierwszym cue `⌃⌥↑` nie robiło *nic* — żadnego
dźwięku, żadnego mignięcia. Nie do odróżnienia od zepsutej appki. Teraz końce
archiwum mają własny, niski blip (raz na przytrzymanie, nie w kółko).
2. **Kursor startował od zera po każdym uruchomieniu.** Pozycja jest teraz
zapamiętana (po tożsamości cue, nie indeksie — przeżywa dopisanie nowych nagrań).
3. **Po nagraniu kursor zostawał na starym klipie.** Teraz parkuje na tym, co
właśnie nagrałeś — jak głowica magnetofonu. Wcześniej po `⌃⌥R`/stopie pierwsze
naciśnięcie `⌃⌥↓` odtwarzało stary klip i wyglądało jak zepsuta nawigacja.

Mapa cue jest do podejrzenia bez GUI: `Tabula --inspect` wypisuje całą listę w
kolejności.

Globalne skróty rejestruje Carbon `RegisterEventHotKey`: **nie wymaga**
uprawnienia Accessibility i **połyka** klawisz. `NSEvent.addGlobalMonitorForEvents`
wymagałby Accessibility i przepuszczałby klawisz do aplikacji z focusem — czyli
każdy skrót wpisywałby się jako znak tam, gdzie akurat piszesz.

## Preferencje

Menu w pasku to tylko linia stanu, **Preferencje…** i **Quit** — całe poruszanie
się po archiwum należy do skrótów, więc w menu nie ma drugiej, rozjeżdżającej się
z nimi nawigacji. Preferencje zbierają to, co wcześniej było podmenu:

- **Global shortcuts** — kliknij skrót i naciśnij nowe klawisze; `Esc` anuluje,
  `+` dodaje alternatywę, `×` usuwa. Na czas nagrywania skrótu globalne skróty są
  chwilowo wyrejestrowane, inaczej Carbon połknąłby właśnie wciskaną kombinację.
  Kolizje są odrzucane z komunikatem.
- **Launch TABULA at login** — ta sama `LaunchAgent`, którą pisze
  `install.sh --login`, więc checkbox i instalator nie mogą się rozjechać.
- **Archive** — ścieżka archiwum, „Open recording folder” i „Change…”.
- **Microphone** — wzmocnienie i podgląd poziomu.
- Trzy linijki pomocy, które wcześniej siedziały w menu.

## Ikona = wyświetlacz

| Kolor | Tryb | Znaczenie |
|---|---|---|
| czerwony | stały | nagrywanie |
| czerwony | miga | błąd (np. brak mikrofonu) |
| zielony | stały / miga | odtwarzanie / pauza |
| cyjan | błysk 250 ms | detent — przeskok między cue |
| magenta | błysk 250 ms | drobny scrub |
| szary | przygaszony | bezczynność |

Kropka jest rysowana jako nietemplate'owy `NSImage` z ciemnym obrysem, żeby
czytała się i na jasnym, i na ciemnym pasku. Pulsowanie animuje pętla 20 Hz.

Ta sama kropka jest **ikoną appki** — powiększona i osadzona na płaskim
grafitowym korpusie (`scripts/make-icon.swift`). Płaska do końca: bez
gradientu, bez cienia, bez fazowania i bez poświaty. Zostają dwie decyzje —
kolor i rozmiar kropki — i obie przeżywają skalowanie do 16 px w Finderze,
bo ikona jest rysowana wektorowo w każdym rozmiarze, a nie pomniejszana
z 1024 px. Czerwień trafiła na ikonę, bo jako jedyna ma stan stały —
nagrywanie; migająca czerwień to błąd, a pozostałe kolory żyją wyłącznie
w pasku. Ikona pokazuje się w Finderze, na dysku z `--dmg` i w Get Info;
`.icns` nie jest w repo, bo dorysowuje go `make-app.sh`.

## Archiwum

Domyślnie `~/Documents/TABULA/` (albo inna ścieżka wskazana z menu — wtedy
zapamiętana). Format jest **identyczny z symulatorem JS**, więc oba mogą czytać
ten sam folder:

```
TABULA/
  manifest.json                 # cardId, nextSeq (zapis zgodny z symulatorem)
  events.jsonl                  # dziennik zdarzeń, append-only
  recordings/rec_000001.wav     # PCM mono 16 kHz s16le
  metadata/rec_000001.json      # czas trwania, markery (offsety w próbkach)
```

Preferencje → **Archive → „Change…”** pozwalają wskazać inną ścieżkę
(zapisywaną w preferencjach). Do jednorazowego testu bez zapisu służy flaga:

```bash
.build/Tabula.app/Contents/MacOS/Tabula -libraryPath /tmp/tabula-test
```

## Trwałość — co jest sprawdzone

| Właściwość | Jak |
|---|---|
| proces zabity w trakcie zapisu | nagłówek WAV pisany na końcu, `recover()` liczy długość z rozmiaru pliku |
| **markery przeżywają kill** | dziennik zdarzeń ma każdy `MARKER_ADDED`, recovery je odtwarza |
| metadane nigdy nie są połowiczne | zapis do `.tmp` + `F_FULLFSYNC` + atomowy `rename` |
| recovery jest idempotentne | fakt odzyskania trafia jako `RECORDING_FINALIZED` do dziennika |
| uszkodzone metadane nie trują archiwum | plik idzie do kwarantanny `.corrupt` |
| nic nie kasuje nagrania | brak delete; markery przycięte do naprawionej długości, nie odwrotnie |
| dwie kopie appki nie zniszczą archiwum | `flock` na `<archiwum>/.lock`, jedna pisząca na raz |

Ostatni punkt ma znaczenie dopiero po instalacji: `open` na ten sam bundle
odtworzy działającą instancję, ale **zainstalowana appka i świeżo zbudowana to
dwa różne bundle**. Bez blokady obie przeczytałyby ten sam `nextSeq` i obie
utworzyły `rec_000006.wav` — a otwarcie pliku go truncate'uje, więc pierwsze
nagranie przepada. Blokada jest doradcza (`flock`), więc system zwalnia ją sam
po zabiciu procesu — nie ma martwego locka po crashu.

## Weryfikacja

```bash
swift test                          # 37 testów domeny i skrótów, headless
./scripts/run.sh --no-open
BIN="$(swift build -c release --show-bin-path)/Tabula"
"$BIN" --selftest                   # potok end-to-end prawdziwym binarium
"$BIN" --inspect                    # co jest w archiwum (domyślnie ~/Documents/TABULA)
```

`--selftest` przechodzi cały potok: nagranie → marker → utrata zasilania →
recovery → odbudowa cue → przewinięcie MEM, plus sprawdzenie, że zapisany WAV
jest czytelny dla CoreAudio i zawiera realny dźwięk.

`--inspect` pokazuje, czy mikrofon naprawdę coś nagrał, czy tylko ciszę:

```
rec_000002  0:13  ⚑2  406 KB   peak 37.7%  rms 2.52%  real audio
      ⚑1 @ 0:06  (92768 samples)
      ⚑2 @ 0:08  (121474 samples)
```

## Struktura

```
Sources/TabulaCore/     domena: bez AppKit, bez CoreAudio, bez filesystemu
  Device.swift          maszyna stanów, cue, markery, odsłuch, MEM
  Library.swift         archiwum, manifest, dziennik, recovery, repairWav
  Audio.swift           strumieniowy zapis WAV, analiza PCM, syntetyczny sygnał
  Keybindings.swift     akcje, kombinacje, defaults, scalanie przy upgrade, kolizje
  Protocols.swift       MicSource / AudioSink / Clock — granice wymienne
Sources/Tabula/         AppKit + CoreAudio: StatusLED, HotKeys, MicCapture,
                        AudioPlayer, ToneFeedback, PreferencesWindow,
                        AppDelegate, SelfTest, Inspector
Tests/TabulaCoreTests/  37 scenariuszy przeniesionych z symulatora + skróty
scripts/make-icon.swift wektorowa ikona appki → Resources/AppIcon.icns
```

Rdzeń nie zna AppKitu ani CoreAudio — ta sama granica, której w symulatorze JS
pilnuje `HARDWARE_ABSTRACTION.md`, więc port na ESP-IDF nadal jest realny.

## Znane ograniczenia i następne kroki

- **Brak kompresji** — pliki są PCM 16 kHz mono (~1,9 MB/min). Świadomie poza v1.
- **Pozycja odtwarzania jest modelowana**, nie czytana z `AVAudioPlayerNode`.
  Dryf jest ograniczony, bo każdy cue startuje od nowa, ale przy długim
  odsłuchu bez przerwy może się rozjechać. Naturalny następny krok.
- **Bez podpisywania** — przy ad-hoc sygnaturze zmienia się cdhash, więc TCC
  może pytać o mikrofon po każdym rebuildzie. Lekarstwo: darmowy certyfikat
  „Apple Development" (personal team) i
  `TABULA_SIGN_IDENTITY="Apple Development: …" ./scripts/run.sh`.
- **Login item to `LaunchAgent`** — checkbox w Preferencjach (i `install.sh
  --login`) piszą plist do `~/Library/LaunchAgents`; `SMAppService` wymagałby
  stabilnej sygnatury.
- **Jedno okno odsłuchu na raz** — brak kolejki odtwarzania, zgodnie z konceptem.
