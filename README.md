# PiCam — Instrukcja obsługi

Automatyczna stacja timelapse: Raspberry Pi Zero W pobiera zdjęcia z kamery IP
Kenik KG-4230TAS-IL, zapisuje lokalnie i raportuje status przez pliki na karcie SD.
Karta SD jest czytelna na MacBooku bez żadnego dodatkowego oprogramowania.

---

## Sprzęt

| Element | Model |
|---|---|
| Komputer | Raspberry Pi Zero W |
| Kamera | Kenik KG-4230TAS-IL (IP, ONVIF 2.6) |
| Karta SD | min. 32 GB (Class 10 / A1) |
| Zasilanie Pi | USB 5 V / 2,5 A |
| Zasilanie kamery | 12 V DC lub PoE (wg modelu) |
| Sieć | Kamera: LAN (kabel) · Pi: WiFi |

---

## Jednorazowa konfiguracja w biurze

Wykonaj raz — w biurze, gdzie kamera i Pi są w tej samej sieci.

### 1. Kamera — wstępna konfiguracja (jeśli jeszcze nie zrobione)

1. Podłącz kamerę kablem LAN do routera biurowego.
2. Znajdź jej adres IP (np. ze strony routera lub za pomocą skanera sieci).
3. Otwórz panel kamery w przeglądarce: `https://<IP>` (ignoruj ostrzeżenie o certyfikacie).
4. Zaloguj się (domyślnie `admin` / `123456`) i **zmień hasło admina** — kamera
   z pustym hasłem wystawiona do internetu jest podatna na ataki.
5. Wyłącz funkcję **KENIKP2P / Chmura** (zakładka obok TCP/IP, DDNS, NAT),
   jeśli nie jest potrzebna.
6. Upewnij się, że kamera ma **włączone DHCP** (nie statyczny IP).
7. Zanotuj adres MAC kamery: `00:46:b8:28:e2:55` *(już wpisany w konfiguracji)*.

### 2. Pi — przygotowanie systemu

1. Wgraj obraz **Raspberry Pi OS Lite Bookworm 32-bit** na kartę SD
   (np. przez Raspberry Pi Imager).
2. W Imagerze ustaw: hostname `pi`, użytkownika `pi`, hasło, WiFi biurowy,
   włącz SSH.
3. Włóż kartę, uruchom Pi, zaloguj się przez SSH:
   ```
   ssh pi@pi.local
   ```
4. Sklonuj repozytorium i uruchom instalator:
   ```bash
   git clone <adres-repo> picam
   cd picam
   sudo ./install.sh
   ```
   Instalator jest idempotentny — można go uruchomić ponownie bez obaw.
   Opcjonalnie dodaj `--with-tailscale` jeśli chcesz zdalny dostęp.

5. Uruchom sondowanie kamery (kamera musi być w tej samej sieci co Pi):
   ```bash
   sudo onvif-probe.sh <IP-kamery>
   ```
   Skrypt automatycznie: wykrywa endpoint ONVIF, wybiera profil o najwyższej
   rozdzielczości, pobiera URL zdjęcia, zapisuje `camera.conf` na karcie SD
   i weryfikuje zdjęcie testowe. Jeśli się powiedzie, zobaczysz:
   ```
   [onvif-probe] camera.conf written and snapshot verified — OK
   ```

6. Ustaw hasło kamery w pliku `camera.conf` (jeśli zmieniłeś w kroku 1.4):
   ```bash
   # Edytuj /boot/firmware/picam/camera.conf
   CAMERA_PASS=TwojNoweHaslo
   ```
   Lub zrób to z MacBooka po wyjęciu karty SD (patrz poniżej).

### 3. Konfiguracja WiFi docelowego miejsca

Dodaj sieć WiFi miejsca docelowego **obok** sieci biurowej (obydwa profile
są zapamiętane — Pi połączy się z siecią o wyższym priorytecie, która jest
dostępna):

**Sposób 1 — skrypt na MacBooku (zalecany):**
```bash
bash mac/picam-config.sh
```
Wybierz `[1] Skonfiguruj/zmień WiFi` i podaj dane.

**Sposób 2 — ręcznie przez SSH:**
```bash
sudo nmcli connection add type wifi ssid "NazwaSieci" \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "HasloSieci" \
  connection.autoconnect-priority 10
```

### 4. Weryfikacja końcowa (w biurze)

1. Uruchom ponownie Pi:
   ```bash
   sudo reboot
   ```
2. Poczekaj ok. 2 minuty, następnie **wyjmij kartę SD** i włóż do MacBooka.
3. Sprawdź plik `status.log` w folderze `picam/` na karcie — powinien zawierać
   linię podobną do:
   ```
   2026-06-19 08:00:00 | healthcheck/boot | OK: network up
   2026-06-19 08:00:01 | healthcheck/boot | OK: camera snapshot verified
   2026-06-19 08:00:02 | healthcheck/boot | OK: disk space sufficient
   2026-06-19 08:00:02 | healthcheck/boot | summary: OK
   ```
4. Otwórz plik `last_photo.jpg` — powinno być aktualne zdjęcie z kamery.

---

## Wdrożenie na miejscu (dzień pierwszy)

1. Zamontuj kamerę, podłącz ją kablem LAN do lokalnego routera.
2. Umieść Pi w zasięgu WiFi tego routera, podłącz zasilanie.
3. **Poczekaj 5 minut.**
4. Wyjmij kartę SD, włóż do MacBooka i uruchom skrypt konfiguracyjny:
   ```bash
   bash mac/picam-config.sh
   ```
5. Wybierz `[3] Pokaż ostatni status` i sprawdź, czy widać:
   - `camera=FOUND` lub `OK: camera snapshot verified`
   - `summary: OK`
6. Wybierz `[4] Pokaż ostatnie zdjęcie` — zweryfikuj wizualnie, że kamera
   pokazuje właściwe miejsce.

**Jeśli kamera nie jest wykryta (camera=NOT FOUND lub FAIL):**

- Sprawdź, czy kamera jest zasilona i czy świeci dioda.
- Sprawdź, czy kamera i Pi są w tej samej sieci L2 — jeśli router ma
  włączoną izolację klientów WiFi, gościnną sieć lub VLAN, kamera i Pi muszą
  być w tym samym segmencie. Rozwiąż z administratorem sieci na miejscu.
  **Nie można opuścić miejsca bez potwierdzenia wykrycia kamery** — po wyjeździe
  nie ma możliwości zdalnej debuggi odkrycia L2.
- Sprawdź czy kamera ma DHCP (nie statyczny IP spoza zakresu routera).

---

## Obsługa codzienna z MacBooka

Włóż kartę SD do MacBooka, uruchom:
```bash
bash mac/picam-config.sh
```

### Menu główne

```
[1] Skonfiguruj / zmień WiFi
[2] Zmień harmonogram zdjęć
[3] Pokaż ostatni status
[4] Pokaż ostatnie zdjęcie
[5] Wyjdź
```

### Zmiana WiFi

Wybierz `[1]`. Podaj nazwę sieci i hasło (dwa razy, ukryte). Skrypt zapisuje
plik `wifi-update.txt` na karcie. Przy następnym uruchomieniu Pi automatycznie
doda nową sieć i przemianuje plik na `wifi-update.applied` (sukces) lub
`wifi-update.failed` (błąd, np. złe hasło).

### Zmiana harmonogramu

Wybierz `[2]`. Dostępne tryby:

| Tryb | Opis | Klucz w capture.conf |
|---|---|---|
| `interval` | co X minut w oknie czasowym (UTC) | `MODE=interval` |
| `times` | o konkretnych godzinach (UTC) | `MODE=times` |

Przykład `capture.conf` dla zdjęcia co 30 minut od 7:00 do 18:00 (UTC):
```
MODE=interval
INTERVAL_MIN=30
WINDOW_START=07:00
WINDOW_END=18:00
```

Przykład dla zdjęcia o konkretnych godzinach:
```
MODE=times
TIMES=08:00,12:00,16:00
```

> **Uwaga:** wszystkie godziny są w **UTC**. Dla Polski: UTC+1 (zima) lub UTC+2 (lato).
> Jeśli chcesz zdjęcie o 10:00 czasu polskiego latem, wpisz `08:00` w UTC.

Zmiana wchodzi w życie przy kolejnym uruchomieniu timera (do 1 minuty).
Nie jest wymagany restart Pi.

### Ręczna edycja plików na karcie SD

Pliki konfiguracyjne są zwykłym tekstem i można je edytować w edytorze:

| Plik | Zawartość |
|---|---|
| `picam/capture.conf` | harmonogram zdjęć |
| `picam/camera.conf` | dane kamery (MAC, hasło, URL) |
| `picam/status.log` | dziennik zdarzeń (tylko do odczytu) |
| `picam/last_photo.jpg` | ostatnie zdjęcie (tylko do odczytu) |
| `picam/wifi-update.txt` | oczekująca zmiana WiFi |
| `picam/wifi-update.applied` | ostatnio zastosowana sieć WiFi |

---

## Alerty email

PiCam wysyła alert emailem gdy kamera jest niedostępna przez dłuższy czas
(domyślnie 6 nieudanych prób z rzędu). Maksymalnie 3 alerty dziennie.

### Konfiguracja (Gmail)

1. Załóż dedykowane konto Gmail (np. `picam-sender@gmail.com`).
2. Włącz **weryfikację dwuetapową** na tym koncie.
3. Przejdź do: Konto Google → Bezpieczeństwo → **Hasła do aplikacji** →
   utwórz nowe hasło dla „PiCam" (pojawi się 16-znakowy kod).
4. Wyjmij kartę SD, włóż do MacBooka, otwórz plik `picam/alert.conf`
   w edytorze tekstowym i uzupełnij:
   ```
   FROM=picam-sender@gmail.com
   TO=twoj-adres@example.com
   SMTP_USER=picam-sender@gmail.com
   SMTP_PASS=xxxx xxxx xxxx xxxx
   RATE_LIMIT_PER_DAY=3
   ```
5. Zapisz plik i włóż kartę z powrotem do Pi.

> Plik `alert.conf` jest zapisany z uprawnieniami `600` (tylko root może czytać).

---

## Gdzie są zdjęcia

Zdjęcia są zapisywane na partycji rootfs Pi (ext4, niewidocznej na MacBooku)
w katalogu `/var/lib/picam/photos/YYYY-MM-DD/HHMMSS.jpg` (UTC).

Aby pobrać zdjęcia, zaloguj się przez SSH lub Tailscale:
```bash
scp -r pi@pi.local:/var/lib/picam/photos ./zdjecia
```

Domyślnie Pi przechowuje zdjęcia z ostatnich **30 dni** (konfigurowalny przez
`RETENTION_DAYS` w `capture.conf`). Starsze dni są automatycznie usuwane.

---

## Rozwiązywanie problemów

### `status.log` zawiera FAIL / brak zdjęcia

| Objaw | Możliwa przyczyna | Działanie |
|---|---|---|
| `FAIL: network down` | Pi nie połączyło się z WiFi | Sprawdź hasło WiFi; wgraj nowe przez `wifi-update.txt` |
| `FAIL: camera unreachable` | Kamera wyłączona lub inny segment sieci | Sprawdź zasilanie kamery i sieć L2 |
| `WARN: last photo stale` | Brak zdjęcia dłużej niż oczekiwano | Sprawdź harmonogram (UTC!) i czy okno obejmuje bieżącą godzinę |
| `FAIL: disk low` | Karta pełna | Pi automatycznie usuwa najstarszy dzień; zmniejsz `RETENTION_DAYS` |

### Pi restartuje się w pętli

Jeśli healthcheck wykryje 6 kolejnych błędów sieci z rzędu, Pi automatycznie
się zrestartuje (max raz na 6 godzin). To normalne zachowanie — sprawdź WiFi.

### `wifi-update.failed` pojawił się na karcie

Otwórz plik — zawiera opis błędu. Najczęstsza przyczyna: złe hasło WiFi.
Popraw przez `[1]` w menu skryptu i ponownie włóż kartę.

### Skrypt `picam-config.sh` zgłasza „Nie znaleziono karty SD"

- Upewnij się, że karta SD jest włożona i widoczna w Finderze (Finder → pasek
  boczny → Lokalizacje).
- Karta musi mieć folder `picam/` — jeśli `install.sh` jeszcze nie był
  uruchomiony, folder nie istnieje.

### Kamera nie jest wykrywana — administrator podał IP wprost

Jeśli router ma włączoną izolację klientów (WiFi client isolation), `arp-scan`
nie dotrze do kamery. Jeśli administrator sieci zapewnił stały adres IP kamery
(rezerwacja DHCP lub IP statyczne), możesz wpisać go do cache'a ręcznie przez SSH:

```bash
ssh pi@pi.local
echo "192.168.1.50" | sudo tee /var/lib/picam/camera_ip
```

Przy następnym zdjęciu Pi użyje tego IP bezpośrednio, pomijając `arp-scan`.

> **Ważne:** jeśli kamera ma DHCP bez rezerwacji, IP może się zmienić po
> restarcie routera i Pi znowu nie znajdzie kamery. W środowisku z izolacją
> klientów **koniecznie poproś administratora o rezerwację DHCP** (stały IP
> przypisany do MAC `00:46:b8:28:e2:55`).

### Jak sprawdzić logi Pi przez SSH

```bash
ssh pi@pi.local
sudo journalctl -u picam-capture -u picam-healthcheck -u picam-wifi-applier -n 50
```

---

## Dane techniczne

| Parametr | Wartość |
|---|---|
| Hostname Pi | `pi` / `pi.local` |
| MAC kamery | `00:46:b8:28:e2:55` |
| Protokół zdjęcia | HTTP Digest (ONVIF Snapshot) |
| Zdjęcia | JPEG, format kamery, bez transkodowania |
| Czas | UTC (wszystkie znaczniki czasu i nazwy plików) |
| Logi Pi | `journald` + `/boot/firmware/picam/status.log` |
| Watchdog | sprzętowy, 15 s |
| Serwisy | `picam-capture.timer`, `picam-healthcheck.timer`, `picam-wifi-applier.service` |
