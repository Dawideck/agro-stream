#!/usr/bin/env bash
# PiCam — Konfiguracja karty SD.
# Uruchom na MacBooku gdy karta SD jest włożona.
# Bash 3.2 compatible: no associative arrays, no mapfile, no GNU-only flags.

# Inject for testing: PICAM_VOLUMES_ROOT (default /Volumes),
#   PICAM_DISKUTIL (default diskutil), PICAM_OPEN (default open).
VOLUMES_ROOT="${PICAM_VOLUMES_ROOT:-/Volumes}"
DISKUTIL="${PICAM_DISKUTIL:-diskutil}"
OPEN_CMD="${PICAM_OPEN:-open}"
BOOT_VOL=""
PICAM_DIR=""

# ---- Helpers ----------------------------------------------------------------

_println() { printf '%s\n' "$*"; }
_ask()     { printf '%s' "$1"; read -r "$2"; }
_secret()  {
  printf '%s' "$1"
  # SC2229: read -r -s name reads into $name; suppress shellcheck false positive.
  # shellcheck disable=SC2229
  read -r -s "$2"
  printf '\n'
}
_confirm() {
  # _confirm "Pytanie [T/n]: " → returns 0 for yes, 1 for no
  local ans
  printf '%s' "$1"
  read -r ans
  case "$ans" in [NnQq]*) return 1 ;; *) return 0 ;; esac
}

_read_conf_val() {
  # _read_conf_val file KEY → prints value (CRLF-tolerant)
  local file="$1" key="$2"
  grep -m1 "^${key}=" "$file" 2>/dev/null \
    | sed "s/^${key}=//;s/\r//" || true
}

_validate_time() {
  # Returns 0 if $1 is HH:MM with valid range
  printf '%s' "$1" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'
}

_hline() { printf '%s\n' "──────────────────────────────────────────"; }

# ---- Volume detection -------------------------------------------------------

_detect_volume() {
  local vol
  for vol in "$VOLUMES_ROOT"/*/; do
    [ -d "$vol" ] || continue
    if [ -d "${vol}picam" ] && [ -f "${vol}config.txt" ]; then
      printf '%s' "$vol"
      return 0
    fi
  done
  return 1
}

# ---- WiFi setup -------------------------------------------------------------

_wifi_setup() {
  _hline
  _println "  WiFi — konfiguracja"
  _hline

  # Show current SSID if a previous config was applied.
  local current_ssid=""
  local applied_file="$PICAM_DIR/wifi-update.applied"
  if [ -f "$applied_file" ]; then
    current_ssid=$(_read_conf_val "$applied_file" SSID)
    [ -n "$current_ssid" ] && _println "  Obecna sieć: $current_ssid"
  fi

  if [ -f "$PICAM_DIR/wifi-update.txt" ]; then
    _println ""
    _println "  UWAGA: poprzednia zmiana WiFi jeszcze nie została zastosowana"
    _println "         przez Pi. Nadpisanie jej?"
    _confirm "  Nadpisać? [T/n]: " || return 0
  fi

  # Ask for SSID
  local ssid=""
  while [ -z "$ssid" ]; do
    if [ -n "$current_ssid" ]; then
      _ask "  Nazwa sieci WiFi [$current_ssid]: " ssid
      [ -z "$ssid" ] && ssid="$current_ssid"
    else
      _ask "  Nazwa sieci WiFi: " ssid
    fi
    [ -z "$ssid" ] && _println "  Nazwa sieci nie może być pusta."
  done

  # Ask for password (twice)
  local pass1="" pass2=""
  while true; do
    _secret "  Hasło WiFi (min. 8 znaków, puste = sieć otwarta): " pass1
    if [ -n "$pass1" ] && [ "${#pass1}" -lt 8 ]; then
      _println "  Hasło za krótkie (min. 8 znaków). Spróbuj ponownie."
      continue
    fi
    if [ -n "$pass1" ]; then
      _secret "  Powtórz hasło: " pass2
      if [ "$pass1" != "$pass2" ]; then
        _println "  Hasła nie zgadzają się. Spróbuj ponownie."
        continue
      fi
    fi
    break
  done

  # Write wifi-update.txt
  local out_file="$PICAM_DIR/wifi-update.txt"
  printf 'SSID=%s\nPASS=%s\nPRIORITY=10\n' "$ssid" "$pass1" > "$out_file"

  # Read back and confirm
  local written_ssid written_pass
  written_ssid=$(_read_conf_val "$out_file" SSID)
  written_pass=$(_read_conf_val "$out_file" PASS)
  local pass_display="(sieć otwarta)"
  [ -n "$written_pass" ] && pass_display="****"

  _println ""
  _println "  Zapisano:"
  _println "    SSID : $written_ssid"
  _println "    PASS : $pass_display"
  _println ""
  _println "  Pi zastosuje nowe WiFi przy następnym uruchomieniu."
  _println "  Możesz teraz wysunąć kartę."
  _println ""

  if _confirm "  Wysunąć kartę SD teraz? [T/n]: "; then
    _println "  Wysuwam $BOOT_VOL ..."
    if "$DISKUTIL" eject "$BOOT_VOL" 2>/dev/null; then
      _println "  Gotowe. Możesz wyjąć kartę."
    else
      _println "  Nie udało się wysunąć automatycznie — wysuń ręcznie."
    fi
  fi
}

# ---- Schedule editing -------------------------------------------------------

_schedule_edit() {
  _hline
  _println "  Harmonogram — zmiana"
  _hline

  local conf_file="$PICAM_DIR/capture.conf"
  local mode interval_min window_start window_end times

  # Read current values (CRLF-tolerant)
  mode=$(_read_conf_val "$conf_file" MODE 2>/dev/null || echo "interval")
  interval_min=$(_read_conf_val "$conf_file" INTERVAL_MIN 2>/dev/null || echo "30")
  window_start=$(_read_conf_val "$conf_file" WINDOW_START 2>/dev/null || echo "07:00")
  window_end=$(_read_conf_val "$conf_file" WINDOW_END 2>/dev/null || echo "18:00")
  times=$(_read_conf_val "$conf_file" TIMES 2>/dev/null || echo "08:00,12:00,16:00")

  _println ""
  _println "  Obecny harmonogram:"
  if [ "$mode" = "times" ]; then
    _println "    Tryb    : stałe godziny ($times)"
  else
    _println "    Tryb    : co $interval_min minut"
    _println "    Okno    : $window_start – $window_end"
  fi
  _println ""
  _println "  Tryb:"
  _println "    [1] Co X minut (interval)"
  _println "    [2] O stałych godzinach (times)"
  _println "    [Enter] Bez zmian"
  _println ""

  local choice
  _ask "  Wybierz [1/2/Enter]: " choice

  case "$choice" in
    1)
      mode=interval
      local new_interval
      while true; do
        _ask "  Co ile minut? [$interval_min]: " new_interval
        [ -z "$new_interval" ] && new_interval="$interval_min"
        printf '%s' "$new_interval" | grep -qE '^[1-9][0-9]*$' && break
        _println "  Podaj liczbę całkowitą większą od zera."
      done
      interval_min="$new_interval"

      local new_start new_end
      while true; do
        _ask "  Początek okna (HH:MM) [$window_start]: " new_start
        [ -z "$new_start" ] && new_start="$window_start"
        _validate_time "$new_start" && break
        _println "  Nieprawidłowy format. Użyj HH:MM (np. 07:00)."
      done
      window_start="$new_start"

      while true; do
        _ask "  Koniec okna  (HH:MM) [$window_end]: " new_end
        [ -z "$new_end" ] && new_end="$window_end"
        _validate_time "$new_end" && break
        _println "  Nieprawidłowy format. Użyj HH:MM (np. 18:00)."
      done
      window_end="$new_end"
      ;;
    2)
      mode="times"
      local new_times
      _println "  Podaj godziny oddzielone przecinkami (np. 08:00,12:00,16:00)"
      while true; do
        _ask "  Godziny [$times]: " new_times
        [ -z "$new_times" ] && new_times="$times"
        # Validate: each comma-separated entry must be HH:MM
        local ok=1 t
        local IFS_ORIG="$IFS"
        IFS=','
        for t in $new_times; do
          t="${t# }"; t="${t% }"
          _validate_time "$t" || { ok=0; break; }
        done
        IFS="$IFS_ORIG"
        [ "$ok" -eq 1 ] && break
        _println "  Nieprawidłowy format. Przykład: 08:00,12:00,16:00"
      done
      times="$new_times"
      ;;
    "")
      _println "  Bez zmian."
      return 0
      ;;
    *)
      _println "  Nieznana opcja. Bez zmian."
      return 0
      ;;
  esac

  # Write updated capture.conf
  printf 'MODE=%s\nINTERVAL_MIN=%s\nWINDOW_START=%s\nWINDOW_END=%s\nTIMES=%s\n' \
    "$mode" "$interval_min" "$window_start" "$window_end" "$times" \
    > "$conf_file"

  _println ""
  _println "  Zapisano nowy harmonogram:"
  if [ "$mode" = "times" ]; then
    _println "    Tryb : stałe godziny ($times)"
  else
    _println "    Tryb : co $interval_min minut, okno $window_start–$window_end"
  fi
}

# ---- Status -----------------------------------------------------------------

_show_status() {
  _hline
  _println "  Ostatni status (status.log)"
  _hline
  local log_file="$PICAM_DIR/status.log"
  if [ -f "$log_file" ]; then
    tail -20 "$log_file"
  else
    _println "  Brak pliku status.log — Pi jeszcze nie uruchomiło skryptów."
  fi
}

# ---- Last photo -------------------------------------------------------------

_show_photo() {
  local photo="$PICAM_DIR/last_photo.jpg"
  if [ -f "$photo" ]; then
    "$OPEN_CMD" "$photo"
    _println "  Otwarto ostatnie zdjęcie w podglądzie."
  else
    _println "  Brak zdjęcia — Pi jeszcze nie wykonało żadnego zdjęcia."
  fi
}

# ---- Main -------------------------------------------------------------------

main() {
  _println ""
  _println "  PiCam — Konfiguracja"
  _println ""

  BOOT_VOL=$(_detect_volume) || {
    _println "  BŁĄD: Nie znaleziono karty SD z PiCam."
    _println ""
    _println "  Upewnij się, że:"
    _println "    • Karta SD jest włożona do czytnika"
    _println "    • Partycja rozruchowa jest zamontowana (widoczna w Finderze)"
    _println "    • Na karcie istnieje folder /picam/ (setup jeszcze nie był uruchomiony?)"
    exit 1
  }
  PICAM_DIR="${BOOT_VOL}picam"

  _println "  Karta SD: $BOOT_VOL"

  while true; do
    _println ""
    _hline
    _println "  [1] Skonfiguruj / zmień WiFi"
    _println "  [2] Zmień harmonogram zdjęć"
    _println "  [3] Pokaż ostatni status"
    _println "  [4] Pokaż ostatnie zdjęcie"
    _println "  [5] Wyjdź"
    _hline
    _ask "  Wybierz opcję: " choice
    _println ""
    case "$choice" in
      1) _wifi_setup ;;
      2) _schedule_edit ;;
      3) _show_status ;;
      4) _show_photo ;;
      5|q|Q|"") _println "  Do widzenia."; exit 0 ;;
      *) _println "  Nieznana opcja '$choice'." ;;
    esac
  done
}

main "$@"
