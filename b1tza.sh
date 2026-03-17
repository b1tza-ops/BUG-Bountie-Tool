#!/usr/bin/env bash
# ================================================================
#  SCAN.SH — Interactive Bug Bounty Scanner v2.0
#  Full TUI: arrow-key menus, animated spinners, live progress
#            bars, real-time findings counter, phase selector
# ================================================================

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────
R='\033[0;31m';  RB='\033[1;31m'
G='\033[0;32m';  GB='\033[1;32m'
Y='\033[0;33m';  YB='\033[1;33m'
C='\033[0;36m';  CB='\033[1;36m'
M='\033[0;35m';  MB='\033[1;35m'
W='\033[1;37m';  DIM='\033[2m'
NC='\033[0m'

# ── Terminal helpers ──────────────────────────────────────────────
hide_cursor()  { tput civis 2>/dev/null || true; }
show_cursor()  { tput cnorm 2>/dev/null || true; }
clear_line()   { printf '\r\033[K'; }
move_up()      { tput cuu "${1:-1}" 2>/dev/null || true; }
trap 'show_cursor; echo ""' EXIT INT TERM

# ── Global state ──────────────────────────────────────────────────
TARGET=""
BASE_DIR="$HOME/bugbounty/scans"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT=""
LOG=""
RATE_LIMIT=50
THREADS=10
SCAN_MODE="full"
SCAN_START=0
CURRENT_PHASE=0
PHASE_START=0

WORDLIST_SMALL="$HOME/wordlists/common.txt"
WORDLIST_MEDIUM="$HOME/wordlists/SecLists/Discovery/Web-Content/raft-medium-directories.txt"
WORDLIST_SUBS="$HOME/wordlists/SecLists/Discovery/DNS/subdomains-top1million-5000.txt"

FINDINGS_CRITICAL=0; FINDINGS_HIGH=0; FINDINGS_MEDIUM=0
FINDINGS_LOW=0;      FINDINGS_INFO=0; FINDINGS_XSS=0

declare -A PHASE_ENABLED=(
    [1]=1 [2]=1 [3]=1 [4]=1 [5]=1
    [6]=1 [7]=1 [8]=1 [9]=1 [10]=1
)

ALLOWED_TARGETS=()

# ── Logging helpers ───────────────────────────────────────────────
log()     { local m="$1"; [ -n "$LOG" ] && echo -e "${C}[*]${NC} $m" | tee -a "$LOG" || echo -e "${C}[*]${NC} $m"; }
success() { local m="$1"; [ -n "$LOG" ] && echo -e "${GB}[✓]${NC} $m" | tee -a "$LOG" || echo -e "${GB}[✓]${NC} $m"; }
warn()    { local m="$1"; [ -n "$LOG" ] && echo -e "${YB}[!]${NC} $m" | tee -a "$LOG" || echo -e "${YB}[!]${NC} $m"; }
error()   { local m="$1"; [ -n "$LOG" ] && echo -e "${RB}[✗]${NC} $m" | tee -a "$LOG" || echo -e "${RB}[✗]${NC} $m"; }
skip()    { local m="$1"; [ -n "$LOG" ] && echo -e "${DIM}[-] SKIP: $m${NC}" | tee -a "$LOG" || echo -e "${DIM}[-] SKIP: $m${NC}"; }

has_tool() {
    command -v "$1" &>/dev/null || \
    [ -f "$HOME/go/bin/$1" ]    || \
    [ -f "/usr/local/bin/$1" ]  || \
    [ -f "$HOME/.local/bin/$1" ]
}

run_tool() {
    local t="$1"; shift
    for p in "$HOME/go/bin/$t" "/usr/local/bin/$t" "$HOME/.local/bin/$t" "$(command -v "$t" 2>/dev/null)"; do
        [ -x "$p" ] && { "$p" "$@"; return $?; }
    done
    return 1
}

count_lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo "0"; }
merge_unique() { [ -f "$2" ] && sort -u "$1" "$2" -o "$1" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════
#  TUI COMPONENTS
# ════════════════════════════════════════════════════════════════

# ── Animated spinner (background process) ────────────────────────
SPINNER_PID=""
spinner_start() {
    local msg="${1:-Working...}"
    hide_cursor
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r  ${C}${frames[$i]}${NC}  ${DIM}%s${NC}" "$msg"
            i=$(( (i+1) % 10 ))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    if [ -n "$SPINNER_PID" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    clear_line
    show_cursor
}

# ── Horizontal progress bar ───────────────────────────────────────
progress_bar() {
    local cur=$1 tot=$2 lbl="${3:-}"
    local w=38
    local pct=$(( tot > 0 ? cur * 100 / tot : 0 ))
    local fill=$(( pct * w / 100 ))
    local bar="" i
    for ((i=0; i<fill; i++));   do bar+="█"; done
    for ((i=fill; i<w; i++));   do bar+="░"; done
    local col; [ $pct -lt 40 ] && col="$R" || { [ $pct -lt 75 ] && col="$Y" || col="$G"; }
    printf "\r  ${col}[%s]${NC} ${W}%3d%%${NC}  ${DIM}%s${NC}  " "$bar" "$pct" "$lbl"
}

# ── Live findings ticker ──────────────────────────────────────────
findings_ticker() {
    printf "  ${DIM}live findings →${NC}"
    [ "$FINDINGS_CRITICAL" -gt 0 ] && printf "  ${RB}%d CRIT${NC}" "$FINDINGS_CRITICAL"
    [ "$FINDINGS_HIGH" -gt 0 ]     && printf "  ${YB}%d HIGH${NC}" "$FINDINGS_HIGH"
    [ "$FINDINGS_MEDIUM" -gt 0 ]   && printf "  ${Y}%d MED${NC}"  "$FINDINGS_MEDIUM"
    [ "$FINDINGS_LOW" -gt 0 ]      && printf "  ${G}%d LOW${NC}"   "$FINDINGS_LOW"
    [ "$FINDINGS_INFO" -gt 0 ]     && printf "  ${C}%d INFO${NC}"  "$FINDINGS_INFO"
    [ "$FINDINGS_XSS" -gt 0 ]      && printf "  ${MB}%d XSS${NC}"  "$FINDINGS_XSS"
    local total=$(( FINDINGS_CRITICAL+FINDINGS_HIGH+FINDINGS_MEDIUM+FINDINGS_LOW+FINDINGS_INFO ))
    [ "$total" -eq 0 ]             && printf "  ${DIM}none yet${NC}"
    echo ""
}

# ── Phase header banner ───────────────────────────────────────────
phase() {
    local num="$1" title="$2"
    CURRENT_PHASE="$num"
    PHASE_START=$(date +%s)
    echo ""
    echo -e "  ${CB}┌$(printf '─%.0s' {1..52})┐${NC}"
    echo -e "  ${CB}│${NC}  ${W}PHASE ${num}${NC}  ${CB}${title}${NC}$(printf ' %.0s' $(seq 1 $((48 - ${#title} - ${#num}))))${CB}│${NC}"
    echo -ne "  ${CB}│${NC}  "
    findings_ticker | sed 's/^  //' | tr -d '\n'
    printf "%$((52 - $(findings_ticker | wc -c) + 5))s${CB}│${NC}\n" ""
    echo -e "  ${CB}└$(printf '─%.0s' {1..52})┘${NC}"
    echo ""
}

phase() {
    local num="$1" title="$2"
    CURRENT_PHASE="$num"
    PHASE_START=$(date +%s)
    echo ""
    printf "  ${CB}══╡${NC} ${W}PHASE %s${NC} — ${CB}%s${NC}\n" "$num" "$title"
    printf "  "
    findings_ticker
    echo -e "  ${DIM}$(printf '─%.0s' {1..52})${NC}"
    echo ""
}

phase_done() {
    local elapsed=$(( $(date +%s) - PHASE_START ))
    echo ""
    success "Phase $CURRENT_PHASE done — ${elapsed}s"
}

# ── Read a single keypress including arrow keys ───────────────────
read_key() {
    local key
    IFS= read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
        local seq
        read -rsn2 -t 0.15 seq 2>/dev/null || seq=""
        key="${key}${seq}"
    fi
    KEY_RESULT="$key"
}

# ── Arrow-key single-select menu ─────────────────────────────────
# arrow_menu TITLE item1 item2 ...  →  sets MENU_RESULT (0-based index)
MENU_RESULT=0
arrow_menu() {
    local title="$1"; shift
    local items=("$@")
    local n=${#items[@]}
    local sel=0

    hide_cursor
    echo -e "  ${W}${title}${NC}"
    echo ""

    _draw_menu() {
        for i in "${!items[@]}"; do
            if [ "$i" -eq "$sel" ]; then
                echo -e "  ${CB}▶${NC}  ${W}${items[$i]}${NC}"
            else
                echo -e "     ${DIM}${items[$i]}${NC}"
            fi
        done
    }

    _draw_menu

    while true; do
        read_key
        case "$KEY_RESULT" in
            $'\x1b[A') sel=$(( (sel - 1 + n) % n )) ;;   # up
            $'\x1b[B') sel=$(( (sel + 1)     % n )) ;;   # down
            ''|$'\n')  break ;;                           # enter
        esac
        move_up "$n"
        _draw_menu
    done

    show_cursor
    MENU_RESULT=$sel
}

# ── Checkbox multi-select menu ────────────────────────────────────
# checkbox_menu TITLE item1 item2 ... → sets CHECKBOX_RESULT (space-sep indices)
CHECKBOX_RESULT=""
checkbox_menu() {
    local title="$1"; shift
    local items=("$@")
    local n=${#items[@]}
    local cur=0
    local checked=()
    for ((i=0; i<n; i++)); do checked[$i]=1; done

    hide_cursor
    echo -e "  ${W}${title}${NC}  ${DIM}(↑↓ navigate · SPACE toggle · ENTER confirm)${NC}"
    echo ""

    _draw_cb() {
        for i in "${!items[@]}"; do
            local box
            [ "${checked[$i]}" -eq 1 ] && box="${GB}[✓]${NC}" || box="${DIM}[ ]${NC}"
            if [ "$i" -eq "$cur" ]; then
                echo -e "  ${CB}▶${NC}  $box  ${W}${items[$i]}${NC}"
            else
                echo -e "     $box  ${DIM}${items[$i]}${NC}"
            fi
        done
    }

    _draw_cb

    while true; do
        read_key
        case "$KEY_RESULT" in
            $'\x1b[A') cur=$(( (cur - 1 + n) % n )) ;;
            $'\x1b[B') cur=$(( (cur + 1)     % n )) ;;
            ' ')
                [ "${checked[$cur]}" -eq 1 ] && checked[$cur]=0 || checked[$cur]=1
                ;;
            ''|$'\n') break ;;
        esac
        move_up "$n"
        _draw_cb
    done

    show_cursor
    CHECKBOX_RESULT=""
    for i in "${!checked[@]}"; do
        [ "${checked[$i]}" -eq 1 ] && CHECKBOX_RESULT="$CHECKBOX_RESULT $i"
    done
}

# ── Simple input prompt ───────────────────────────────────────────
prompt_input() {
    local label="$1" default="$2"
    # Print prompt to stderr so subshell $() captures only the typed value
    printf "  ${C}?${NC}  ${W}%s${NC} ${DIM}[%s]${NC}: " "$label" "$default" >&2
    local r; read -r r
    echo "${r:-$default}"
}

confirm() {
    local msg="$1" default="${2:-y}"
    local yn
    if [ "$default" = "y" ]; then
        yn="$(echo -e "${W}Y${NC}/${DIM}n${NC}")"
    else
        yn="$(echo -e "${DIM}y${NC}/${W}N${NC}")"
    fi
    echo -ne "  ${Y}?${NC}  ${W}${msg}${NC} ${DIM}(${NC}${yn}${DIM})${NC}: "
    local a; read -r a; a="${a:-$default}"
    [[ "$a" =~ ^[Yy] ]]
}

# ── Tool status table ─────────────────────────────────────────────
show_tool_status() {
    echo ""
    echo -e "  ${W}Installed Tools${NC}"
    echo -e "  ${DIM}$(printf '─%.0s' {1..44})${NC}"
    local tools=(httpx nuclei ffuf subfinder katana naabu dnsx gobuster dalfox gau waybackurls feroxbuster sqlmap nmap nikto whatweb amass)
    local col=0
    for t in "${tools[@]}"; do
        if has_tool "$t"; then
            printf "  ${GB}✓${NC} %-16s" "$t"
        else
            printf "  ${R}✗${NC} ${DIM}%-16s${NC}" "$t"
        fi
        col=$((col+1))
        [ $((col % 3)) -eq 0 ] && echo ""
    done
    [ $((col % 3)) -ne 0 ] && echo ""
    echo ""
}

# ── Overall progress bar (between phases) ────────────────────────
draw_overall_progress() {
    local phase_num="$1"
    local w=36
    local pct=$(( phase_num * 100 / 10 ))
    local fill=$(( pct * w / 100 ))
    local bar="" i
    for ((i=0; i<fill; i++));    do bar+="▓"; done
    for ((i=fill; i<w; i++));    do bar+="░"; done
    echo ""
    printf "  ${DIM}Overall:${NC}  ${C}[%s]${NC}  ${W}%d%%${NC}  ${DIM}Phase %d / 10${NC}\n" "$bar" "$pct" "$phase_num"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#  INTERACTIVE SETUP SCREENS
# ════════════════════════════════════════════════════════════════

draw_banner() {
    clear
    echo ""
    echo -e "  ${RB}  _       _    _              _    ${NC}"
    echo -e "  ${RB} | |__   / |  | |_   ____  _ | |  ${NC}"
    echo -e "  ${RB} | '_ \ | |  | __|  |_  / | || |  ${NC}"
    echo -e "  ${RB} | |_) || |  | |_    / /  | || |  ${NC}"
    echo -e "  ${RB} |_.__/ |_|   \__|  /___|  |_||_|  ${NC}"
    echo ""
    echo -e "  ${CB}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CB}║${NC}   ${W}b1tza Scanner${NC}  ${DIM}—  Interactive Bug Bounty Toolkit${NC}   ${CB}║${NC}"
    echo -e "  ${CB}║${NC}   ${DIM}Authorised penetration testing only  •  v2.0${NC}        ${CB}║${NC}"
    echo -e "  ${CB}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

select_target() {
    echo -e "  ${W}Step 1 of 3 — Enter Target${NC}"
    echo ""
    # Print prompt to stderr — keeps TARGET clean of escape codes
    printf "  ${C}▶${NC}  ${W}Target domain:${NC} " >&2
    read -r TARGET </dev/tty
    TARGET="${TARGET:-}"

    # Strip protocol and any stray ANSI escape codes
    TARGET=$(echo "$TARGET" | sed 's|https\?://||' | cut -d'/' -f1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\033' | xargs)

    if [ -z "$TARGET" ]; then
        error "No target entered. Exiting."
        exit 1
    fi

    echo ""
    echo -e "  ${YB}⚠  Only scan targets you own or have written authorisation to test.${NC}"
    echo ""
    printf "  ${Y}?${NC}  ${W}I confirm I have written authorisation to scan${NC} ${CB}%s${NC} ${DIM}(y/N)${NC}: " "$TARGET"
    local a; read -r a
    if [[ ! "$a" =~ ^[Yy] ]]; then
        error "Scan cancelled — authorisation not confirmed"
        exit 1
    fi

    echo ""
    # Final sanitise — guarantee TARGET is a clean domain string
    TARGET=$(printf '%s' "$TARGET" | sed 's/[[:cntrl:]]//g' | xargs)
    success "Target set: $TARGET"
}

select_scan_mode() {
    echo ""
    echo -e "  ${W}Step 2 of 3 — Scan Mode${NC}"
    echo ""

    arrow_menu "Choose scan mode:" \
        "⚡  Quick       httpx + nuclei only  (~5 min)" \
        "🔍  Full        All 10 phases        (~30-60 min)" \
        "🎛   Custom      Choose phases manually" \
        "📋  Tool check  See what's installed"

    echo ""
    case $MENU_RESULT in
        0)
            SCAN_MODE="quick"
            for k in "${!PHASE_ENABLED[@]}"; do PHASE_ENABLED[$k]=0; done
            PHASE_ENABLED[1]=1; PHASE_ENABLED[3]=1; PHASE_ENABLED[9]=1
            success "Mode: Quick Scan (passive recon + live hosts + nuclei)"
            ;;
        1)
            SCAN_MODE="full"
            for k in "${!PHASE_ENABLED[@]}"; do PHASE_ENABLED[$k]=1; done
            success "Mode: Full Scan — all 10 phases"
            ;;
        2)
            SCAN_MODE="custom"
            echo ""
            local pnames=(
                "Phase 1  — Passive Recon       (DNS, WHOIS, crt.sh, Wayback)"
                "Phase 2  — Subdomain Enum       (subfinder, amass, dnsx)"
                "Phase 3  — Live Host Detection  (httpx)"
                "Phase 4  — Port Scanning        (naabu, nmap)"
                "Phase 5  — Tech Fingerprinting  (whatweb)"
                "Phase 6  — Directory Fuzzing    (ffuf, feroxbuster)"
                "Phase 7  — URL Harvesting       (gau, waybackurls, katana)"
                "Phase 8  — XSS Scanning         (dalfox)"
                "Phase 9  — Vulnerability Scan   (nuclei)"
                "Phase 10 — SQL Injection        (sqlmap)"
            )
            checkbox_menu "Select phases to include:" "${pnames[@]}"
            echo ""
            for k in "${!PHASE_ENABLED[@]}"; do PHASE_ENABLED[$k]=0; done
            for i in $CHECKBOX_RESULT; do PHASE_ENABLED[$((i+1))]=1; done
            local enabled_str=""
            for k in $(echo "${!PHASE_ENABLED[@]}" | tr ' ' '\n' | sort -n); do
                [ "${PHASE_ENABLED[$k]}" -eq 1 ] && enabled_str="$enabled_str $k"
            done
            success "Custom phases selected:$enabled_str"
            ;;
        3)
            show_tool_status
            select_scan_mode
            return
            ;;
    esac
}

configure_scan() {
    echo ""
    echo -e "  ${W}Step 3 of 3 — Scan Configuration${NC}"
    echo ""

    arrow_menu "Request rate limit (req/sec):" \
        "🐢  25   Conservative — safest for shared/prod servers" \
        "⚡  50   Normal       — recommended (default)" \
        "🚀  100  Aggressive   — fast, for dedicated dev servers"
    case $MENU_RESULT in
        0) RATE_LIMIT=25 ;; 1) RATE_LIMIT=50 ;; 2) RATE_LIMIT=100 ;;
    esac
    echo ""
    success "Rate limit: ${RATE_LIMIT} req/s"

    echo ""
    arrow_menu "Thread count:" \
        "5   Low resource  — lightweight VPS" \
        "10  Balanced      — recommended" \
        "25  High          — beefy server only"
    case $MENU_RESULT in
        0) THREADS=5 ;; 1) THREADS=10 ;; 2) THREADS=25 ;;
    esac
    echo ""
    success "Threads: $THREADS"
}

confirm_scan() {
    echo ""
    echo -e "  ${W}$(printf '═%.0s' {1..52})${NC}"
    echo -e "  ${W}  READY TO SCAN — Review and confirm${NC}"
    echo -e "  ${W}$(printf '═%.0s' {1..52})${NC}"
    echo ""
    echo -e "  ${DIM}Target     ${NC}  ${GB}$TARGET${NC}"
    echo -e "  ${DIM}Mode       ${NC}  ${W}$SCAN_MODE${NC}"
    echo -e "  ${DIM}Rate       ${NC}  ${W}${RATE_LIMIT} req/s${NC}"
    echo -e "  ${DIM}Threads    ${NC}  ${W}$THREADS${NC}"
    echo -e "  ${DIM}Output     ${NC}  ${DIM}$OUT${NC}"
    echo ""
    echo -e "  ${DIM}Phases:${NC}"
    local pnames=("" "Passive Recon" "Subdomain Enum" "Live Hosts" "Port Scan" "Tech Fingerprint" "Dir Fuzzing" "URL Harvest" "XSS Scan" "Nuclei" "SQLi")
    for k in $(echo "${!PHASE_ENABLED[@]}" | tr ' ' '\n' | sort -n); do
        if [ "${PHASE_ENABLED[$k]}" -eq 1 ]; then
            echo -e "    ${GB}✓${NC}  ${pnames[$k]}"
        else
            echo -e "    ${DIM}✗  ${pnames[$k]}${NC}"
        fi
    done
    echo ""
    echo -e "  ${YB}⚠  Only test targets you own or have written permission for.${NC}"
    echo ""
    confirm "Start scan?" "y" || { warn "Scan cancelled."; exit 0; }
    echo ""
    success "Launching scan..."
    sleep 0.4
}

# ════════════════════════════════════════════════════════════════
#  SCAN PHASES
# ════════════════════════════════════════════════════════════════

update_findings() {
    local f="${1:-}"; [ ! -f "$f" ] && return
    FINDINGS_CRITICAL=$(python3 -c "import json;print(sum(1 for l in open('$f') if json.loads(l).get('info',{}).get('severity')=='critical'))" 2>/dev/null || echo 0)
    FINDINGS_HIGH=$(python3     -c "import json;print(sum(1 for l in open('$f') if json.loads(l).get('info',{}).get('severity')=='high'))"     2>/dev/null || echo 0)
    FINDINGS_MEDIUM=$(python3   -c "import json;print(sum(1 for l in open('$f') if json.loads(l).get('info',{}).get('severity')=='medium'))"   2>/dev/null || echo 0)
    FINDINGS_LOW=$(python3      -c "import json;print(sum(1 for l in open('$f') if json.loads(l).get('info',{}).get('severity')=='low'))"       2>/dev/null || echo 0)
    FINDINGS_INFO=$(python3     -c "import json;print(sum(1 for l in open('$f') if json.loads(l).get('info',{}).get('severity')=='info'))"      2>/dev/null || echo 0)
}

run_preflight() {
    phase "0" "Preflight"
    export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin"
    export GOPATH="$HOME/go"
    mkdir -p "$OUT"/{passive,subdomains,hosts,ports,tech,fuzz,urls,vulns,sqli,report}
    touch "$LOG"

    if [ ! -f "$WORDLIST_SMALL" ]; then
        spinner_start "Downloading fallback wordlist..."
        mkdir -p "$HOME/wordlists"
        wget -q "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/common.txt" \
            -O "$WORDLIST_SMALL" 2>/dev/null || true
        spinner_stop; success "Wordlist downloaded"
    fi
    [ ! -f "$WORDLIST_MEDIUM" ] && WORDLIST_MEDIUM="$WORDLIST_SMALL"
    [ ! -f "$WORDLIST_SUBS" ]   && WORDLIST_SUBS="$WORDLIST_SMALL"

    local missing=()
    for t in httpx nuclei ffuf nmap; do has_tool "$t" || missing+=("$t"); done
    [ ${#missing[@]} -gt 0 ] && warn "Missing tools: ${missing[*]}" || success "All critical tools present"
    SCAN_START=$(date +%s)
    phase_done
}

run_passive() {
    [ "${PHASE_ENABLED[1]:-0}" -eq 0 ] && return
    phase "1" "Passive Recon — DNS, WHOIS, crt.sh, Wayback"
    local P="$OUT/passive"

    spinner_start "DNS records (A MX TXT NS CNAME)..."
    for t in A AAAA MX TXT NS CNAME SOA; do
        dig "$TARGET" "$t" +short 2>/dev/null >> "$P/dns_${t}.txt" || true
    done
    spinner_stop; success "DNS records saved"

    command -v whois &>/dev/null && {
        spinner_start "WHOIS lookup..."
        whois "$TARGET" > "$P/whois.txt" 2>/dev/null || true
        spinner_stop; success "WHOIS complete"
    }

    spinner_start "crt.sh certificate transparency..."
    curl -s "https://crt.sh/?q=%25.$TARGET&output=json" 2>/dev/null | python3 -c "
import sys,json
try:
    data=json.load(sys.stdin)
    names=set()
    for e in data:
        for n in e.get('name_value','').split('\n'):
            n=n.strip().lstrip('*.').lower()
            if n and '.' in n: names.add(n)
    [print(n) for n in sorted(names)]
except: pass
" > "$P/crtsh.txt" 2>/dev/null || true
    spinner_stop; success "crt.sh: $(count_lines "$P/crtsh.txt") subdomains found"
    cp "$P/crtsh.txt" "$OUT/subdomains/seed.txt" 2>/dev/null || true

    spinner_start "Wayback Machine archive..."
    curl -s "http://web.archive.org/cdx/search/cdx?url=$TARGET/*&output=text&fl=original&collapse=urlkey&limit=200" \
        > "$P/wayback.txt" 2>/dev/null || true
    spinner_stop; success "Wayback: $(count_lines "$P/wayback.txt") historical URLs"
    phase_done
}

run_subdomains() {
    [ "${PHASE_ENABLED[2]:-0}" -eq 0 ] && return
    phase "2" "Subdomain Enumeration"
    local P="$OUT/subdomains"
    echo "$TARGET" > "$P/all.txt"

    has_tool subfinder && {
        spinner_start "subfinder passive enum..."
        run_tool subfinder -d "$TARGET" -silent -o "$P/subfinder.txt" 2>/dev/null || true
        spinner_stop; success "subfinder: $(count_lines "$P/subfinder.txt") subdomains"
        merge_unique "$P/all.txt" "$P/subfinder.txt"
    } || skip "subfinder"

    has_tool amass && {
        spinner_start "amass passive (may take a while)..."
        run_tool amass enum -passive -d "$TARGET" -o "$P/amass.txt" 2>/dev/null || true
        spinner_stop; success "amass: $(count_lines "$P/amass.txt") subdomains"
        merge_unique "$P/all.txt" "$P/amass.txt"
    } || skip "amass"

    merge_unique "$P/all.txt" "$P/seed.txt"

    has_tool dnsx && [ -f "$WORDLIST_SUBS" ] && {
        spinner_start "DNS bruteforce with dnsx..."
        awk -v t="$TARGET" '{print $1"."t}' "$WORDLIST_SUBS" > "$P/cands.txt"
        run_tool dnsx -l "$P/cands.txt" -silent -o "$P/dnsx.txt" 2>/dev/null || true
        spinner_stop; success "dnsx brute: $(count_lines "$P/dnsx.txt") live"
        merge_unique "$P/all.txt" "$P/dnsx.txt"
    } || skip "dnsx"

    sort -u "$P/all.txt" -o "$P/all.txt"
    success "Total unique hosts: $(count_lines "$P/all.txt")"
    phase_done
}

run_live_hosts() {
    [ "${PHASE_ENABLED[3]:-0}" -eq 0 ] && return
    phase "3" "Live Host Detection — httpx"
    local P="$OUT/hosts"
    local sf="$OUT/subdomains/all.txt"
    [ ! -f "$sf" ] && echo "$TARGET" > "$sf"

    if ! has_tool httpx; then
        skip "httpx not found"
        echo "https://$TARGET" > "$P/live_urls.txt"
        echo "$TARGET"         > "$P/live_hosts.txt"
        phase_done; return
    fi

    local total; total=$(count_lines "$sf")
    log "Probing $total hosts with httpx..."

    run_tool httpx -l "$sf" -title -tech-detect -status-code -tls-grab -server \
        -follow-redirects -rate-limit "$RATE_LIMIT" -threads "$THREADS" \
        -json -o "$P/httpx.json" -silent 2>/dev/null &
    local pid=$!

    hide_cursor
    local dots=0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    while kill -0 $pid 2>/dev/null; do
        local found=0; [ -f "$P/httpx.json" ] && found=$(count_lines "$P/httpx.json")
        printf "\r  ${C}${frames[$((dots%10))]}${NC}  Probing...  ${GB}%d live${NC} found" "$found"
        dots=$((dots+1)); sleep 0.2
    done
    wait $pid 2>/dev/null || true
    clear_line; show_cursor

    [ -f "$P/httpx.json" ] && python3 -c "
import json
urls=[]
for line in open('$P/httpx.json'):
    try:
        d=json.loads(line.strip())
        d.get('url') and urls.append(d['url'])
    except: pass
print('\n'.join(sorted(set(urls))))
" > "$P/live_urls.txt" 2>/dev/null || true

    echo "$TARGET"         >> "$P/live_hosts.txt" 2>/dev/null || true
    echo "https://$TARGET" >> "$P/live_urls.txt"  2>/dev/null || true
    sort -u "$P/live_urls.txt"  -o "$P/live_urls.txt"  2>/dev/null || true
    sort -u "$P/live_hosts.txt" -o "$P/live_hosts.txt" 2>/dev/null || true

    success "$(count_lines "$P/live_urls.txt") live URLs detected"
    phase_done
}

run_ports() {
    [ "${PHASE_ENABLED[4]:-0}" -eq 0 ] && return
    phase "4" "Port Scanning — naabu + nmap"
    local P="$OUT/ports"
    local hf="$OUT/hosts/live_hosts.txt"
    [ ! -f "$hf" ] && echo "$TARGET" > "$hf"

    has_tool naabu && {
        spinner_start "naabu fast scan (top 1000 ports)..."
        run_tool naabu -l "$hf" -top-ports 1000 -silent -json -o "$P/naabu.json" -rate 300 2>/dev/null || true
        spinner_stop; success "naabu complete"
    } || skip "naabu"

    has_tool nmap && {
        spinner_start "nmap service detection..."
        nmap -sV -sC --open -T4 -p 21,22,25,53,80,443,3306,5432,6379,8080,8443,9200,27017 \
            "$TARGET" -oN "$P/nmap.txt" -oX "$P/nmap.xml" 2>/dev/null || true
        spinner_stop; success "nmap complete"
        grep "open" "$P/nmap.txt" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG" || true
    } || skip "nmap"
    phase_done
}

run_tech() {
    [ "${PHASE_ENABLED[5]:-0}" -eq 0 ] && return
    phase "5" "Technology Fingerprinting"
    local P="$OUT/tech"
    local uf="$OUT/hosts/live_urls.txt"
    [ ! -f "$uf" ] && echo "https://$TARGET" > "$uf"

    has_tool whatweb && {
        spinner_start "whatweb fingerprinting..."
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            whatweb --color=never -a 3 "$u" >> "$P/whatweb.txt" 2>/dev/null || true
        done < "$uf"
        spinner_stop; success "whatweb complete"
    } || skip "whatweb"

    [ -f "$OUT/hosts/httpx.json" ] && python3 -c "
import json
for line in open('$OUT/hosts/httpx.json'):
    try:
        d=json.loads(line.strip())
        t=d.get('technologies') or d.get('tech',[])
        if t: print(f\"{d.get('url','')}: {' | '.join(t)}\")
    except: pass
" > "$P/tech_stack.txt" 2>/dev/null && cat "$P/tech_stack.txt" | sed 's/^/  /' || true
    phase_done
}

run_fuzz() {
    [ "${PHASE_ENABLED[6]:-0}" -eq 0 ] && return
    phase "6" "Directory & Endpoint Fuzzing — ffuf + feroxbuster"
    local P="$OUT/fuzz"
    local uf="$OUT/hosts/live_urls.txt"
    [ ! -f "$uf" ] && echo "https://$TARGET" > "$uf"

    has_tool ffuf && [ -f "$WORDLIST_MEDIUM" ] && {
        local total; total=$(count_lines "$uf")
        local done_n=0
        while IFS= read -r url; do
            [ -z "$url" ] && continue
            done_n=$((done_n+1))
            local sn; sn=$(echo "$url" | sed 's|https\?://||;s|/|_|g')
            progress_bar "$done_n" "$total" "ffuf → ${url:0:40}"
            run_tool ffuf -u "${url}/FUZZ" -w "$WORDLIST_MEDIUM" \
                -mc 200,201,204,301,302,307,401,403 \
                -o "$P/ffuf_${sn}.json" -of json \
                -t "$THREADS" -rate "$RATE_LIMIT" -timeout 10 -silent 2>/dev/null || true
        done < "$uf"
        clear_line; success "ffuf complete on $done_n target(s)"
    } || skip "ffuf"

    has_tool feroxbuster && {
        spinner_start "feroxbuster recursive scan (depth 3)..."
        run_tool feroxbuster --url "https://$TARGET" --wordlist "$WORDLIST_MEDIUM" \
            --threads "$THREADS" --rate-limit "$RATE_LIMIT" --depth 3 \
            --status-codes 200,201,204,301,302,307,401,403 \
            --output "$P/ferox.txt" --no-state --quiet 2>/dev/null || true
        spinner_stop; success "feroxbuster complete"
    } || skip "feroxbuster"

    {
        find "$P" -name "ffuf_*.json" 2>/dev/null | while read -r f; do
            python3 -c "
import json,pathlib
try:
    d=json.loads(pathlib.Path('$f').read_text())
    [print(r.get('url','')) for r in d.get('results',[])]
except: pass
" 2>/dev/null
        done
        grep -h "^https\?://" "$P/ferox.txt" 2>/dev/null || true
    } | sort -u > "$P/all_paths.txt"

    success "Total unique paths: $(count_lines "$P/all_paths.txt")"
    phase_done
}

run_harvest() {
    [ "${PHASE_ENABLED[7]:-0}" -eq 0 ] && return
    phase "7" "URL Harvesting — gau + waybackurls + katana"
    local P="$OUT/urls"

    has_tool gau && {
        spinner_start "gau — pulling known URLs from archives..."
        echo "$TARGET" | run_tool gau --threads "$THREADS" --retries 2 --timeout 15 \
            --o "$P/gau.txt" 2>/dev/null || true
        spinner_stop; success "gau: $(count_lines "$P/gau.txt") URLs"
    } || skip "gau"

    has_tool waybackurls && {
        spinner_start "waybackurls — Wayback Machine..."
        echo "$TARGET" | run_tool waybackurls > "$P/wayback.txt" 2>/dev/null || true
        spinner_stop; success "waybackurls: $(count_lines "$P/wayback.txt") URLs"
    } || skip "waybackurls"

    has_tool katana && {
        spinner_start "katana active crawl (depth 3)..."
        run_tool katana -u "https://$TARGET" -depth 3 -jc -silent \
            -o "$P/katana.txt" -rate-limit "$RATE_LIMIT" -timeout 15 2>/dev/null || true
        spinner_stop; success "katana: $(count_lines "$P/katana.txt") URLs"
    } || skip "katana"

    cat "$P"/*.txt 2>/dev/null | sort -u > "$P/all.txt" || true
    grep "?" "$P/all.txt" 2>/dev/null | sort -u > "$P/params.txt" || true
    grep -iE "\.js(\?|$)" "$P/all.txt" 2>/dev/null | sort -u > "$P/js.txt" || true

    success "$(count_lines "$P/all.txt") total URLs | $(count_lines "$P/params.txt") with params | $(count_lines "$P/js.txt") JS files"
    phase_done
}

run_xss() {
    [ "${PHASE_ENABLED[8]:-0}" -eq 0 ] && return
    phase "8" "XSS Scanning — dalfox"
    local P="$OUT/vulns"
    local pf="$OUT/urls/params.txt"

    has_tool dalfox || { skip "dalfox not installed"; phase_done; return; }
    [ "$(count_lines "$pf")" -eq 0 ] && { skip "No parameterised URLs found"; phase_done; return; }

    log "Testing $(count_lines "$pf") parameterised URLs for XSS..."
    run_tool dalfox file "$pf" --silence --no-color \
        --output "$P/dalfox.txt" --timeout 10 --delay 200 --worker "$THREADS" 2>/dev/null &
    local pid=$!

    hide_cursor
    local dots=0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    while kill -0 $pid 2>/dev/null; do
        local found=0
        [ -f "$P/dalfox.txt" ] && found=$(grep -c "\[V\]" "$P/dalfox.txt" 2>/dev/null || echo 0)
        printf "\r  ${C}${frames[$((dots%10))]}${NC}  Testing XSS...  ${MB}%d confirmed${NC}" "$found"
        dots=$((dots+1)); sleep 0.2
    done
    wait $pid 2>/dev/null || true
    clear_line; show_cursor

    FINDINGS_XSS=$(grep -c "\[V\]" "$P/dalfox.txt" 2>/dev/null || echo 0)
    [ "$FINDINGS_XSS" -gt 0 ] \
        && warn "${MB}XSS: $FINDINGS_XSS confirmed findings${NC}" \
        || success "No confirmed XSS"
    phase_done
}

run_nuclei() {
    [ "${PHASE_ENABLED[9]:-0}" -eq 0 ] && return
    phase "9" "Vulnerability Scanning — nuclei"
    local P="$OUT/vulns"
    local uf="$OUT/hosts/live_urls.txt"
    [ ! -f "$uf" ] && echo "https://$TARGET" > "$uf"

    has_tool nuclei || { skip "nuclei not installed"; phase_done; return; }

    spinner_start "Updating nuclei templates..."
    run_tool nuclei -update-templates -silent 2>/dev/null || true
    spinner_stop; success "Templates updated"

    log "Scanning $(count_lines "$uf") URL(s)..."

    run_tool nuclei -l "$uf" \
        -severity critical,high,medium,low,info \
        -tags cve,misconfig,exposure,takeover,token,default-login,panel,tech,sqli,xss \
        -rate-limit "$RATE_LIMIT" -bulk-size 25 -concurrency "$THREADS" \
        -timeout 10 -retries 1 \
        -json-export "$P/nuclei.json" -o "$P/nuclei.txt" -silent 2>/dev/null &
    local pid=$!

    hide_cursor
    local dots=0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    while kill -0 $pid 2>/dev/null; do
        update_findings "$P/nuclei.json"
        printf "\r  ${C}${frames[$((dots%10))]}${NC}  Scanning..."
        [ "$FINDINGS_CRITICAL" -gt 0 ] && printf "  ${RB}%d CRIT${NC}" "$FINDINGS_CRITICAL"
        [ "$FINDINGS_HIGH" -gt 0 ]     && printf "  ${YB}%d HIGH${NC}" "$FINDINGS_HIGH"
        [ "$FINDINGS_MEDIUM" -gt 0 ]   && printf "  ${Y}%d MED${NC}"  "$FINDINGS_MEDIUM"
        [ "$FINDINGS_LOW" -gt 0 ]      && printf "  ${G}%d LOW${NC}"   "$FINDINGS_LOW"
        dots=$((dots+1)); sleep 0.3
    done
    wait $pid 2>/dev/null || true
    clear_line; show_cursor
    update_findings "$P/nuclei.json"

    echo ""
    [ "$FINDINGS_CRITICAL" -gt 0 ] && echo -e "  ${RB}CRITICAL: $FINDINGS_CRITICAL${NC}"
    [ "$FINDINGS_HIGH" -gt 0 ]     && echo -e "  ${YB}HIGH:     $FINDINGS_HIGH${NC}"
    [ "$FINDINGS_MEDIUM" -gt 0 ]   && echo -e "  ${Y}MEDIUM:   $FINDINGS_MEDIUM${NC}"
    [ "$FINDINGS_LOW" -gt 0 ]      && echo -e "  ${G}LOW:      $FINDINGS_LOW${NC}"
    [ "$FINDINGS_INFO" -gt 0 ]     && echo -e "  ${C}INFO:     $FINDINGS_INFO${NC}"
    phase_done
}

run_sqli() {
    [ "${PHASE_ENABLED[10]:-0}" -eq 0 ] && return
    phase "10" "SQL Injection — sqlmap"
    local P="$OUT/sqli"
    local pf="$OUT/urls/params.txt"

    has_tool sqlmap || { skip "sqlmap not installed"; phase_done; return; }
    [ "$(count_lines "$pf")" -eq 0 ] && { skip "No parameterised URLs found"; phase_done; return; }

    head -20 "$pf" > "$P/targets.txt"
    log "Testing $(count_lines "$P/targets.txt") URLs for SQL injection..."
    spinner_start "sqlmap batch scan..."
    sqlmap -m "$P/targets.txt" --batch --level=2 --risk=1 \
        --threads="$THREADS" --timeout=10 --retries=1 \
        --output-dir="$P/output" --forms --crawl=2 --random-agent --quiet 2>/dev/null || true
    spinner_stop; success "sqlmap complete — see sqli/output/"
    phase_done
}

run_report() {
    phase "11" "Report Generation"
    local P="$OUT/report"
    local elapsed=$(( $(date +%s) - SCAN_START ))
    local dur; dur=$(printf '%02dh %02dm %02ds' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))

    spinner_start "Compiling results into HTML report..."

    local subs total_u live op nf xf
    subs=$(count_lines "$OUT/subdomains/all.txt")
    total_u=$(count_lines "$OUT/urls/all.txt")
    live=$(count_lines "$OUT/hosts/live_urls.txt")
    op=$(count_lines "$OUT/fuzz/all_paths.txt")
    nf=$([ -f "$OUT/vulns/nuclei.json" ] && wc -l < "$OUT/vulns/nuclei.json" || echo 0)
    xf=$([ -f "$OUT/vulns/dalfox.txt"  ] && grep -c "\[V\]" "$OUT/vulns/dalfox.txt" 2>/dev/null || echo 0)

    local crit=$FINDINGS_CRITICAL high=$FINDINGS_HIGH med=$FINDINGS_MEDIUM
    local low=$FINDINGS_LOW info=$FINDINGS_INFO

    local nrows=""
    [ -f "$OUT/vulns/nuclei.json" ] && nrows=$(python3 -c "
import json,html
order={'critical':0,'high':1,'medium':2,'low':3,'info':4}
findings=[]
try:
    for line in open('$OUT/vulns/nuclei.json'):
        try: findings.append(json.loads(line))
        except: pass
except: pass
findings.sort(key=lambda x:order.get(x.get('info',{}).get('severity','info'),4))
rows=[]
for f in findings:
    sev=f.get('info',{}).get('severity','info')
    name=html.escape(f.get('info',{}).get('name',''))
    desc=html.escape((f.get('info',{}).get('description','') or '')[:120])
    url=html.escape(f.get('matched-at','') or f.get('host',''))
    tid=html.escape(f.get('template-id',''))
    rows.append(f'<tr><td><span class=\"badge badge-{sev}\">{sev.upper()}</span></td><td style=\"font-family:monospace;font-size:11px\">{tid}</td><td>{name}</td><td style=\"font-size:11px;word-break:break-all\">{url}</td><td style=\"font-size:12px\">{desc}</td></tr>')
print(''.join(rows))
" 2>/dev/null) || true

    local frows=""
    [ -f "$OUT/fuzz/all_paths.txt" ] && frows=$(head -100 "$OUT/fuzz/all_paths.txt" | python3 -c "
import sys,html
for l in sys.stdin:
    u=html.escape(l.strip())
    if u: print(f'<tr><td style=\"font-family:monospace;font-size:12px\">{u}</td></tr>')
" 2>/dev/null) || true

    # Sanitise TARGET for HTML output — strip any stray escape codes
    local CLEAN_TARGET
    CLEAN_TARGET=$(echo "$TARGET" | sed 's/\x1b\[[0-9;]*[mK]//g' | tr -d '\001-\037' | xargs)
    cat > "$P/report.html" << HTMLEOF
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Security Report — ${TARGET}</title>
<style>
:root{--bg:#060910;--sf:#0d1117;--br:#21262d;--tx:#c9d1d9;--dm:#484f58;--ac:#58a6ff;--cr:#ff7b72;--hi:#ffa657;--me:#e3b341;--lo:#3fb950;--in:#58a6ff}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Courier New',monospace;background:var(--bg);color:var(--tx);padding:40px 48px;line-height:1.6}
h1{font-size:24px;color:var(--ac);border-bottom:1px solid var(--br);padding-bottom:16px;margin-bottom:8px}
h2{font-size:14px;color:#79c0ff;margin:40px 0 16px;padding-bottom:8px;border-bottom:1px solid var(--br);letter-spacing:1px;text-transform:uppercase}
.meta{color:var(--dm);font-size:13px;margin-bottom:32px}.meta span{color:var(--tx)}
.grid{display:grid;grid-template-columns:repeat(6,1fr);gap:12px;margin:24px 0 40px}
.card{background:var(--sf);border:1px solid var(--br);border-radius:10px;padding:20px 16px;text-align:center}
.card .num{font-size:30px;font-weight:900;line-height:1}.card .lbl{font-size:10px;color:var(--dm);margin-top:6px;letter-spacing:1px}
.card.c .num{color:var(--cr)}.card.h .num{color:var(--hi)}.card.m .num{color:var(--me)}.card.l .num{color:var(--lo)}.card.i .num{color:var(--in)}.card.n .num{color:#79c0ff}
table{width:100%;border-collapse:collapse;font-size:13px;margin-bottom:8px}
th{background:var(--sf);color:#79c0ff;padding:10px 12px;text-align:left;border:1px solid var(--br);font-size:11px;text-transform:uppercase}
td{padding:9px 12px;border:1px solid var(--br);vertical-align:top}
tr:nth-child(even) td{background:#0a0e14}
.badge{display:inline-block;padding:2px 7px;border-radius:3px;font-size:10px;font-weight:bold}
.badge-critical{background:#2d0f0f;color:var(--cr);border:1px solid var(--cr)}
.badge-high{background:#2d1a06;color:var(--hi);border:1px solid var(--hi)}
.badge-medium{background:#2d2206;color:var(--me);border:1px solid var(--me)}
.badge-low{background:#082d0f;color:var(--lo);border:1px solid var(--lo)}
.badge-info{background:#071a2d;color:var(--in);border:1px solid var(--in)}
.alert{background:#1a0a0a;border:1px solid var(--cr);border-radius:8px;padding:14px 18px;margin:20px 0;color:var(--cr);font-size:13px}
.ok{background:#081a0a;border:1px solid var(--lo);border-radius:8px;padding:14px 18px;margin:20px 0;color:var(--lo);font-size:13px}
footer{margin-top:60px;padding-top:20px;border-top:1px solid var(--br);font-size:11px;color:var(--dm)}
pre{background:var(--sf);border:1px solid var(--br);border-radius:6px;padding:14px;font-size:11px;overflow-x:auto;white-space:pre-wrap}
</style></head><body>
<h1>🔐 Security Assessment Report</h1>
<div class="meta">Target: <span>${TARGET}</span> &nbsp;·&nbsp; Date: <span>$(date '+%Y-%m-%d %H:%M UTC')</span> &nbsp;·&nbsp; Duration: <span>${dur}</span> &nbsp;·&nbsp; Scope: <span>Authorised</span></div>
<h2>Executive Summary</h2>
<div class="grid">
<div class="card n"><div class="num">${live}</div><div class="lbl">LIVE HOSTS</div></div>
<div class="card n"><div class="num">${subs}</div><div class="lbl">SUBDOMAINS</div></div>
<div class="card n"><div class="num">${op}</div><div class="lbl">OPEN PATHS</div></div>
<div class="card c"><div class="num">${crit}</div><div class="lbl">CRITICAL</div></div>
<div class="card h"><div class="num">${high}</div><div class="lbl">HIGH</div></div>
<div class="card m"><div class="num">${med}</div><div class="lbl">MEDIUM</div></div>
</div>
$([ "$crit" -gt 0 ] && echo '<div class="alert">⚠  CRITICAL vulnerabilities found — remediate before production</div>' || echo '<div class="ok">✓ No critical vulnerabilities found</div>')
<h2>Vulnerability Findings</h2>
$([ -n "$nrows" ] && echo "<table><tr><th>Severity</th><th>Template</th><th>Name</th><th>URL</th><th>Description</th></tr>${nrows}</table>" || echo '<p style="color:var(--lo);font-size:13px">✓ No vulnerabilities detected</p>')
<h2>Discovered Paths</h2>
$([ -n "$frows" ] && echo "<table><tr><th>URL</th></tr>${frows}</table>" || echo '<p style="color:var(--dm);font-size:13px">None found</p>')
<h2>Live Hosts</h2><pre>$(cat "$OUT/hosts/live_urls.txt" 2>/dev/null || echo "none")</pre>
<h2>Subdomains</h2><pre>$(cat "$OUT/subdomains/all.txt" 2>/dev/null || echo "none")</pre>
<h2>Tech Stack</h2><pre>$(cat "$OUT/tech/tech_stack.txt" 2>/dev/null || echo "none")</pre>
<footer>SCAN.SH Interactive Bug Bounty Scanner &nbsp;·&nbsp; ${TARGET} &nbsp;·&nbsp; Authorised only &nbsp;·&nbsp; $(date '+%Y-%m-%d')</footer>
</body></html>
HTMLEOF

    python3 -c "
import json
print(json.dumps({'target':'$TARGET','date':'$(date -u +%Y-%m-%dT%H:%M:%SZ)','duration':'$dur',
'stats':{'live':$live,'subdomains':$subs,'urls':$total_u,'paths':$op},
'severity':{'critical':$crit,'high':$high,'medium':$med,'low':$low,'info':$info,'xss':$xf}},indent=2))
" > "$P/summary.json" 2>/dev/null || true

    spinner_stop
    success "report/report.html"
    success "report/summary.json"
    phase_done
}

# ════════════════════════════════════════════════════════════════
#  FINAL SUMMARY
# ════════════════════════════════════════════════════════════════

final_summary() {
    local elapsed=$(( $(date +%s) - SCAN_START ))
    local dur; dur=$(printf '%02dh %02dm %02ds' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))

    clear
    echo ""
    echo -e "  ${GB}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GB}║  ✓  SCAN COMPLETE                                    ║${NC}"
    echo -e "  ${GB}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}Target:${NC}      ${GB}$TARGET${NC}"
    echo -e "  ${DIM}Duration:${NC}    ${W}$dur${NC}"
    echo -e "  ${DIM}Live hosts:${NC}  ${W}$(count_lines "$OUT/hosts/live_urls.txt")${NC}"
    echo -e "  ${DIM}Subdomains:${NC}  ${W}$(count_lines "$OUT/subdomains/all.txt")${NC}"
    echo -e "  ${DIM}Paths found:${NC} ${W}$(count_lines "$OUT/fuzz/all_paths.txt")${NC}"
    echo ""
    echo -e "  ${W}Findings:${NC}"
    local total=$(( FINDINGS_CRITICAL+FINDINGS_HIGH+FINDINGS_MEDIUM+FINDINGS_LOW+FINDINGS_INFO ))
    [ "$FINDINGS_CRITICAL" -gt 0 ] && echo -e "    ${RB}⚠  CRITICAL  $FINDINGS_CRITICAL${NC}"
    [ "$FINDINGS_HIGH" -gt 0 ]     && echo -e "    ${YB}   HIGH      $FINDINGS_HIGH${NC}"
    [ "$FINDINGS_MEDIUM" -gt 0 ]   && echo -e "    ${Y}   MEDIUM    $FINDINGS_MEDIUM${NC}"
    [ "$FINDINGS_LOW" -gt 0 ]      && echo -e "    ${G}   LOW       $FINDINGS_LOW${NC}"
    [ "$FINDINGS_INFO" -gt 0 ]     && echo -e "    ${C}   INFO      $FINDINGS_INFO${NC}"
    [ "$FINDINGS_XSS" -gt 0 ]      && echo -e "    ${MB}   XSS       $FINDINGS_XSS${NC}"
    [ "$total" -eq 0 ]             && echo -e "    ${G}✓  Clean — no vulnerabilities found${NC}"
    echo ""
    echo -e "  ${W}Output:${NC}  ${C}$OUT/${NC}"
    echo ""
    echo -e "  ${DIM}├──${NC} ${C}report/report.html${NC}   ${DIM}← open in browser${NC}"
    echo -e "  ${DIM}├──${NC} ${C}report/summary.json${NC}  ${DIM}← compliance pack${NC}"
    echo -e "  ${DIM}├──${NC} ${C}vulns/nuclei.json${NC}"
    echo -e "  ${DIM}└──${NC} ${C}scan.log${NC}"
    echo ""

    if command -v xdg-open &>/dev/null; then
        if confirm "Open HTML report in browser?" "y"; then
            xdg-open "$OUT/report/report.html" 2>/dev/null &
        fi
    fi

    echo ""
}

# ════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════
main() {
    export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin"
    export GOPATH="$HOME/go"

    draw_banner

    select_target
    select_scan_mode
    configure_scan

    OUT="$BASE_DIR/${TARGET}_${TIMESTAMP}"
    LOG="$OUT/scan.log"
    mkdir -p "$OUT"

    confirm_scan

    run_preflight
    draw_overall_progress 1;  run_passive
    draw_overall_progress 2;  run_subdomains
    draw_overall_progress 3;  run_live_hosts
    draw_overall_progress 4;  run_ports
    draw_overall_progress 5;  run_tech
    draw_overall_progress 6;  run_fuzz
    draw_overall_progress 7;  run_harvest
    draw_overall_progress 8;  run_xss
    draw_overall_progress 9;  run_nuclei
    draw_overall_progress 10; run_sqli
    run_report

    final_summary
}

main "$@"
