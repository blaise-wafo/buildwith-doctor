#!/usr/bin/env bash
# =============================================================================
#   ┏━┓ BUILDWITH DOCTOR — le stéthoscope numérique pour Linux
#   Auscultation complète · Diagnostic · Ordonnance · Traitement · Contre-visite
#
#   by BuildWith
#
#   Usage : sudo ./buildwith-doctor.sh [options]
#
#   Actions
#     (aucune)         Menu interactif
#     --scan           Consultation seule : diagnostic complet, AUCUNE modification
#     --heal           Consultation + traitement (confirmation pour chaque soin)
#     --auto           Consultation + traitement sans question (= --heal --yes)
#
#   Réglages
#     --deep           Auscultation approfondie (intégrité des paquets, journal…)
#     --quick          Auscultation rapide (saute les contrôles lents)
#     --dry-run        Simule les traitements sans rien modifier
#     --yes, -y        Répond « oui » aux soins critiques/importants
#     --full           Avec --yes : inclut aussi les soins optionnels
#     --only a,b       N'ausculte que ces modules   (voir --list)
#     --skip a,b       Ignore ces modules
#     --list           Liste les modules
#     --no-reboot      Ne propose jamais de redémarrage
#     --no-anim        Pas d'animation          --no-color   Pas de couleurs
#     -v, --version    Version                  -h, --help   Cette aide
#
#   Codes de sortie : 0 = en bonne santé · 1 = avertissements · 2 = critique
#   Journaux        : /var/log/buildwith-doctor/   (rapport .txt et .json)
#   Sauvegardes     : /var/backups/buildwith-doctor/<date>/  (avant toute édition)
# =============================================================================

# Bash >= 4 requis (tableaux associatifs)
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
  echo "Bash 4 ou supérieur est requis." >&2; exit 1
fi

set -o pipefail
umask 022

readonly VERSION="2.0.0"
readonly APP="BuildWith Doctor"
readonly SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
readonly TS="$(date +%Y%m%d-%H%M%S)"

# ----- langue / locale : sorties des commandes en anglais, UTF-8 si possible -----
if locale -a 2>/dev/null | grep -qi '^c\.utf-\?8$'; then export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qi '^en_us\.utf-\?8$'; then export LC_ALL=en_US.UTF-8
else export LC_ALL=C; fi
export LANGUAGE=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# ----- options -----
ACTION=""            # scan | heal | "" (menu)
DRY_RUN=0; ASSUME_YES=0; FULL=0; DEEP=0; QUICK=0; NO_REBOOT=0
ANIM=1; USE_COLOR=1; ONLY=""; SKIP=""; LIST=0
QUIET=0
ROOT_PCT=0

# ----- état global -----
F_SEV=(); F_MOD=(); F_TITLE=(); F_DETAIL=(); F_FIX=(); F_FIXD=()
PASS_N=0; SCORE=100; NC=0; NW=0; NI=0
SCORE_BEFORE=""
declare -A DONE_FIX=()
FIX_RESULTS=()
REBOOT_REASONS=()
KMSG=""
PM=""

LOG_DIR="/var/log/buildwith-doctor"
BACKUP_ROOT="/var/backups/buildwith-doctor"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"
ACTION_LOG=""
REPORT_TXT=""; REPORT_JSON=""

# =============================================================================
#  ARGUMENTS
# =============================================================================
usage() { sed -n '2,33p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0; }

ORIG_ARGS=("$@")
while (( $# )); do
  case "$1" in
    --scan|--status|--check) ACTION="scan" ;;
    --heal|--fix|--repair)   ACTION="heal" ;;
    --auto)                  ACTION="heal"; ASSUME_YES=1 ;;
    --dry-run)               DRY_RUN=1 ;;
    --yes|-y)                ASSUME_YES=1 ;;
    --full)                  FULL=1 ;;
    --deep)                  DEEP=1 ;;
    --quick)                 QUICK=1 ;;
    --only)                  shift; ONLY="${1:-}" ;;
    --only=*)                ONLY="${1#*=}" ;;
    --skip)                  shift; SKIP="${1:-}" ;;
    --skip=*)                SKIP="${1#*=}" ;;
    --list)                  LIST=1 ;;
    --no-reboot)             NO_REBOOT=1 ;;
    --no-anim)               ANIM=0 ;;
    --no-color)              USE_COLOR=0 ;;
    -v|--version)            echo "$APP $VERSION — by BuildWith"; exit 0 ;;
    -h|--help)               usage ;;
    *) echo "Option inconnue : $1 (voir --help)" >&2; exit 2 ;;
  esac
  shift
done

IS_TTY=0; [[ -t 1 && -t 0 ]] && IS_TTY=1
[[ -t 1 ]] || { USE_COLOR=0; ANIM=0; }
[[ -n "${NO_COLOR:-}" || "${TERM:-dumb}" == dumb ]] && { USE_COLOR=0; ANIM=0; }

if (( USE_COLOR )); then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; M=$'\e[35m'; C=$'\e[36m'
  W=$'\e[1m'; D=$'\e[90m'; N=$'\e[0m'; HR=$'\e[91m'; HG=$'\e[92m'; HC=$'\e[96m'
else
  R=""; G=""; Y=""; B=""; M=""; C=""; W=""; D=""; N=""; HR=""; HG=""; HC=""
fi

COLS=$(tput cols 2>/dev/null || echo 80)
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
(( COLS < 60 )) && COLS=60
(( COLS > 100 )) && COLS=100

# =============================================================================
#  UTILITAIRES
# =============================================================================
have()   { command -v "$1" >/dev/null 2>&1; }
num()    { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }
meminfo(){ awk -v k="$1:" '$1==k {print $2}' /proc/meminfo 2>/dev/null; }
pct()    { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if (b<=0) print 0; else printf "%d", a*100/b }'; }
gio()    { awk -v k="${1:-0}" 'BEGIN{ printf "%.2f Gio", k/1048576 }'; }
fgt()    { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit !(a>b) }'; }
tmo()    { if have timeout; then timeout "$@"; else shift; "$@"; fi; }
is_root(){ (( EUID == 0 )); }
hr()     { local i s=""; for (( i=0; i<${1:-$COLS}; i++ )); do s+="─"; done; printf '%s\n' "$s"; }
wrap()   { fold -s -w "$(( COLS - ${2:-6} ))" <<<"$1" | sed "s/^/$(printf '%*s' "${2:-6}" '')/"; }
trim()   { local s="${1:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
cut_to() { local s="$1" n="${2:-100}"; (( ${#s} > n )) && s="${s:0:n-1}…"; printf '%s' "$s"; }

log() {
  [[ -n "$ACTION_LOG" ]] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$ACTION_LOG" 2>/dev/null || true
}

# --- affichage ---
pass()  { PASS_N=$((PASS_N+1)); (( QUIET )) || printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
note()  { (( QUIET )) || printf '  %s•%s %s%s%s\n' "$D" "$N" "$D" "$*" "$N"; }
info()  { printf '%s[i]%s %s\n' "$B" "$N" "$*"; }
okk()   { printf '%s[✔]%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
err()   { printf '%s[✘]%s %s\n' "$R" "$N" "$*" >&2; }
act()   { printf '    %s↳%s %s\n' "$C" "$N" "$*"; }
title() { printf '\n%s━━ %s ━━%s\n' "$W$C" "$*" "$N"; }

# add_finding SEV MODULE TITRE DETAIL [FIX_FUNC] [FIX_DESC]
add_finding() {
  local sev="$1" mod="$2" ttl="$3" det="${4:-}" fix="${5:-}" fixd="${6:-}" ic col
  F_SEV+=("$sev"); F_MOD+=("$mod"); F_TITLE+=("$ttl"); F_DETAIL+=("$det"); F_FIX+=("$fix"); F_FIXD+=("$fixd")
  case "$sev" in
    crit) ic="✘"; col="$R" ;;
    warn) ic="▲"; col="$Y" ;;
    *)    ic="ℹ"; col="$B" ;;
  esac
  (( QUIET )) && return 0
  printf '  %s%s%s %s%s%s' "$col" "$ic" "$N" "$W" "$ttl" "$N"
  [[ -n "$det" ]] && printf ' %s— %s%s' "$D" "$(cut_to "$det" $(( COLS - ${#ttl} - 10 )))" "$N"
  printf '\n'
}

# --- exécution / simulation ---
run() {
  if (( DRY_RUN )); then printf '    %s[simulation]%s %s\n' "$Y" "$N" "$*"; log "SIMULATION: $*"; return 0; fi
  log "EXEC: $*"
  "$@"
}
backup_file() {
  local f="$1"; [[ -e "$f" ]] || return 0
  (( DRY_RUN )) && return 0
  mkdir -p "${BACKUP_DIR}$(dirname "$f")" 2>/dev/null && cp -a "$f" "${BACKUP_DIR}${f}" 2>/dev/null && log "SAUVEGARDE: $f -> ${BACKUP_DIR}${f}"
}
restore_file() {
  local f="$1"; [[ -e "${BACKUP_DIR}${f}" ]] && cp -a "${BACKUP_DIR}${f}" "$f" 2>/dev/null
}
write_file() {   # write_file CHEMIN  (contenu sur stdin)
  local f="$1"
  if (( DRY_RUN )); then printf '    %s[simulation]%s écriture de %s\n' "$Y" "$N" "$f"; cat >/dev/null; return 0; fi
  backup_file "$f"; mkdir -p "$(dirname "$f")"; cat >"$f" && log "ÉCRIT: $f"
}
confirm() {   # confirm "question"  (défaut : non)
  local rep
  (( ASSUME_YES )) && return 0
  [[ -r /dev/tty ]] || return 1
  read -r -p "$1 [o/N] " rep </dev/tty || return 1
  [[ "$rep" =~ ^([oO]|[oO][uU][iI]|[yY]|[yY][eE][sS])$ ]]
}
pause_key() { (( IS_TTY )) && { read -r -s -n1 -p "$1" </dev/tty || true; printf '\n'; }; }

cleanup() { (( IS_TTY )) && tput cnorm 2>/dev/null; printf '%s' "$N"; }
on_int()  { printf '\n%s[!]%s Interruption demandée, arrêt en cours.\n' "$Y" "$N"; cleanup; exit 130; }
trap cleanup EXIT
trap on_int INT TERM

# =============================================================================
#  SPLASH : stéthoscope + électrocardiogramme + signature
# =============================================================================
ART=(
"  ▄███▄                           ▄███▄"
"  █████                           █████"
"   ▀█▀                             ▀█▀"
"    ║                               ║"
"    ║                               ║"
"    ╚═══╗                       ╔═══╝"
"        ╚═══╗               ╔═══╝"
"            ╚═══╗       ╔═══╝"
"                ╚═══╦═══╝"
"                    ║"
"                    ║"
"           ▄▄▄▄▄▄▄▄▄█▄▄▄▄▄▄▄▄▄"
"          ▄█▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀█▄"
"         █▀ ╭───────────────╮ ▀█"
"         █▀ │  ♥ ─╱╲─╱╲╱╲─  │ ▀█"
"         █▀ ╰───────────────╯ ▀█"
"          ▀█▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄█▀"
"            ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"
)

center_pad() { local w="$1"; local p=$(( (COLS - w) / 2 )); (( p < 0 )) && p=0; printf '%*s' "$p" ''; }

splash() {
  local i line pad col
  (( ANIM )) && { clear 2>/dev/null; tput civis 2>/dev/null; }
  pad="$(center_pad 41)"
  printf '\n'
  for i in "${!ART[@]}"; do
    line="${ART[i]}"
    if   (( i <= 2 ));  then col="$W"
    elif (( i <= 10 )); then col="$D"
    else                     col="$HC"; fi
    line="${line//♥/${HR}♥${col}}"
    printf '%s%s%s%s\n' "$pad" "$col" "$line" "$N"
    (( ANIM )) && sleep 0.03
  done
  ecg_line
  printf '\n'
  banner
}

ecg_line() {
  local wave=(▁ ▁ ▁ ▁ ▁ ▁ ▂ ▅ █ ▇ ▃ ▁ ▄ ▁ ▁ ▁ ▁ ▁ ▁ ▁) n=20 width=$(( COLS - 8 )) f x s
  local frames=1; (( ANIM )) && frames=44
  for (( f=0; f<frames; f++ )); do
    s=""
    for (( x=0; x<width; x++ )); do s+="${wave[(x + f) % n]}"; done
    printf '\r    %s%s%s' "$HG" "$s" "$N"
    (( ANIM )) && sleep 0.035
  done
  printf '\n'
}

banner() {
  local pad bw=48 hl=""; pad="$(center_pad $((bw + 2)))"
  local k; for (( k=0; k<bw; k++ )); do hl+="═"; done
  box_row() {   # box_row "texte brut" "texte coloré"
    local plain="$1" colored="$2" left right
    left=$(( (bw - ${#plain}) / 2 )); right=$(( bw - ${#plain} - left ))
    printf '%s%s║%s%*s%s%*s%s║%s\n' "$pad" "$HC" "$N" "$left" "" "$colored" "$right" "" "$HC" "$N"
  }
  printf '%s%s╔%s╗%s\n' "$pad" "$HC" "$hl" "$N"
  box_row "B U I L D W I T H   ·   D O C T O R" "${W}B U I L D W I T H   ·   D O C T O R${N}"
  box_row "Le stéthoscope numérique de votre Linux" "Le stéthoscope numérique de votre Linux"
  box_row "v${VERSION}  ·  ausculte · diagnostique · soigne" "${D}v${VERSION}  ·  ausculte · diagnostique · soigne${N}"
  printf '%s%s╠%s╣%s\n' "$pad" "$HC" "$hl" "$N"
  box_row "— by BuildWith —" "${HG}${W}— by BuildWith —${N}"
  printf '%s%s╚%s╝%s\n' "$pad" "$HC" "$hl" "$N"
}

signature() { printf '\n%s%s— by BuildWith —%s\n' "$(center_pad 16)" "$HG$W" "$N"; }

module_header() {   # i total label
  local i=$1 n=$2 label=$3 w=16 f bar="" k
  f=$(( i * w / n ))
  for (( k=0; k<w; k++ )); do (( k < f )) && bar+="█" || bar+="░"; done
  printf '\n%s♥%s %s%s%s %s%s%s %s(%d/%d)%s\n' "$HR" "$N" "$W" "Auscultation : $label" "$N" "$C" "$bar" "$N" "$D" "$i" "$n" "$N"
}

# =============================================================================
#  PRÉPARATION : privilèges, verrou, détection
# =============================================================================
ensure_root() {
  is_root && return 0
  if have sudo; then
    info "Droits administrateur requis pour une auscultation complète — relance avec sudo…"
    local args=(); (( DRY_RUN )) && args+=(--dry-run)
    exec sudo -E bash "$SELF" "$@"
  fi
  warn "Pas de sudo : diagnostic partiel (certains contrôles exigent root)."
  return 1
}

setup_dirs() {
  if is_root; then
    mkdir -p "$LOG_DIR" 2>/dev/null && chmod 750 "$LOG_DIR" 2>/dev/null
    if [[ -w /run ]] && have flock; then
      exec 9>/run/buildwith-doctor.lock
      flock -n 9 || { err "Une autre instance de $APP est déjà en cours."; exit 1; }
    fi
  else
    LOG_DIR="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/buildwith-doctor"; mkdir -p "$LOG_DIR" 2>/dev/null
  fi
  [[ -w "$LOG_DIR" ]] || LOG_DIR="$(mktemp -d /tmp/buildwith-doctor.XXXXXX)"
  ACTION_LOG="$LOG_DIR/actions-$TS.log"
  REPORT_TXT="$LOG_DIR/rapport-$TS.txt"
  REPORT_JSON="$LOG_DIR/rapport-$TS.json"
  : >"$ACTION_LOG" 2>/dev/null || ACTION_LOG=""
  log "=== $APP v$VERSION démarré (utilisateur: ${SUDO_USER:-$(id -un)}, uid: $EUID) ==="
}

detect_env() {
  REAL_USER="${SUDO_USER:-$(id -un 2>/dev/null || echo root)}"
  REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"; REAL_HOME="${REAL_HOME:-/root}"
  if   have apt-get; then PM="apt"
  elif have dnf;     then PM="dnf"
  elif have pacman;  then PM="pacman"
  elif have zypper;  then PM="zypper"
  else PM=""; fi
  HAS_SYSTEMD=0; [[ -d /run/systemd/system ]] && have systemctl && HAS_SYSTEMD=1
  VIRT="$(systemd-detect-virt 2>/dev/null)"; [[ -z "$VIRT" || "$VIRT" == none ]] && VIRT="aucune"
  IS_CONTAINER=0; [[ "$(systemd-detect-virt -c 2>/dev/null)" =~ ^(docker|lxc|lxc-libvirt|podman|wsl|openvz|systemd-nspawn)$ ]] && IS_CONTAINER=1
  APT="apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef -y -qq"
}

load_kmsg() {
  KMSG="$( { journalctl -k -b --no-pager -q 2>/dev/null || dmesg 2>/dev/null; } | tail -n 30000 )"
  [[ -n "$KMSG" ]] || KMSG="$(dmesg 2>/dev/null | tail -n 30000)"
}

apt_busy() {
  if have fuser; then fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; return $?; fi
  pgrep -x 'apt|apt-get|dpkg|aptitude' >/dev/null 2>&1
}
svc_active() { (( HAS_SYSTEMD )) && systemctl is-active --quiet "$1" 2>/dev/null; }
unit_exists() { (( HAS_SYSTEMD )) && systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q .; }

# =============================================================================
#  MODULES D'AUSCULTATION
# =============================================================================

# ---------- 1. Identité & noyau ----------
mod_system() {
  local os kern up_d taint
  os="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"; [[ -n "$(trim "$os")" ]] || os="Linux"
  kern="$(uname -r)"
  note "Système : $os — noyau $kern ($(uname -m))"
  note "Hôte : $(hostname) — virtualisation : $VIRT$( (( IS_CONTAINER )) && echo ' (conteneur)')"
  up_d=$(( $(num "$(cut -d. -f1 /proc/uptime 2>/dev/null)") / 86400 ))
  if (( up_d > 60 )); then
    add_finding info system "Uptime très long : ${up_d} jours" "Les correctifs noyau récents ne sont probablement pas actifs"
  else pass "Uptime : ${up_d} j"; fi

  taint=$(num "$(cat /proc/sys/kernel/tainted 2>/dev/null)")
  if (( taint & (16 | 32 | 128) )); then
    add_finding warn system "Noyau marqué « tainted » (valeur $taint)" "Erreur machine (MCE), page défectueuse ou OOPS détecté : voir journaux noyau"
  elif (( taint != 0 )); then
    note "Noyau « tainted » ($taint) : module propriétaire / hors arbre — normal avec pilotes NVIDIA, VirtualBox, etc."
  else pass "Noyau non marqué"; fi

  if [[ -e /sys/firmware/efi ]]; then note "Démarrage : UEFI"; else note "Démarrage : BIOS/Legacy"; fi
  [[ -r /etc/machine-id && -s /etc/machine-id ]] && pass "machine-id présent" \
    || add_finding warn system "machine-id absent ou vide" "" fix_machine_id "Régénérer /etc/machine-id (systemd-machine-id-setup)"
}

# ---------- 2. Processeur & charge ----------
cpu_sample() { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5, $6}' /proc/stat 2>/dev/null; }
mod_cpu() {
  local cores l1 l5 l15 ratio t1 i1 w1 t2 i2 w2 dt di dw usage iow
  cores=$(nproc 2>/dev/null || echo 1)
  read -r l1 l5 l15 _ </proc/loadavg
  note "Cœurs : $cores — charge 1/5/15 min : $l1 $l5 $l15"
  ratio=$(awk -v l="$l5" -v c="$cores" 'BEGIN{printf "%.2f", l/c}')
  if   fgt "$ratio" 3;   then add_finding crit cpu "Charge CPU extrême" "load5=$l5 pour $cores cœur(s) (x$ratio)"
  elif fgt "$ratio" 1.5; then add_finding warn cpu "Charge CPU élevée" "load5=$l5 pour $cores cœur(s) (x$ratio)"
  else pass "Charge CPU normale (x$ratio par cœur)"; fi

  read -r t1 i1 w1 <<<"$(cpu_sample)"; sleep 1; read -r t2 i2 w2 <<<"$(cpu_sample)"
  dt=$(( t2 - t1 )); di=$(( i2 - i1 )); dw=$(( w2 - w1 ))
  if (( dt > 0 )); then
    usage=$(( 100 - (di * 100 / dt) )); iow=$(( dw * 100 / dt ))
    note "Utilisation instantanée : ${usage}% — attente disque (iowait) : ${iow}%"
    (( iow > 30 )) && add_finding warn cpu "Attente d'E/S disque élevée (${iow}%)" "Le disque est un goulot d'étranglement (disque lent, défaillant ou saturé)"
  fi
  local top; top="$(ps -eo pcpu=,comm= --sort=-pcpu 2>/dev/null | awk '$2!="ps"' | head -n 3 | awk '{printf "%s(%s%%) ", $2, $1}')"
  [[ -n "$top" ]] && note "Top CPU (moyenne depuis lancement) : $top"
}

# ---------- 3. Mémoire ----------
mod_memory() {
  local total avail swap_t swap_f slab ap su oom
  total=$(num "$(meminfo MemTotal)"); avail=$(num "$(meminfo MemAvailable)")
  swap_t=$(num "$(meminfo SwapTotal)"); swap_f=$(num "$(meminfo SwapFree)"); slab=$(num "$(meminfo SUnreclaim)")
  (( total > 0 )) || { note "Mémoire illisible"; return; }
  ap=$(pct "$avail" "$total")
  note "RAM $(gio "$total") — disponible $(gio "$avail") (${ap}%) — swap $(gio "$swap_t")"
  if   (( ap < 8 ));  then add_finding crit memory "RAM presque saturée" "Seulement ${ap}% disponible" fix_memory_clean "Libérer les caches, compacter la mémoire, purger le swap si sûr"
  elif (( ap < 15 )); then add_finding warn memory "RAM faible" "${ap}% disponible" fix_memory_clean "Libérer les caches, compacter la mémoire, purger le swap si sûr"
  else pass "Mémoire disponible : ${ap}%"; fi

  if (( swap_t > 0 )); then
    su=$(pct $(( swap_t - swap_f )) "$swap_t")
    if   (( su > 85 )); then add_finding crit memory "Swap saturé (${su}%)" "Le système swappe massivement : lenteurs / gels probables" fix_memory_harden "Installer zram, ajuster sysctl, activer earlyoom"
    elif (( su > 60 )); then add_finding warn memory "Swap très utilisé (${su}%)" "" fix_memory_harden "Installer zram, ajuster sysctl, activer earlyoom"
    else pass "Swap utilisé : ${su}%"; fi
  elif (( total < 8388608 )); then
    add_finding warn memory "Aucun swap sur une machine à moins de 8 Gio" "Risque de blocage dès que la RAM est pleine" fix_memory_harden "Installer zram + swap de secours, ajuster sysctl, activer earlyoom"
  else note "Pas de swap (RAM confortable)"; fi

  if (( $(pct "$slab" "$total") > 20 )); then
    add_finding crit memory "Le noyau retient plus de 20% de la RAM (slab)" "Fuite noyau/pilote probable → redémarrage conseillé"
    REBOOT_REASONS+=("Fuite mémoire noyau probable (slab > 20% de la RAM).")
  fi

  oom=$(grep -ciE 'out of memory|oom-kill|killed process' <<<"$KMSG")
  if (( oom > 0 )); then
    add_finding warn memory "Le noyau a tué des processus faute de mémoire ($oom événement(s))" "Depuis ce démarrage" fix_memory_harden "Installer zram, ajuster sysctl, activer earlyoom"
  else pass "Aucun OOM-kill depuis le démarrage"; fi

  if (( total < 16777216 )) && ! svc_active earlyoom && ! svc_active systemd-oomd && (( ! IS_CONTAINER )); then
    add_finding info memory "Aucune protection anti-saturation (earlyoom / systemd-oomd)" "" fix_memory_harden "Installer zram, ajuster sysctl, activer earlyoom"
  fi
}

# ---------- 4. Stockage ----------
mod_disk() {
  local fs type size used avail pc mp p bad=0 line ro f susp="" hogs=""
  ro="$(awk '$3 ~ /^(ext[234]|xfs|btrfs|f2fs|vfat|ntfs3?|exfat)$/ && $4 ~ /(^|,)ro(,|$)/ {print $2}' /proc/mounts 2>/dev/null | grep -v '^/snap')"
  while read -r fs type size used avail pc mp; do
    [[ "$pc" =~ ^[0-9]+% ]] || continue
    p=${pc%\%}
    if grep -qxF "$mp" <<<"$ro"; then (( QUIET )) || note "$mp : ${p}% (monté en lecture seule, ignoré)"; continue; fi
    [[ "$mp" == / ]] && ROOT_PCT=$p
    hogs=""
    if (( p >= 85 && QUICK == 0 )) && [[ "$mp" == / ]]; then
      hogs=" — Gros consommateurs : $(tmo 40 du -xsk /var /home /opt /usr /root /snap /tmp 2>/dev/null | sort -rn | head -n 4 | awk '{printf "%s %.1fGio, ", $2, $1/1048576}' | sed 's/, $//')"
    fi
    if   (( p >= 95 )); then add_finding crit disk "Partition $mp pleine à ${p}%" "$fs ($type), $(gio "$avail") libres${hogs}" fix_disk_clean "Nettoyer APT, journaux, caches, snaps, flatpak, anciens fichiers temporaires"; bad=1
    elif (( p >= 85 )); then add_finding warn disk "Partition $mp à ${p}%" "$fs ($type), $(gio "$avail") libres${hogs}" fix_disk_clean "Nettoyer APT, journaux, caches, snaps, flatpak, anciens fichiers temporaires"; bad=1
    else (( QUIET )) || note "$mp : ${p}% utilisé ($fs)"; fi
  done < <(df -PTk -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x iso9660 -x ramfs -x fuse.snapfuse 2>/dev/null | tail -n +2)
  (( bad )) || pass "Espace disque suffisant sur toutes les partitions"

  bad=0
  while read -r fs size used free pc mp; do
    [[ "$pc" =~ ^[0-9]+% ]] || continue
    p=${pc%\%}
    if (( p >= 90 )); then add_finding warn disk "Inodes presque épuisés sur $mp (${p}%)" "Beaucoup trop de petits fichiers (caches, sessions, mails…)" fix_disk_clean "Nettoyer APT, journaux, caches, snaps, flatpak, anciens fichiers temporaires"; bad=1; fi
  done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)
  (( bad )) || pass "Inodes : OK"

  for mp in $ro; do
    f="$(awk -v m="$mp" '$1 !~ /^#/ && $2==m {print $4}' /etc/fstab 2>/dev/null | head -n 1)"
    if [[ -n "$f" && ",$f," != *,ro,* ]]; then susp+="$mp "
    elif [[ -z "$f" ]] && grep -qiE 'Remounting filesystem read-only|remount-ro' <<<"$KMSG"; then susp+="$mp "
    else note "$mp : monté en lecture seule volontairement"; fi
  done
  if [[ -n "$(trim "$susp")" ]]; then
    add_finding crit disk "Système(s) de fichiers passé(s) en LECTURE SEULE : $(trim "$susp")" "Signe d'erreurs disque : sauvegardez vos données puis lancez fsck depuis un mode de secours"
  else pass "Aucun système de fichiers anormalement en lecture seule"; fi

  if have findmnt; then
    f="$(findmnt --verify 2>&1 | grep -E '\[E\]' | head -n 3 | tr '\n' ' ')"
    if [[ -n "$(trim "$f")" ]]; then add_finding warn disk "Erreurs dans /etc/fstab" "$(trim "$f")" "" ""
    else pass "/etc/fstab cohérent"; fi
  fi

  f="$(grep -E 'EXT4-fs error|I/O error|Buffer I/O|XFS.*(error|corrupt)|BTRFS.*error|blk_update_request|ata[0-9.]+:.*(failed|error|exception)|nvme.*(timeout|reset controller)' <<<"$KMSG" | head -n 3 | cut -c1-110 | tr '\n' ' ')"
  if [[ -n "$(trim "$f")" ]]; then
    add_finding crit disk "Erreurs d'E/S ou de système de fichiers dans le journal noyau" "$(trim "$f")"
  else pass "Journal noyau : aucune erreur de stockage"; fi

  if [[ -r /proc/mdstat ]] && grep -qE '\[[U_]*_[U_]*\]' /proc/mdstat; then
    add_finding crit disk "Grappe RAID dégradée" "$(grep -E '\[[U_]*_[U_]*\]' /proc/mdstat | head -n 1)"
  fi

  if have smartctl && is_root; then
    local d out checked=0
    for d in $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
      out="$(tmo 20 smartctl -H "$d" 2>&1)"
      if grep -qiE 'overall-health.*result: *FAILED|SMART Health Status: *(FAIL|BAD)' <<<"$out"; then
        local mdl rea pen attrs
        mdl="$(tmo 20 smartctl -i "$d" 2>/dev/null | awk -F: '/Device Model|Model Number|Product/{gsub(/^ +/,"",$2); print $2; exit}')"
        attrs="$(tmo 20 smartctl -A "$d" 2>/dev/null)"
        rea="$(awk '$1==5{print $NF}' <<<"$attrs")"; pen="$(awk '$1==197{print $NF}' <<<"$attrs")"
        add_finding crit disk "SMART : le disque $d (${mdl:-modèle inconnu}) annonce une panne" "Secteurs réalloués : ${rea:-?}, en attente : ${pen:-?}. Sauvegardez vos données puis vérifiez : sudo smartctl -a $d"
        checked=1
      elif grep -qE 'PASSED|result: OK|Health Status: OK' <<<"$out"; then pass "SMART : $d en bonne santé"; checked=1; fi
    done
    (( checked )) || note "SMART non disponible (machine virtuelle ou disque non supporté)"
  fi

  if have lsblk && ! systemctl is-enabled fstrim.timer >/dev/null 2>&1 && lsblk -dno ROTA 2>/dev/null | grep -q '^0$' && (( ! IS_CONTAINER )) && [[ "$VIRT" == aucune ]]; then
    add_finding info disk "SSD sans TRIM périodique (fstrim.timer inactif)" "" fix_trim "Activer fstrim.timer et lancer un TRIM"
  fi
}

# ---------- 5. Services & démarrage ----------
mod_services() {
  (( HAS_SYSTEMD )) || { note "systemd absent : module ignoré"; return; }
  local state failed n loops t m s total blame
  state="$(systemctl is-system-running 2>/dev/null)"
  case "$state" in
    running) pass "systemd : état « running »" ;;
    degraded) note "systemd : état « degraded » (au moins une unité en échec)" ;;
    *) note "systemd : état « ${state:-inconnu} »" ;;
  esac
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  n=$(wc -w <<<"$failed")
  if (( n > 0 )); then
    add_finding warn services "$n unité(s) systemd en échec" "$(trim "$failed")" fix_failed_services "Réinitialiser et redémarrer les unités en échec"
  else pass "Aucune unité systemd en échec"; fi

  loops="$(systemctl list-units --state=activating,auto-restart --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  [[ -n "$(trim "$loops")" ]] && add_finding warn services "Services qui redémarrent en boucle" "$(trim "$loops")"

  if have systemd-analyze; then
    t="$(systemd-analyze 2>/dev/null | head -n 1 | sed -n 's/.*= *//p')"
    total=0
    [[ "$t" =~ ([0-9]+)min ]] && total=$(( BASH_REMATCH[1] * 60 ))
    [[ "$t" =~ ([0-9.]+)s ]] && total=$(( total + ${BASH_REMATCH[1]%.*} ))
    if (( total > 0 )); then
      note "Temps de démarrage : ${total}s"
      if (( total > 90 )); then
        blame="$(systemd-analyze blame 2>/dev/null | head -n 3 | awk '{n=$NF; $NF=""; sub(/ +$/,""); printf "%s(%s) ", n, $0}')"
        add_finding info services "Démarrage lent (${total}s)" "Plus lents : $blame"
      fi
    fi
  fi
}

# ---------- 6. Paquets & mises à jour ----------
mod_packages() {
  case "$PM" in
    apt)    pk_apt ;;
    dnf)    pk_dnf ;;
    pacman) pk_pacman ;;
    *)      note "Gestionnaire de paquets non géré : module ignoré" ;;
  esac
  [[ -f /var/run/reboot-required ]] && {
    add_finding warn packages "Redémarrage requis par des mises à jour" "$(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null | cut -c1-90)"
    REBOOT_REASONS+=("Des mises à jour (noyau/bibliothèques) attendent un redémarrage.")
  }
}
pk_apt() {
  local audit up sec orph rc old
  if apt_busy; then add_finding info packages "APT/dpkg est occupé" "Un autre gestionnaire de paquets tourne : contrôles ignorés"; return; fi
  audit="$(dpkg --audit 2>&1)"
  if [[ -n "$(trim "$audit")" ]]; then
    add_finding crit packages "Paquets cassés ou configuration interrompue" "$(echo "$audit" | head -n 2 | tr '\n' ' ' | cut -c1-110)" fix_apt_repair "dpkg --configure -a puis apt-get install -f"
  elif is_root && ! apt-get check >/dev/null 2>&1; then
    add_finding crit packages "Dépendances cassées (apt-get check)" "" fix_apt_repair "dpkg --configure -a puis apt-get install -f"
  else pass "dpkg/apt : base de paquets cohérente"; fi

  up="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst')"; up=$(num "$up")
  sec="$(apt-get -s upgrade 2>/dev/null | grep '^Inst' | grep -ci security)"; sec=$(num "$sec")
  if   (( sec > 0 )); then add_finding warn packages "$sec mise(s) à jour de SÉCURITÉ en attente" "$up mise(s) à jour au total" fix_upgrade "apt-get update puis apt-get upgrade"
  elif (( up > 40 )); then add_finding warn packages "$up mises à jour en attente" "" fix_upgrade "apt-get update puis apt-get upgrade"
  elif (( up > 0 ));  then add_finding info packages "$up mise(s) à jour en attente" "" fix_upgrade "apt-get update puis apt-get upgrade"
  else pass "Système à jour (selon l'index local)"; fi

  orph="$(apt-get -s autoremove 2>/dev/null | grep -c '^Remv')"; orph=$(num "$orph")
  (( orph > 0 )) && add_finding info packages "$orph paquet(s) orphelin(s) / ancien(s) noyau(x) à retirer" "" fix_apt_autoremove "apt-get autoremove --purge"
  rc="$(dpkg -l 2>/dev/null | awk '/^rc/{c++} END{print c+0}')"
  (( rc > 0 )) && add_finding info packages "$rc paquet(s) supprimé(s) avec configuration résiduelle" "" fix_purge_rc "Purger les configurations résiduelles"
  old="$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | grep -c '^ii')"; old=$(num "$old")
  (( old > 3 )) && add_finding info packages "$old noyaux installés" "Les anciens occupent /boot" fix_apt_autoremove "apt-get autoremove --purge"
  have snap && [[ "$(snap list --all 2>/dev/null | awk '/disabled/' | wc -l)" -gt 0 ]] && \
    add_finding info packages "Anciennes révisions snap désactivées" "" fix_snap_clean "Supprimer les révisions snap désactivées"
  return 0
}
pk_dnf() {
  local n
  if dnf -q check >/dev/null 2>&1; then pass "dnf check : OK"; else add_finding warn packages "dnf check signale des problèmes" "Lancez : dnf check"; fi
  dnf -C -q check-update >/dev/null 2>&1; [[ $? -eq 100 ]] && add_finding info packages "Mises à jour disponibles (dnf)" "" fix_upgrade "dnf upgrade -y"
  have needs-restarting && ! needs-restarting -r >/dev/null 2>&1 && REBOOT_REASONS+=("needs-restarting : un redémarrage est requis.")
}
pk_pacman() {
  local bad; bad="$(pacman -Qk 2>&1 | grep -v ' 0 missing files' | head -n 3 | tr '\n' ' ')"
  if [[ -n "$(trim "$bad")" ]]; then add_finding warn packages "Fichiers de paquets manquants" "$bad"; else pass "pacman -Qk : OK"; fi
  [[ -n "$(pacman -Qdtq 2>/dev/null)" ]] && add_finding info packages "Paquets orphelins" "" fix_upgrade "pacman -Syu"
}

# ---------- 7. Sécurité ----------
perm_issues() {   # affiche: chemin mode_actuel mode_max
  local spec f max cur
  for spec in /etc/shadow:640 /etc/gshadow:640 /etc/passwd:644 /etc/group:644 /etc/sudoers:440 /etc/crontab:644 /etc/ssh/sshd_config:644; do
    f="${spec%%:*}"; max="${spec##*:}"; [[ -f "$f" ]] || continue
    cur="$(stat -c '%a' "$f" 2>/dev/null)"; [[ "$cur" =~ ^[0-7]+$ ]] || continue
    (( (8#$cur & ~8#$max) )) && echo "$f $cur $max"
  done
  for f in /etc/ssh/ssh_host_*_key; do
    [[ -f "$f" ]] || continue
    cur="$(stat -c '%a' "$f" 2>/dev/null)"
    (( (8#$cur & ~8#600) )) && echo "$f $cur 600"
  done
}
ssh_dir_issues() {
  local u h f cur
  while IFS=: read -r u h; do
    [[ -d "$h/.ssh" ]] || continue
    cur="$(stat -c '%a' "$h/.ssh")"; (( (8#$cur & ~8#700) )) && echo "$h/.ssh $cur 700"
    for f in "$h"/.ssh/id_* "$h"/.ssh/authorized_keys "$h"/.ssh/config; do
      [[ -f "$f" && "$f" != *.pub ]] || continue
      cur="$(stat -c '%a' "$f")"; (( (8#$cur & ~8#600) )) && echo "$f $cur 600"
    done
  done < <(getent passwd 2>/dev/null | awk -F: '($3==0 || ($3>=1000 && $3<65534)) && $7 !~ /(nologin|false)$/ {print $1":"$6}')
}
public_listeners() {
  ss -H -tuln 2>/dev/null | awk '{n=split($5,a,":"); port=a[n]; addr=substr($5,1,length($5)-length(port)-1);
    if (addr !~ /^(127\.|\[::1\]$|::1$)/ && port ~ /^[0-9]+$/) print $1, port}' | sort -u
}
fw_active() {
  have ufw && ufw status 2>/dev/null | grep -q '^Status: active' && return 0
  have firewall-cmd && firewall-cmd --state >/dev/null 2>&1 && return 0
  have nft && nft list ruleset 2>/dev/null | grep -q 'hook input' && return 0
  have iptables && iptables -S 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)' && return 0
  return 1
}
sshd_opt() { have sshd && sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }

mod_security() {
  local x lst cnt
  x="$(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | tr '\n' ' ')"
  if [[ -n "$(trim "$x")" ]]; then add_finding crit security "Compte(s) avec UID 0 autre(s) que root" "$(trim "$x") — possible porte dérobée"; else pass "Un seul compte UID 0 (root)"; fi

  if is_root && [[ -r /etc/shadow ]]; then
    x="$(awk -F: '$2==""{print $1}' /etc/shadow | tr '\n' ' ')"
    if [[ -n "$(trim "$x")" ]]; then add_finding crit security "Compte(s) SANS mot de passe : $(trim "$x")" "Connexion possible sans authentification" fix_lock_empty "Verrouiller les comptes sans mot de passe (passwd -l)"
    else pass "Aucun compte sans mot de passe"; fi
  fi

  lst="$(perm_issues | tr '\n' ';')"
  if [[ -n "$lst" ]]; then add_finding warn security "Permissions trop ouvertes sur des fichiers sensibles" "$(cut_to "$lst" 110)" fix_perms "Rétablir les permissions sûres (shadow, sudoers, clés SSH…)"
  else pass "Permissions des fichiers sensibles correctes"; fi

  x="$(stat -c '%a' /tmp 2>/dev/null)"
  if [[ "$x" != 1777 ]]; then add_finding crit security "/tmp n'a pas le sticky bit (mode $x)" "N'importe qui peut supprimer les fichiers des autres" fix_tmp_perms "chmod 1777 /tmp /var/tmp"; else pass "/tmp : mode 1777"; fi

  x="$(find /tmp /var/tmp /dev/shm -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | head -n 5 | tr '\n' ' ')"
  if [[ -n "$(trim "$x")" ]]; then add_finding crit security "Fichier(s) setuid/setgid dans un dossier temporaire" "$(trim "$x")" fix_suid_tmp "Retirer les bits setuid/setgid de ces fichiers"
  else pass "Aucun exécutable setuid dans /tmp"; fi

  if (( ! QUICK )); then
    x="$(tmo 40 find /etc /usr /bin /sbin /lib /lib64 -xdev -type f -perm -0002 2>/dev/null | head -n 5 | tr '\n' ' ')"
    if [[ -n "$(trim "$x")" ]]; then add_finding warn security "Fichiers système modifiables par tous" "$(trim "$x")" fix_world_writable "Retirer le droit d'écriture 'autres' (chmod o-w)"
    else pass "Aucun fichier système world-writable"; fi
  fi

  x="$(ssh_dir_issues | tr '\n' ';')"
  if [[ -n "$x" ]]; then add_finding warn security "Permissions ~/.ssh trop ouvertes" "$(cut_to "$x" 100)" fix_ssh_perms "chmod 700 ~/.ssh et 600 sur les clés"; fi

  if is_root && have sshd && { svc_active ssh || svc_active sshd; }; then
    x="$(sshd_opt permitrootlogin)"
    [[ "$x" == yes ]] && add_finding warn security "SSH : connexion root par mot de passe autorisée" "PermitRootLogin yes" fix_sshd_harden "PermitRootLogin → prohibit-password (clé uniquement), PermitEmptyPasswords no"
    x="$(sshd_opt permitemptypasswords)"
    [[ "$x" == yes ]] && add_finding crit security "SSH : mots de passe vides autorisés" "PermitEmptyPasswords yes" fix_sshd_harden "PermitRootLogin → prohibit-password (clé uniquement), PermitEmptyPasswords no"
    [[ "$(sshd_opt passwordauthentication)" == yes ]] && note "SSH : authentification par mot de passe active (envisagez les clés SSH + fail2ban)"
    cnt="$(journalctl -u ssh -u sshd --since '-24h' --no-pager -q 2>/dev/null | grep -c 'Failed password')"; cnt=$(num "$cnt")
    (( cnt > 50 )) && add_finding warn security "$cnt échecs de connexion SSH en 24 h" "Tentatives de force brute probables — installez fail2ban"
  fi

  lst="$(public_listeners | awk '{printf "%s/%s ", $2, $1}')"
  if [[ -n "$(trim "$lst")" ]]; then
    note "Ports à l'écoute (non-loopback) : $(cut_to "$(trim "$lst")" 90)"
    if is_root && ! fw_active && (( ! IS_CONTAINER )); then
      add_finding warn security "Aucun pare-feu actif alors que des ports sont exposés" "" fix_firewall "Installer/activer ufw : deny entrant, allow sortant, SSH et services actuels autorisés"
    elif is_root; then pass "Pare-feu actif"; fi
  else pass "Aucun port exposé sur le réseau"; fi

  x=$(num "$(cat /proc/sys/kernel/randomize_va_space 2>/dev/null)")
  if (( x != 2 )); then add_finding warn security "ASLR désactivé ou partiel (valeur $x)" "" fix_sysctl_sec "Activer kernel.randomize_va_space=2 et protections hardlinks/symlinks"
  else pass "ASLR actif"; fi
}

# ---------- 8. Réseau & heure ----------
mod_network() {
  local gw dns_ok=0 ping_ok=0 ifs ntp hn bad
  ifs="$(ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | grep -v '^lo$' | tr '\n' ' ')"
  note "Interfaces actives : ${ifs:-aucune}"
  gw="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
  if [[ -z "$gw" ]]; then
    add_finding warn network "Aucune route par défaut" "Pas de passerelle : réseau non configuré ou déconnecté" fix_network_restart "Débloquer rfkill et redémarrer NetworkManager/systemd-networkd"
  else
    if tmo 5 ping -c1 -W2 "$gw" >/dev/null 2>&1; then pass "Passerelle $gw joignable"; else add_finding warn network "Passerelle $gw injoignable" ""; fi
  fi
  if tmo 6 ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || tmo 6 ping -c1 -W3 9.9.9.9 >/dev/null 2>&1; then ping_ok=1; pass "Accès Internet (IP) : OK"
  else note "Accès Internet (IP) : indisponible ou ICMP filtré"; fi
  if tmo 6 getent hosts example.com >/dev/null 2>&1; then dns_ok=1; pass "Résolution DNS : OK"
  elif (( ping_ok )); then add_finding crit network "Résolution DNS défaillante" "Internet fonctionne par IP mais les noms ne se résolvent pas" fix_dns "Redémarrer systemd-resolved / réparer /etc/resolv.conf"
  else note "Résolution DNS : indisponible (hors ligne ?)"; fi

  hn="$(hostname)"
  if [[ -n "$hn" ]] && ! getent hosts "$hn" >/dev/null 2>&1 && (( ! IS_CONTAINER )); then
    add_finding warn network "Le nom d'hôte « $hn » ne se résout pas" "Provoque des lenteurs (sudo, GNOME, applications)" fix_hosts "Ajouter $hn à /etc/hosts"
  else pass "Nom d'hôte résolu"; fi

  if (( HAS_SYSTEMD )) && have timedatectl && (( ! IS_CONTAINER )); then
    ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    if [[ "$ntp" == no ]]; then add_finding warn network "Horloge non synchronisée (NTP)" "Une heure fausse casse HTTPS, APT, certificats et journaux" fix_time_sync "Activer NTP (systemd-timesyncd) et resynchroniser"
    elif [[ "$ntp" == yes ]]; then pass "Horloge synchronisée (NTP)"; fi
  fi

  bad=""
  local d
  for d in /sys/class/net/*; do
    [[ "$(basename "$d")" == lo ]] && continue
    local e dr
    e=$(( $(num "$(cat "$d/statistics/rx_errors" 2>/dev/null)") + $(num "$(cat "$d/statistics/tx_errors" 2>/dev/null)") ))
    dr=$(( $(num "$(cat "$d/statistics/rx_dropped" 2>/dev/null)") + $(num "$(cat "$d/statistics/tx_dropped" 2>/dev/null)") ))
    (( e > 1000 || dr > 5000 )) && bad+="$(basename "$d")(err=$e,drop=$dr) "
  done
  [[ -n "$bad" ]] && add_finding info network "Erreurs/pertes de paquets importantes" "$bad"
  have rfkill && rfkill list 2>/dev/null | grep -q 'Hard blocked: yes' && add_finding info network "Radio matérielle bloquée (interrupteur Wi-Fi/Bluetooth)" ""
  return 0
}

# ---------- 9. Journaux & noyau ----------
mod_logs() {
  local errc top x kb sz
  if have journalctl; then
    errc=$(num "$(journalctl -p err -b --no-pager -q 2>/dev/null | wc -l)")
    if   (( errc > 300 )); then
      top="$(journalctl -p err -b -o cat --no-pager -q 2>/dev/null | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -n 3 | cut -c1-90 | tr '\n' ';')"
      add_finding warn logs "$errc erreurs dans le journal depuis le démarrage" "$top"
    elif (( errc > 40 )); then add_finding info logs "$errc erreurs dans le journal depuis le démarrage" ""
    else pass "Journal système : $errc erreur(s) depuis le démarrage"; fi
  fi
  x="$(grep -ciE 'segfault' <<<"$KMSG")"; x=$(num "$x")
  (( x > 0 )) && add_finding info logs "$x plantage(s) de programme (segfault)" "Voir : journalctl -k | grep segfault"
  x="$(grep -E 'Call Trace|BUG:|kernel panic|Oops:|general protection' <<<"$KMSG" | head -n 2 | cut -c1-100 | tr '\n' ' ')"
  [[ -n "$(trim "$x")" ]] && add_finding warn logs "Traces d'erreur noyau (BUG/Oops/Call Trace)" "$(trim "$x")"
  x="$(grep -E 'Machine check|mce:|Hardware Error' <<<"$KMSG" | head -n 2 | cut -c1-100 | tr '\n' ' ')"
  [[ -n "$(trim "$x")" ]] && add_finding crit logs "Erreur matérielle (MCE) signalée par le processeur" "$(trim "$x")"
  x="$(grep -ciE 'firmware: failed to load|failed to load firmware' <<<"$KMSG")"; x=$(num "$x")
  (( x > 0 )) && add_finding info logs "Firmware manquant pour du matériel ($x)" "Installez linux-firmware"

  sz=$(num "$(du -sm /var/log 2>/dev/null | awk '{print $1}')")
  note "/var/log : ${sz} Mio"
  (( sz > 2048 )) && add_finding warn logs "/var/log très volumineux (${sz} Mio)" "" fix_disk_clean "Nettoyer APT, journaux, caches, snaps, flatpak, anciens fichiers temporaires"
  x="$(find /var/log -xdev -type f -size +200M 2>/dev/null | head -n 3 | tr '\n' ' ')"
  [[ -n "$(trim "$x")" ]] && add_finding info logs "Fichiers de log énormes" "$(trim "$x")"
  sz=$(num "$(du -sm /var/lib/systemd/coredump 2>/dev/null | awk '{print $1}')")
  (( sz > 500 )) && add_finding info logs "Core dumps volumineux (${sz} Mio)" "" fix_disk_clean "Nettoyer APT, journaux, caches, snaps, flatpak, anciens fichiers temporaires"
  return 0
}

# ---------- 10. Matériel : température, batterie ----------
mod_hardware() {
  local z t v name max=0 maxn="" found=0 b cap st full des health thr
  for z in /sys/class/thermal/thermal_zone*; do
    [[ -r "$z/temp" ]] || continue
    v=$(num "$(cat "$z/temp" 2>/dev/null)"); t=$(( v / 1000 )); name="$(cat "$z/type" 2>/dev/null)"; found=1
    (( t > max )) && { max=$t; maxn="$name"; }
  done
  if (( found )); then
    note "Température max : ${max}°C ($maxn)"
    if   (( max >= 95 )); then add_finding crit hardware "Surchauffe critique : ${max}°C" "$maxn — nettoyez les ventilateurs/pâte thermique, éteignez si persistant"
    elif (( max >= 85 )); then add_finding warn hardware "Température élevée : ${max}°C" "$maxn"
    else pass "Températures normales (${max}°C)"; fi
  else note "Capteurs thermiques indisponibles (machine virtuelle ?)"; fi

  thr=0; for z in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do [[ -r "$z" ]] && thr=$(( thr + $(num "$(cat "$z")") )); done
  (( thr > 0 )) && add_finding info hardware "Le processeur a été bridé thermiquement ($thr fois)" "Refroidissement insuffisant"

  for b in /sys/class/power_supply/BAT*; do
    [[ -d "$b" ]] || continue
    cap=$(num "$(cat "$b/capacity" 2>/dev/null)"); st="$(cat "$b/status" 2>/dev/null)"
    full=$(num "$(cat "$b/energy_full" 2>/dev/null || cat "$b/charge_full" 2>/dev/null)")
    des=$(num "$(cat "$b/energy_full_design" 2>/dev/null || cat "$b/charge_full_design" 2>/dev/null)")
    note "Batterie $(basename "$b") : ${cap}% ($st)"
    if (( des > 0 && full > 0 )); then
      health=$(( full * 100 / des ))
      if   (( health < 50 )); then add_finding warn hardware "Batterie usée : ${health}% de sa capacité d'origine" "Remplacement conseillé"
      elif (( health < 70 )); then add_finding info hardware "Batterie vieillissante : ${health}% de sa capacité d'origine" ""
      else pass "Santé batterie : ${health}%"; fi
    fi
  done

  if [[ "$VIRT" == aucune ]] && is_root && { ! have smartctl || ! have sensors; }; then
    [[ "$PM" == apt ]] && add_finding info hardware "Outils de diagnostic matériel absents (smartmontools, lm-sensors)" "" fix_install_tools "Installer smartmontools et lm-sensors"
  fi
  return 0
}

# ---------- 11. Processus & ressources noyau ----------
mod_processes() {
  local z d fu fmax thr tmax top
  z="$(ps -eo pid=,ppid=,stat=,comm= 2>/dev/null | awk '$3 ~ /^Z/ {printf "%s(%s) ", $4, $1}')"
  if [[ -n "$(trim "$z")" ]]; then
    d=$(wc -w <<<"$z")
    (( d > 5 )) && add_finding warn processes "$d processus zombies" "$(cut_to "$(trim "$z")" 90)" fix_zombies "Envoyer SIGCHLD aux parents pour récolter les zombies" \
                || note "$d zombie(s) : $(trim "$z")"
  else pass "Aucun processus zombie"; fi
  d=$(ps -eo stat= 2>/dev/null | grep -c '^D'); d=$(num "$d")
  (( d > 3 )) && add_finding warn processes "$d processus bloqués en attente d'E/S (état D)" "Disque ou montage réseau (NFS) bloqué"
  read -r fu _ fmax < <(awk '{print $1, $2, $3}' /proc/sys/fs/file-nr 2>/dev/null)
  fu=$(num "$fu"); fmax=$(num "$fmax")
  if (( fmax > 0 && $(pct "$fu" "$fmax") > 80 )); then add_finding warn processes "Descripteurs de fichiers à $(pct "$fu" "$fmax")%" "$fu / $fmax : fuite de fichiers ouverts"
  else pass "Descripteurs de fichiers : OK"; fi
  thr=$(num "$(ps -eLf 2>/dev/null | wc -l)"); tmax=$(num "$(cat /proc/sys/kernel/threads-max 2>/dev/null)")
  (( tmax > 0 && $(pct "$thr" "$tmax") > 70 )) && add_finding warn processes "Nombre de threads proche de la limite" "$thr / $tmax"
  top="$(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -n 3 | awk '{printf "%s(%d Mio) ", $2, $1/1024}')"
  note "Top mémoire : $top"
  return 0
}

# ---------- 12. Comptes & configuration ----------
mod_users() {
  local x
  if have visudo; then
    if visudo -c -q >/dev/null 2>&1; then pass "sudoers : syntaxe valide"; else add_finding crit users "Fichier sudoers invalide" "Risque de perdre l'accès administrateur — corrigez avec visudo"; fi
  fi
  x="$(cut -d: -f3 /etc/passwd | sort | uniq -d | tr '\n' ' ')"
  [[ -n "$(trim "$x")" ]] && add_finding warn users "UID dupliqués dans /etc/passwd" "$(trim "$x")"
  if is_root; then
    x="$( { have pwck && pwck -r 2>&1; have grpck && grpck -r 2>&1; } | grep -Ei 'duplicate|invalid|no matching|bad|too long' | head -n 3 | tr '\n' ';')"
    [[ -n "$x" ]] && add_finding warn users "Incohérences dans passwd/group" "$(cut_to "$x" 100)" || pass "passwd/group cohérents"
  fi
  x="$(getent passwd | awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1":"$6}' | while IFS=: read -r u h; do [[ -d "$h" ]] || printf '%s ' "$u"; done)"
  [[ -n "$(trim "$x")" ]] && add_finding warn users "Utilisateur(s) sans dossier personnel" "$(trim "$x")"
  note "Utilisateurs avec shell de connexion : $(getent passwd | awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' | tr '\n' ' ')"
  return 0
}

# ---------- 13. Démarrage (boot) ----------
mod_boot() {
  local k m
  k="$(uname -r)"
  if [[ -d /boot ]] && (( ! IS_CONTAINER )); then
    if [[ -e "/boot/initrd.img-$k" || -e "/boot/initramfs-$k.img" || -e "/boot/initramfs-linux.img" ]]; then pass "initramfs présent pour le noyau $k"
    elif [[ -e /boot/vmlinuz-$k || -e /boot/vmlinuz-linux ]]; then add_finding warn boot "initramfs introuvable pour le noyau $k" "" fix_initramfs "Régénérer l'initramfs (update-initramfs -u)"; fi
    [[ -e /boot/grub/grub.cfg || -e /boot/grub2/grub.cfg || -d /boot/loader ]] && pass "Configuration du chargeur de démarrage présente"
    if [[ -d /sys/firmware/efi ]] && grep -q ' /boot/efi ' /etc/fstab 2>/dev/null && ! mountpoint -q /boot/efi 2>/dev/null; then
      add_finding warn boot "Partition EFI (/boot/efi) non montée" "Les mises à jour du chargeur échoueront" fix_mount_all "mount -a"
    fi
    local newest; newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n 1)"
    if [[ -n "$newest" && "$newest" != "$k" && "${newest##*-}" == "${k##*-}" ]] && [[ "$(printf '%s\n%s\n' "$k" "$newest" | sort -V | tail -n 1)" == "$newest" ]]; then
      add_finding info boot "Un noyau plus récent est installé ($newest)" "Vous tournez sur $k"
      REBOOT_REASONS+=("Un noyau plus récent ($newest) est installé mais pas encore actif.")
    fi
  fi
  return 0
}

# ---------- 14. Conteneurs ----------
mod_containers() {
  have docker || { note "Docker absent : module ignoré"; return; }
  svc_active docker || { note "Docker installé mais inactif"; return; }
  local rec ex
  ex=$(num "$(tmo 15 docker ps -aq --filter status=exited 2>/dev/null | wc -l)")
  rec="$(tmo 20 docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -n 4 | tr '\n' ' ')"
  note "Docker — espace récupérable : ${rec:-inconnu} — conteneurs arrêtés : $ex"
  (( ex > 20 )) && add_finding info containers "$ex conteneurs arrêtés" ""
  if [[ "$rec" =~ [0-9]+(\.[0-9]+)?GB ]]; then
    local sev=info; (( ROOT_PCT >= 85 )) && sev=warn
    add_finding "$sev" containers "Docker occupe de l'espace récupérable" "$rec — la partition / est à ${ROOT_PCT}%" fix_docker_clean "Docker : supprimer images dangling, cache de build, et (si vous confirmez) toutes les images inutilisées"
  fi
  return 0
}

# ---------- 15. Intégrité (approfondi) ----------
MOD_INTEG_FILES=""
mod_integrity() {
  local x
  x="$(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /bin /sbin -xtype l 2>/dev/null | head -n 5 | tr '\n' ' ')"
  [[ -n "$(trim "$x")" ]] && add_finding info integrity "Liens symboliques cassés dans les dossiers de binaires" "$(trim "$x")" || pass "Aucun lien cassé dans les dossiers de binaires"
  if (( DEEP )); then
    if [[ "$PM" == apt ]] && ! apt_busy; then
      note "Vérification des fichiers de paquets (dpkg --verify) — peut être long…"
      MOD_INTEG_FILES="$(tmo 600 dpkg --verify 2>/dev/null | grep -v ' c /' | awk '$1 ~ /5/ {print $NF}' | grep -E '^/(usr/)?(s?bin|lib|lib64)/|^/usr/(local/)?(s?bin|lib)/' | grep -vE '\.(whl|pyc|pth)$|/ensurepip/|/python-wheels/|/alternatives/' | head -n 200)"
      if [[ -n "$MOD_INTEG_FILES" ]]; then
        add_finding warn integrity "$(wc -l <<<"$MOD_INTEG_FILES") fichier(s) binaire(s)/bibliothèque(s) différent(s) du paquet d'origine" "$(head -n 4 <<<"$MOD_INTEG_FILES" | tr '\n' ' ') — mise à jour interrompue, disque défaillant ou compromission possible" fix_reinstall_modified "Réinstaller les paquets propriétaires de ces fichiers"
      else pass "Fichiers des paquets intègres (dpkg --verify)"; fi
    fi
    if have journalctl; then
      x="$(tmo 120 journalctl --verify 2>&1 | grep -ciE 'FAIL|corrupt')"; x=$(num "$x")
      (( x > 0 )) && add_finding warn integrity "Journal systemd corrompu ($x fichier(s))" "" fix_disk_clean "Nettoyer APT, journaux, caches, snaps, flatpak, anciens fichiers temporaires" || pass "Journal systemd intègre"
    fi
    x="$(tmo 90 find / -xdev \( -nouser -o -nogroup \) -not -path '/proc/*' -not -path '/run/*' -not -path '/sys/*' -not -path '/dev/*' -print 2>/dev/null | head -n 5 | tr '\n' ' ')"
    [[ -n "$(trim "$x")" ]] && add_finding info integrity "Fichiers sans propriétaire valide" "$(trim "$x")"
  else
    note "Mode --deep : active dpkg --verify, journalctl --verify et recherche de fichiers orphelins"
  fi
  return 0
}

# Registre : id|libellé|fonction|vitesse
MODULES=(
  "system|Identité & noyau|mod_system|fast"
  "cpu|Processeur & charge|mod_cpu|fast"
  "memory|Mémoire & swap|mod_memory|fast"
  "disk|Stockage & systèmes de fichiers|mod_disk|fast"
  "services|Services & démarrage|mod_services|fast"
  "packages|Paquets & mises à jour|mod_packages|fast"
  "security|Sécurité|mod_security|slow"
  "network|Réseau & horloge|mod_network|fast"
  "logs|Journaux & erreurs noyau|mod_logs|fast"
  "hardware|Matériel : températures, batterie|mod_hardware|fast"
  "processes|Processus & ressources|mod_processes|fast"
  "users|Comptes & configuration|mod_users|fast"
  "boot|Chargeur de démarrage|mod_boot|fast"
  "containers|Conteneurs|mod_containers|fast"
  "integrity|Intégrité du système|mod_integrity|slow"
)

list_modules() {
  local e id label fn sp
  printf '%sModules disponibles :%s\n' "$W" "$N"
  for e in "${MODULES[@]}"; do IFS='|' read -r id label fn sp <<<"$e"; printf '  %-11s %s\n' "$id" "$label"; done
}

select_modules() {
  SEL=(); local e id label fn sp
  for e in "${MODULES[@]}"; do
    IFS='|' read -r id label fn sp <<<"$e"
    [[ -n "$ONLY" && ",$ONLY," != *",$id,"* ]] && continue
    [[ -n "$SKIP" && ",$SKIP," == *",$id,"* ]] && continue
    SEL+=("$e")
  done
}

# =============================================================================
#  SOINS (réparations) — chacun re-détecte lui-même son périmètre
# =============================================================================
fix_machine_id() { run systemd-machine-id-setup; }

fix_memory_clean() {
  local used avail total need line dev prio
  run sync
  if (( ! DRY_RUN )); then echo 3 >/proc/sys/vm/drop_caches 2>/dev/null && act "Caches noyau libérés"; fi
  [[ -w /proc/sys/vm/compact_memory ]] && (( ! DRY_RUN )) && echo 1 >/proc/sys/vm/compact_memory && act "Mémoire compactée"
  used=$(awk 'NR>1 && $1 !~ /zram/ {s+=$4} END{print s+0}' /proc/swaps)
  if (( used >= 51200 )); then
    avail=$(num "$(meminfo MemAvailable)"); total=$(num "$(meminfo MemTotal)")
    need=$(( used * 115 / 100 + total / 20 ))
    if (( avail < need )); then warn "Purge du swap ignorée : pas assez de RAM libre pour le rapatrier sans risque."
    else
      while read -r dev prio; do
        [[ -n "$dev" ]] || continue
        run swapoff "$dev" && run swapon -p "$prio" "$dev"
      done < <(awk 'NR>1 && $1 !~ /zram/ {print $1" "$5}' /proc/swaps)
      act "Swap disque purgé et réactivé"
    fi
  fi
  return 0
}

fix_memory_harden() {
  local total_kb total_mb disk_swaps swappiness=30 minfree has_z=0
  total_kb=$(num "$(meminfo MemTotal)"); total_mb=$(( total_kb / 1024 ))
  grep -q '^/dev/zram' /proc/swaps && has_z=1
  if (( ! has_z )) && [[ "$PM" == apt ]]; then
    act "Installation de zram (swap compressé en RAM)"
    if (( DRY_RUN )); then act "[simulation] apt-get install systemd-zram-generator"
    elif $APT install systemd-zram-generator >/dev/null 2>&1; then
      write_file /etc/systemd/zram-generator.conf.d/90-buildwith.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
EOF
      systemctl daemon-reload; systemctl start systemd-zram-setup@zram0.service 2>/dev/null && has_z=1 || warn "zram sera actif au prochain démarrage."
    elif $APT install zram-config >/dev/null 2>&1; then act "zram-config installé (actif au prochain démarrage)"
    else warn "zram indisponible sur ce système."; fi
  fi
  disk_swaps=$(awk 'NR>1 && $1 !~ /zram/' /proc/swaps | wc -l)
  if (( disk_swaps == 0 )) && [[ ! -e /swapfile ]]; then
    local fstype free_mb size_mb
    fstype="$(findmnt -no FSTYPE / 2>/dev/null)"; free_mb=$(num "$(df --output=avail -m / | tail -n 1 | tr -d ' ')")
    size_mb=$(( total_mb < 2048 ? 2048 : (total_mb > 4096 ? 4096 : total_mb) ))
    if [[ "$fstype" =~ ^(ext4|xfs)$ ]] && (( free_mb > size_mb + 5120 )); then
      act "Création d'un swap de secours (${size_mb} Mio)"
      if (( DRY_RUN )); then act "[simulation] création /swapfile"
      else
        if fallocate -l "${size_mb}M" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon -p 10 /swapfile; then
          backup_file /etc/fstab; grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=10 0 0' >>/etc/fstab
        else
          warn "Impossible d'activer le swap de secours (conteneur ?) : fichier supprimé."; rm -f /swapfile
        fi
      fi
    else warn "Pas de swap disque créé (système de fichiers « $fstype » ou espace insuffisant)."; fi
  fi
  (( has_z )) && swappiness=100
  minfree=$(( total_kb / 100 )); (( minfree < 32768 )) && minfree=32768; (( minfree > 131072 )) && minfree=131072
  write_file /etc/sysctl.d/99-buildwith-memory.conf <<EOF
# Généré par BuildWith Doctor
vm.swappiness = ${swappiness}
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${minfree}
$( (( has_z )) && echo "vm.page-cluster = 0" )
EOF
  (( DRY_RUN )) || sysctl -q -p /etc/sysctl.d/99-buildwith-memory.conf >/dev/null 2>&1
  act "sysctl : swappiness=${swappiness}, min_free_kbytes=${minfree}"
  if [[ "$PM" == apt ]]; then
    if (( DRY_RUN )); then act "[simulation] installation d'earlyoom"
    elif $APT install earlyoom >/dev/null 2>&1; then
      write_file /etc/default/earlyoom <<'EOF'
# Généré par BuildWith Doctor
EARLYOOM_ARGS="-r 3600 -m 5 -s 5 --avoid '(^|/)(gnome-shell|Xorg|Xwayland|gdm|gdm3|systemd|systemd-logind|sshd|NetworkManager|pipewire|wireplumber|dbus-daemon)$' --prefer '(^|/)(chrome|chromium|firefox|Web Content|code|electron|slack|teams)$'"
EOF
      systemctl enable --now earlyoom >/dev/null 2>&1; systemctl restart earlyoom 2>/dev/null
      act "earlyoom actif : protège gnome-shell, sacrifie d'abord navigateurs/éditeurs"
    else warn "earlyoom indisponible."; fi
  fi
  return 0
}

fix_disk_clean() {
  local before after
  before=$(num "$(df --output=avail -k / | tail -n 1 | tr -d ' ')")
  if [[ "$PM" == apt ]]; then run apt-get clean; run $APT autoremove --purge; fi
  have dnf && run dnf clean all -q
  have pacman && run paccache -r -q
  have journalctl && { run journalctl --vacuum-time=7d --vacuum-size=200M >/dev/null 2>&1; act "Journal systemd réduit (7 j / 200 Mo)"; }
  (( DRY_RUN )) || {
    find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' -o -name '*.xz' \) -mtime +7 -delete 2>/dev/null
    find /var/lib/systemd/coredump -type f -mtime +3 -delete 2>/dev/null
    find /var/crash -type f -mtime +3 -delete 2>/dev/null
    find /tmp /var/tmp -xdev -type f -atime +10 -not -name '.X*' -not -name '*.sock' -delete 2>/dev/null
    [[ -d "$REAL_HOME/.cache/thumbnails" ]] && rm -rf "${REAL_HOME:?}/.cache/thumbnails/"* 2>/dev/null
    log "Nettoyage disque effectué (logs, coredumps, crash, tmp, miniatures)"
  }
  act "Anciens logs compressés, core dumps, rapports de crash, fichiers temporaires > 10 j, miniatures"
  have snap && fix_snap_clean
  have flatpak && { run flatpak uninstall --unused -y >/dev/null 2>&1; act "Flatpak : runtimes inutilisés retirés"; }
  have docker && svc_active docker && fix_docker_clean
  after=$(num "$(df --output=avail -k / | tail -n 1 | tr -d ' ')")
  okk "Espace récupéré sur / : $(gio $(( after > before ? after - before : 0 )))"
  return 0
}
fix_snap_clean() {
  have snap || return 0
  run snap set system refresh.retain=2
  LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r n r; do run snap remove "$n" --revision="$r" >/dev/null 2>&1; done
  act "Snap : anciennes révisions retirées"
}
fix_docker_clean() {
  run docker image prune -f >/dev/null 2>&1; run docker builder prune -f --filter until=168h >/dev/null 2>&1
  act "Docker : images dangling et cache de build > 7 j supprimés"
  if (( ! ASSUME_YES )) && confirm "  Supprimer AUSSI toutes les images Docker inutilisées (re-téléchargées au besoin) ?"; then
    run docker image prune -a -f >/dev/null 2>&1; act "Docker : images inutilisées supprimées"
  fi
  return 0
}
fix_trim() { run systemctl enable --now fstrim.timer && run fstrim -av; }

fix_failed_services() {
  local u rc=0
  while read -r u; do
    [[ -n "$u" ]] || continue
    run systemctl reset-failed "$u"
    case "$u" in
      *.service|*.socket|*.timer|*.path)
        local st="ok"
        if run systemctl restart "$u" 2>/dev/null; then
          (( DRY_RUN )) || sleep 3
          (( DRY_RUN )) || case "$(systemctl is-active "$u" 2>/dev/null)" in failed|activating|auto-restart) st="bad" ;; esac
        else st="bad"; fi
        if [[ "$st" == ok ]]; then act "$u redémarré et stable"
        else
          warn "$u ne reste pas actif. Dernières lignes :"
          journalctl -u "$u" -n 3 --no-pager -q 2>/dev/null | cut -c1-120 | sed 's/^/        /'
          act "Si ce service est inutile : sudo systemctl disable --now $u   (souvent un port déjà pris ou une config invalide)"
          rc=1
        fi ;;
      *) act "$u : état d'échec réinitialisé" ;;
    esac
  done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
  return $rc
}

fix_apt_repair() {
  [[ "$PM" == apt ]] || return 1
  run dpkg --configure -a
  run $APT install -f
}
fix_upgrade() {
  case "$PM" in
    apt)    run $APT update && run $APT upgrade ;;
    dnf)    run dnf upgrade -y -q ;;
    pacman) run pacman -Syu --noconfirm ;;
    *)      return 1 ;;
  esac
}
fix_apt_autoremove() { run $APT autoremove --purge; }
fix_purge_rc() {
  local pk; pk="$(dpkg -l 2>/dev/null | awk '/^rc/{print $2}')"
  [[ -n "$pk" ]] || return 0
  # shellcheck disable=SC2086
  run dpkg --purge $pk
}
fix_install_tools() { run $APT install smartmontools lm-sensors; }
fix_reinstall_modified() {
  local pk f
  pk="$(while read -r f; do [[ -n "$f" ]] && dpkg -S "$f" 2>/dev/null | head -n 1 | cut -d: -f1; done <<<"$MOD_INTEG_FILES" | sort -u | head -n 25 | tr '\n' ' ')"
  [[ -n "$(trim "$pk")" ]] || { warn "Aucun paquet propriétaire identifié."; return 1; }
  act "Réinstallation : $pk"
  # shellcheck disable=SC2086
  run $APT install --reinstall $pk
}

fix_lock_empty() {
  local u
  for u in $(awk -F: '$2==""{print $1}' /etc/shadow); do backup_file /etc/shadow; run passwd -l "$u" >/dev/null && act "Compte $u verrouillé"; done
}
fix_perms() {
  local f cur max
  while read -r f cur max; do
    [[ -n "$f" ]] || continue
    run chmod "$max" "$f" && act "$f : $cur → $max"
  done < <(perm_issues; ssh_dir_issues)
}
fix_ssh_perms() { fix_perms; }
fix_tmp_perms() { run chmod 1777 /tmp /var/tmp; }
fix_suid_tmp()  { find /tmp /var/tmp /dev/shm -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | while read -r f; do run chmod u-s,g-s "$f" && act "Bits setuid/setgid retirés : $f"; done; }
fix_world_writable() { tmo 60 find /etc /usr /bin /sbin /lib /lib64 -xdev -type f -perm -0002 2>/dev/null | while read -r f; do run chmod o-w "$f" && act "o-w : $f"; done; }

fix_sshd_harden() {
  local f files=(/etc/ssh/sshd_config) rc=0
  for f in /etc/ssh/sshd_config.d/*.conf; do [[ -f "$f" ]] && files+=("$f"); done
  for f in "${files[@]}"; do
    grep -qiE '^\s*(PermitRootLogin\s+yes|PermitEmptyPasswords\s+yes)' "$f" 2>/dev/null || continue
    backup_file "$f"
    run sed -i -E 's/^(\s*PermitRootLogin\s+)yes/\1prohibit-password/I; s/^(\s*PermitEmptyPasswords\s+)yes/\1no/I' "$f"
    act "Modifié : $f"
  done
  (( DRY_RUN )) && return 0
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    act "Configuration SSH validée et rechargée"
  else
    err "sshd -t a échoué : restauration des fichiers d'origine"
    for f in "${files[@]}"; do restore_file "$f"; done; rc=1
  fi
  return $rc
}

fix_sysctl_sec() {
  write_file /etc/sysctl.d/99-buildwith-security.conf <<'EOF'
# Généré par BuildWith Doctor
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.kptr_restrict = 1
EOF
  (( DRY_RUN )) || sysctl -q -p /etc/sysctl.d/99-buildwith-security.conf >/dev/null 2>&1
}

fix_firewall() {
  local ssh_port proto port desktop=0
  [[ "$PM" == apt ]] || { warn "Installation automatique de ufw non supportée ici."; return 1; }
  have ufw || run $APT install ufw || return 1
  [[ "$(systemctl get-default 2>/dev/null)" == graphical.target ]] && desktop=1
  run ufw default deny incoming >/dev/null; run ufw default allow outgoing >/dev/null
  ssh_port="$(ss -H -tlnp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]}' | sort -u)"
  for port in $ssh_port; do run ufw allow "$port"/tcp >/dev/null && act "Autorisé : SSH ($port/tcp)"; done
  if (( ! desktop )); then
    while read -r proto port; do
      [[ -n "$port" ]] || continue
      [[ " $ssh_port " == *" $port "* ]] && continue
      case "$port" in 23|3306|5432|6379|27017|11211|9200) warn "Port $port/$proto (base de données/risqué) NON ouvert automatiquement"; continue ;; esac
      [[ "$proto" == tcp ]] && { run ufw allow "$port"/tcp >/dev/null && act "Autorisé : service en écoute $port/tcp"; }
    done < <(public_listeners)
  fi
  run ufw --force enable >/dev/null && act "Pare-feu ufw activé"
}

fix_network_restart() {
  have rfkill && run rfkill unblock all
  if   svc_active NetworkManager;   then run systemctl restart NetworkManager
  elif svc_active systemd-networkd; then run systemctl restart systemd-networkd
  else warn "Aucun gestionnaire réseau actif trouvé."; return 1; fi
  (( DRY_RUN )) || sleep 4
}
fix_dns() {
  if unit_exists systemd-resolved.service; then
    run systemctl enable --now systemd-resolved >/dev/null 2>&1; run systemctl restart systemd-resolved
    if [[ ! -s /etc/resolv.conf ]] || ! grep -q '^nameserver' /etc/resolv.conf; then
      backup_file /etc/resolv.conf; run ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; act "/etc/resolv.conf relié au résolveur systemd"
    fi
  elif svc_active NetworkManager; then run systemctl restart NetworkManager
  fi
  if (( ! DRY_RUN )) && ! getent hosts example.com >/dev/null 2>&1; then
    warn "DNS toujours HS : ajout de serveurs publics de secours (1.1.1.1, 9.9.9.9)"
    backup_file /etc/resolv.conf; [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >/etc/resolv.conf
  fi
  (( DRY_RUN )) || getent hosts example.com >/dev/null 2>&1
}
fix_hosts() { local hn; hn="$(hostname)"; backup_file /etc/hosts; (( DRY_RUN )) && { act "[simulation] ajout 127.0.1.1 $hn"; return 0; }; printf '127.0.1.1\t%s\n' "$hn" >>/etc/hosts; }
fix_time_sync() {
  if unit_exists systemd-timesyncd.service && ! unit_exists chrony.service; then run systemctl enable --now systemd-timesyncd >/dev/null 2>&1; fi
  run timedatectl set-ntp true
  (( DRY_RUN )) || sleep 5
}

fix_zombies() {
  local pp
  for pp in $(ps -eo ppid=,stat= 2>/dev/null | awk '$2 ~ /^Z/ {print $1}' | sort -u); do
    [[ "$pp" -gt 1 ]] && { run kill -CHLD "$pp" 2>/dev/null; act "SIGCHLD envoyé au parent $pp ($(ps -o comm= -p "$pp" 2>/dev/null))"; }
  done
  return 0
}
fix_initramfs() { run update-initramfs -u -k "$(uname -r)"; }
fix_mount_all() { run mount -a; }

# =============================================================================
#  SCAN, SCORE, RAPPORT
# =============================================================================
reset_findings() { F_SEV=(); F_MOD=(); F_TITLE=(); F_DETAIL=(); F_FIX=(); F_FIXD=(); PASS_N=0; REBOOT_REASONS=(); }

run_scan() {
  reset_findings
  load_kmsg
  local total=${#SEL[@]} i=0 e id label fn sp
  for e in "${SEL[@]}"; do
    IFS='|' read -r id label fn sp <<<"$e"
    i=$((i+1))
    [[ "$sp" == slow && $QUICK -eq 1 && "$id" == integrity ]] && continue
    (( QUIET )) || module_header "$i" "$total" "$label"
    log "MODULE: $id"
    "$fn" || true
  done
  compute_score
}

compute_score() {
  local s
  NC=0; NW=0; NI=0
  for s in "${F_SEV[@]}"; do case "$s" in crit) NC=$((NC+1));; warn) NW=$((NW+1));; *) NI=$((NI+1));; esac; done
  SCORE=$(( 100 - NC*12 - NW*4 - NI ))
  (( SCORE < 0 )) && SCORE=0
  (( NC > 0 && SCORE > 69 )) && SCORE=69
}

score_label() {
  if   (( SCORE >= 90 )); then printf 'Excellente santé'
  elif (( SCORE >= 75 )); then printf 'Bonne santé'
  elif (( SCORE >= 50 )); then printf 'À soigner'
  else printf 'État préoccupant'; fi
}
score_color() { if (( SCORE >= 90 )); then printf '%s' "$HG"; elif (( SCORE >= 75 )); then printf '%s' "$G"; elif (( SCORE >= 50 )); then printf '%s' "$Y"; else printf '%s' "$HR"; fi; }
score_bar() {
  local f k bar=""; f=$(( SCORE / 5 ))
  for (( k=0; k<20; k++ )); do (( k < f )) && bar+="█" || bar+="░"; done
  printf '%s%s%s' "$(score_color)" "$bar" "$N"
}

show_summary() {
  local sev ic col i n=0 label
  title "DIAGNOSTIC"
  printf '\n  %sIndice de santé%s  %s  %s%d/100%s — %s\n' "$W" "$N" "$(score_bar)" "$W$(score_color)" "$SCORE" "$N" "$(score_label)"
  printf '  %s✘ %d critique(s)%s   %s▲ %d avertissement(s)%s   %sℹ %d info(s)%s   %s✔ %d contrôle(s) réussi(s)%s\n' \
    "$R" "$NC" "$N" "$Y" "$NW" "$N" "$B" "$NI" "$N" "$G" "$PASS_N" "$N"
  if (( ${#F_SEV[@]} == 0 )); then
    printf '\n  %sAucune anomalie détectée. Le patient est en pleine forme !%s\n' "$HG" "$N"; return
  fi
  for sev in crit warn info; do
    case "$sev" in crit) ic="✘"; col="$R"; label="CRITIQUE";; warn) ic="▲"; col="$Y"; label="AVERTISSEMENT";; *) ic="ℹ"; col="$B"; label="INFORMATION";; esac
    local shown=0
    for i in "${!F_SEV[@]}"; do
      [[ "${F_SEV[i]}" == "$sev" ]] || continue
      (( shown == 0 )) && printf '\n  %s%s%s%s\n' "$W" "$col" "$label" "$N"
      shown=1; n=$((n+1))
      printf '  %s%s %2d.%s %s%s%s %s[%s]%s\n' "$col" "$ic" "$n" "$N" "$W" "${F_TITLE[i]}" "$N" "$D" "${F_MOD[i]}" "$N"
      [[ -n "${F_DETAIL[i]}" ]] && wrap "${F_DETAIL[i]}" 9 | sed "s/^/$D/; s/\$/$N/"
      [[ -n "${F_FIX[i]}" ]] && printf '       %sRx →%s %s\n' "$C" "$N" "${F_FIXD[i]}"
    done
  done
}

json_escape() { printf '%s' "${1:-}" | tr '\n\t\r' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\010\013\014\016-\037'; }

write_reports() {
  local i first=1 title_s
  {
    echo "$APP v$VERSION — by BuildWith"
    echo "Rapport du $(date '+%F %T') — hôte $(hostname) — noyau $(uname -r)"
    echo "Indice de santé : $SCORE/100 ($(score_label)) — critiques: $NC, avertissements: $NW, infos: $NI, réussis: $PASS_N"
    echo
    for i in "${!F_SEV[@]}"; do
      printf '[%s] (%s) %s\n    %s\n' "${F_SEV[i]^^}" "${F_MOD[i]}" "${F_TITLE[i]}" "${F_DETAIL[i]}"
      [[ -n "${F_FIX[i]}" ]] && printf '    Soin proposé : %s\n' "${F_FIXD[i]}"
    done
    if (( ${#FIX_RESULTS[@]} )); then echo; echo "Traitements :"; printf '  %s\n' "${FIX_RESULTS[@]}"; fi
    [[ -d "$BACKUP_DIR" ]] && { echo; echo "Sauvegardes des fichiers modifiés : $BACKUP_DIR"; }
  } >"$REPORT_TXT" 2>/dev/null
  {
    printf '{\n  "tool": "%s", "version": "%s", "signature": "by BuildWith",\n' "$APP" "$VERSION"
    printf '  "date": "%s", "host": "%s", "kernel": "%s",\n' "$(date -Is)" "$(json_escape "$(hostname)")" "$(uname -r)"
    printf '  "score": %d, "critical": %d, "warnings": %d, "info": %d, "passed": %d,\n  "findings": [' "$SCORE" "$NC" "$NW" "$NI" "$PASS_N"
    for i in "${!F_SEV[@]}"; do
      (( first )) || printf ','; first=0
      printf '\n    {"severity":"%s","module":"%s","title":"%s","detail":"%s","fix":"%s"}' \
        "${F_SEV[i]}" "${F_MOD[i]}" "$(json_escape "${F_TITLE[i]}")" "$(json_escape "${F_DETAIL[i]}")" "$(json_escape "${F_FIXD[i]}")"
    done
    printf '\n  ]\n}\n'
  } >"$REPORT_JSON" 2>/dev/null
  chmod 640 "$REPORT_TXT" "$REPORT_JSON" 2>/dev/null
  ln -sf "$REPORT_TXT" "$LOG_DIR/dernier-rapport.txt" 2>/dev/null
  ln -sf "$REPORT_JSON" "$LOG_DIR/dernier-rapport.json" 2>/dev/null
}

# =============================================================================
#  TRAITEMENT
# =============================================================================
heal() {
  if ! is_root; then err "Le traitement exige les droits root (relancez avec sudo)."; return 1; fi
  local order=(crit warn info) sev i fix list=() idx=0 total=0 ok_n=0 ko_n=0 skip_n=0 desc
  declare -A seen=()
  for sev in "${order[@]}"; do
    for i in "${!F_SEV[@]}"; do
      [[ "${F_SEV[i]}" == "$sev" ]] || continue
      fix="${F_FIX[i]}"; [[ -n "$fix" && -z "${seen[$fix]:-}" ]] || continue
      seen[$fix]=1; list+=("$i")
    done
  done
  total=${#list[@]}
  title "ORDONNANCE"
  if (( total == 0 )); then okk "Aucun soin automatique à administrer."; return 0; fi
  (( DRY_RUN )) && warn "MODE SIMULATION : aucun changement ne sera appliqué."
  info "$total soin(s) proposé(s). Sauvegardes : $BACKUP_DIR"
  for i in "${list[@]}"; do
    idx=$((idx+1)); fix="${F_FIX[i]}"; sev="${F_SEV[i]}"; desc="${F_FIXD[i]}"
    printf '\n%s[%d/%d]%s %s%s%s %s(%s)%s\n' "$W$C" "$idx" "$total" "$N" "$W" "$desc" "$N" "$D" "${F_TITLE[i]}" "$N"
    if [[ "$sev" == info && $ASSUME_YES -eq 1 && $FULL -eq 0 ]]; then
      info "Soin optionnel ignoré (ajoutez --full pour l'inclure)."; FIX_RESULTS+=("IGNORÉ  $desc"); skip_n=$((skip_n+1)); continue
    fi
    if ! confirm "  Administrer ce soin ?"; then
      FIX_RESULTS+=("REFUSÉ  $desc"); skip_n=$((skip_n+1)); continue
    fi
    log "SOIN: $fix ($desc)"
    if "$fix"; then okk "Soin appliqué."; FIX_RESULTS+=("OK      $desc"); ok_n=$((ok_n+1))
    else err "Le soin a échoué ou n'est que partiel (voir $ACTION_LOG)."; FIX_RESULTS+=("ÉCHEC   $desc"); ko_n=$((ko_n+1)); fi
  done
  printf '\n  %s✔ %d appliqué(s)%s   %s✘ %d échec(s)%s   %s• %d ignoré(s)%s\n' "$G" "$ok_n" "$N" "$R" "$ko_n" "$N" "$D" "$skip_n" "$N"
  return 0
}

recheck() {
  title "CONTRE-VISITE"
  local before=$SCORE
  QUIET=1; (( ANIM )) && printf '  Nouvelle auscultation en cours…\n'
  run_scan; QUIET=0
  printf '\n  Indice de santé : %s%d%s → %s%s%d/100%s %s(%s)%s\n' "$D" "$before" "$N" "$W" "$(score_color)" "$SCORE" "$N" "$D" "$(score_label)" "$N"
  if (( ${#F_SEV[@]} )); then
    printf '  Problèmes restants :\n'
    local i; for i in "${!F_SEV[@]}"; do printf '   %s• [%s]%s %s\n' "$D" "${F_SEV[i]}" "$N" "${F_TITLE[i]}"; done
  else printf '  %sTous les symptômes ont disparu.%s\n' "$HG" "$N"; fi
}

reboot_check() {
  title "FAUT-IL REDÉMARRER ?"
  (( NO_REBOOT )) && { info "Redémarrage non proposé (--no-reboot)."; return 0; }
  if (( ${#REBOOT_REASONS[@]} == 0 )); then okk "Aucun redémarrage nécessaire."; return 0; fi
  warn "Redémarrage recommandé pour ${#REBOOT_REASONS[@]} raison(s) :"
  printf '   • %s\n' "${REBOOT_REASONS[@]}"
  (( DRY_RUN )) && { info "Simulation : pas de redémarrage."; return 0; }
  is_root || return 0
  if (( ASSUME_YES )); then info "Redémarrage non automatique : relancez-le vous-même quand vous êtes prêt."; return 0; fi
  if confirm "Redémarrer maintenant ? Enregistrez votre travail avant."; then
    warn "Redémarrage dans 15 s — Ctrl+C pour annuler."
    local s; for s in $(seq 15 -1 1); do printf '\r  %2d s ' "$s"; sleep 1; done; echo
    systemctl reboot
  else info "Pensez à redémarrer dès que possible."; fi
}

# =============================================================================
#  MENU
# =============================================================================
menu() {
  local c
  printf '\n  %s1)%s Consultation complète       %s(diagnostic seul, aucune modification)%s\n' "$W$C" "$N" "$D" "$N"
  printf '  %s2)%s Consultation + traitement   %s(je valide chaque soin)%s\n' "$W$C" "$N" "$D" "$N"
  printf '  %s3)%s Traitement automatique      %s(soins critiques/importants sans question)%s\n' "$W$C" "$N" "$D" "$N"
  printf '  %s4)%s Consultation approfondie    %s(+ intégrité des paquets, journal, fichiers orphelins)%s\n' "$W$C" "$N" "$D" "$N"
  printf '  %s5)%s Consultation rapide\n' "$W$C" "$N"
  printf '  %s6)%s Simulation du traitement    %s(--dry-run : rien ne change)%s\n' "$W$C" "$N" "$D" "$N"
  printf '  %s7)%s Lire le dernier rapport\n' "$W$C" "$N"
  printf '  %s0)%s Quitter\n\n' "$W$C" "$N"
  read -r -p "  Votre choix : " c </dev/tty || exit 0
  case "$c" in
    1) ACTION="scan" ;;
    2) ACTION="heal" ;;
    3) ACTION="heal"; ASSUME_YES=1 ;;
    4) ACTION="scan"; DEEP=1 ;;
    5) ACTION="scan"; QUICK=1 ;;
    6) ACTION="heal"; DRY_RUN=1 ;;
    7) if [[ -r "$LOG_DIR/dernier-rapport.txt" ]]; then ${PAGER:-less} "$LOG_DIR/dernier-rapport.txt"; else warn "Aucun rapport précédent."; fi; exit 0 ;;
    *) printf '\n  Bonne continuation !\n'; signature; exit 0 ;;
  esac
}

# =============================================================================
#  PROGRAMME PRINCIPAL
# =============================================================================
main() {
  if (( LIST )); then list_modules; exit 0; fi

  # Les actions qui modifient ou exigent root relancent sous sudo AVANT l'écran d'accueil.
  if [[ -n "$ACTION" ]] && ! is_root; then ensure_root "${ORIG_ARGS[@]}" || true; fi

  splash
  if [[ -z "$ACTION" ]]; then
    if (( IS_TTY )); then
      is_root || { ensure_root "${ORIG_ARGS[@]}" || true; }
      menu
    else ACTION="scan"; fi
  fi
  is_root || warn "Exécution sans root : diagnostic partiel."

  setup_dirs
  detect_env
  select_modules
  (( ${#SEL[@]} )) || { err "Aucun module sélectionné (voir --list)."; exit 2; }

  printf '\n  %sConsultation du %s — hôte %s — %d module(s)%s%s%s\n' "$D" "$(date '+%d/%m/%Y %H:%M')" "$(hostname)" "${#SEL[@]}" \
    "$( (( DEEP )) && echo ' — mode approfondi')" "$( (( QUICK )) && echo ' — mode rapide')" "$N"
  hr

  run_scan
  show_summary
  SCORE_BEFORE=$SCORE

  if [[ "$ACTION" == heal ]]; then
    heal
    (( DRY_RUN )) || recheck
  fi

  reboot_check
  write_reports
  printf '\n  %sRapport :%s %s\n  %sJSON    :%s %s\n' "$D" "$N" "$REPORT_TXT" "$D" "$N" "$REPORT_JSON"
  [[ -d "$BACKUP_DIR" ]] && printf '  %sSauvegardes :%s %s\n' "$D" "$N" "$BACKUP_DIR"
  signature
  log "=== Fin — score $SCORE, crit=$NC, warn=$NW, info=$NI ==="

  (( NC > 0 )) && exit 2
  (( NW > 0 )) && exit 1
  exit 0
}

main
