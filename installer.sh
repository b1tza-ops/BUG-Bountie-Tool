#!/usr/bin/env bash
# ============================================================
#  Bug Bounty Toolkit Installer
#  Installs: Go, httpx, nuclei, ffuf, subfinder, katana,
#            nmap, whatweb, wafw00f, sqlmap, nikto, amass,
#            gau, waybackurls, dalfox, gobuster, feroxbuster
#  Tested on: Ubuntu 20.04/22.04/24.04, Debian 11/12, Kali
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GO_VERSION="1.22.3"
INSTALL_DIR="$HOME/go/bin"
RESULTS_DIR="$HOME/bugbounty"

# ─────────────────────────────────────────────
# FIX PATH IMMEDIATELY — before anything else runs
# This is the #1 reason Go tools fail to install
# ─────────────────────────────────────────────
fix_go_path() {
    export GOPATH="$HOME/go"
    export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$GOPATH/bin"

    # Determine shell rc file
    SHELL_RC="$HOME/.bashrc"
    [[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"
    [[ "$SHELL" == */fish ]] && SHELL_RC="$HOME/.config/fish/config.fish"

    # Write to rc file if not already there
    if ! grep -q "go/bin" "$SHELL_RC" 2>/dev/null; then
        echo '' >> "$SHELL_RC"
        echo '# Go PATH — added by bugbounty installer' >> "$SHELL_RC"
        echo 'export GOPATH=$HOME/go' >> "$SHELL_RC"
        echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin:$GOPATH/bin' >> "$SHELL_RC"
    fi

    # Also write to /etc/environment as a fallback for system-wide access
    mkdir -p "$HOME/go/bin"
}

fix_go_path

log()     { echo -e "${CYAN}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

# ─────────────────────────────────────────────
banner() {
cat << 'EOF'

  ██████╗ ██╗   ██╗ ██████╗     ██████╗  ██████╗ ██╗   ██╗███╗   ██╗████████╗██╗   ██╗
  ██╔══██╗██║   ██║██╔════╝     ██╔══██╗██╔═══██╗██║   ██║████╗  ██║╚══██╔══╝╚██╗ ██╔╝
  ██████╔╝██║   ██║██║  ███╗    ██████╔╝██║   ██║██║   ██║██╔██╗ ██║   ██║    ╚████╔╝ 
  ██╔══██╗██║   ██║██║   ██║    ██╔══██╗██║   ██║██║   ██║██║╚██╗██║   ██║     ╚██╔╝  
  ██████╔╝╚██████╔╝╚██████╔╝    ██████╔╝╚██████╔╝╚██████╔╝██║ ╚████║   ██║      ██║   
  ╚═════╝  ╚═════╝  ╚═════╝     ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝   ╚═╝      ╚═╝  
                                                                                        
         Bug Bounty Toolkit Installer  —  for authorised testing only
EOF
echo ""
}

# ─────────────────────────────────────────────
check_root() {
    if [[ $EUID -eq 0 ]]; then
        warn "Running as root. Tools will install system-wide."
    else
        log "Running as user: $(whoami)"
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        log "Detected OS: $PRETTY_NAME"
    else
        error "Cannot detect OS. Exiting."
        exit 1
    fi
}

# ─────────────────────────────────────────────
install_dependencies() {
    header "System Dependencies"
    log "Updating package lists..."

    if [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$OS" == "kali" ]]; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            curl wget git python3 python3-pip \
            nmap nikto whatweb wafw00f \
            libpcap-dev build-essential \
            unzip tar jq 2>/dev/null || true
        success "System packages installed"
    elif [[ "$OS" == "fedora" || "$OS" == "rhel" || "$OS" == "centos" ]]; then
        sudo dnf install -y \
            curl wget git python3 python3-pip \
            nmap nikto libpcap-devel gcc \
            unzip tar jq 2>/dev/null || true
        success "System packages installed"
    else
        warn "Unknown distro — attempting apt install anyway"
        sudo apt-get update -qq && sudo apt-get install -y curl wget git python3 python3-pip nmap unzip tar jq 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────
install_go() {
    header "Go Language Runtime"

    # Find go binary wherever it might be installed
    GO_BIN=""
    for candidate in /usr/local/go/bin/go /usr/bin/go /snap/bin/go "$(command -v go 2>/dev/null)"; do
        if [ -x "$candidate" ]; then
            GO_BIN="$candidate"
            break
        fi
    done

    if [ -n "$GO_BIN" ]; then
        CURRENT_GO=$("$GO_BIN" version | awk '{print $3}' | sed 's/go//')
        success "Go already installed: v$CURRENT_GO (at $GO_BIN)"
        # Ensure PATH includes Go bin dirs even for pre-installed Go
        export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
        return
    fi

    log "Installing Go $GO_VERSION..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  GOARCH="amd64" ;;
        aarch64) GOARCH="arm64" ;;
        armv7l)  GOARCH="armv6l" ;;
        *)       GOARCH="amd64" ;;
    esac

    GO_TAR="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
    wget -q "https://go.dev/dl/${GO_TAR}" -O /tmp/${GO_TAR}
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/${GO_TAR}
    rm /tmp/${GO_TAR}

    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
    success "Go $GO_VERSION installed"
}

# ─────────────────────────────────────────────
find_go_binary() {
    for candidate in /usr/local/go/bin/go /usr/bin/go /snap/bin/go "$(command -v go 2>/dev/null)"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

install_go_tool() {
    local name=$1
    local pkg=$2
    local desc=$3

    # Check if already installed in PATH or in ~/go/bin
    if command -v "$name" &>/dev/null || [ -f "$HOME/go/bin/$name" ]; then
        success "$name already installed — skipping"
        # Symlink to /usr/local/bin so it's always in PATH
        if [ ! -f "/usr/local/bin/$name" ] && [ -f "$HOME/go/bin/$name" ]; then
            sudo ln -sf "$HOME/go/bin/$name" "/usr/local/bin/$name" 2>/dev/null || true
        fi
        return
    fi

    local GO_BIN
    GO_BIN=$(find_go_binary)

    if [ -z "$GO_BIN" ]; then
        warn "$name skipped — Go not found in PATH"
        return
    fi

    log "Installing $name ($desc)..."

    # Run install and capture output for error detection
    local install_output
    install_output=$("$GO_BIN" install "$pkg" 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ] && [ -f "$HOME/go/bin/$name" ]; then
        # Symlink to /usr/local/bin so it works without PATH changes
        sudo ln -sf "$HOME/go/bin/$name" "/usr/local/bin/$name" 2>/dev/null || true
        success "$name installed → symlinked to /usr/local/bin/$name"
    else
        # Show what went wrong
        warn "$name failed — retrying with verbose output..."
        echo -e "  ${RED}Error:${NC} $(echo "$install_output" | tail -5)"

        # Retry once with CGO disabled (fixes many libpcap issues)
        log "Retrying $name with CGO_ENABLED=0..."
        if CGO_ENABLED=0 "$GO_BIN" install "$pkg" 2>/dev/null && [ -f "$HOME/go/bin/$name" ]; then
            sudo ln -sf "$HOME/go/bin/$name" "/usr/local/bin/$name" 2>/dev/null || true
            success "$name installed (CGO disabled)"
        else
            warn "$name could not be installed — skipping"
        fi
    fi
}

install_go_tools() {
    header "ProjectDiscovery + Go Tools"
    # Ensure PATH is fully set before installing any Go tools
    export GOPATH="$HOME/go"
    export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$GOPATH/bin"
    mkdir -p "$HOME/go/bin"

    install_go_tool "httpx"       "github.com/projectdiscovery/httpx/cmd/httpx@latest"         "HTTP probing"
    install_go_tool "nuclei"      "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"     "Vulnerability scanner"
    install_go_tool "subfinder"   "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" "Subdomain discovery"
    install_go_tool "katana"      "github.com/projectdiscovery/katana/cmd/katana@latest"        "Web crawler"
    install_go_tool "naabu"       "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"       "Port scanner"
    install_go_tool "dnsx"        "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"            "DNS resolver"
    install_go_tool "ffuf"        "github.com/ffuf/ffuf/v2@latest"                              "Web fuzzer"
    install_go_tool "gobuster"    "github.com/OJ/gobuster/v3@latest"                            "Dir/DNS bruter"
    install_go_tool "dalfox"      "github.com/hahwul/dalfox/v2@latest"                         "XSS scanner"
    install_go_tool "gau"         "github.com/lc/gau/v2/cmd/gau@latest"                        "URL fetcher (archive)"
    install_go_tool "waybackurls" "github.com/tomnomnom/waybackurls@latest"                     "Wayback Machine URLs"
    install_go_tool "anew"        "github.com/tomnomnom/anew@latest"                            "Append new lines"
    install_go_tool "gf"          "github.com/tomnomnom/gf@latest"                             "Pattern grep"
    install_go_tool "qsreplace"   "github.com/tomnomnom/qsreplace@latest"                       "Query string replace"
    install_go_tool "hakrawler"   "github.com/hakluke/hakrawler@latest"                         "Web crawler"
}

# ─────────────────────────────────────────────
install_feroxbuster() {
    header "Feroxbuster"

    if command -v feroxbuster &>/dev/null; then
        success "feroxbuster already installed"
        return
    fi

    log "Installing feroxbuster (Rust-based dir buster)..."
    if command -v curl &>/dev/null; then
        curl -sL https://raw.githubusercontent.com/epi052/feroxbuster/main/install-nix.sh | bash -s "$HOME/.local/bin" 2>/dev/null \
            && success "feroxbuster installed" \
            || warn "feroxbuster install failed — install manually: https://github.com/epi052/feroxbuster"
    fi
}

# ─────────────────────────────────────────────
install_sqlmap() {
    header "sqlmap"

    if command -v sqlmap &>/dev/null; then
        success "sqlmap already installed"
        return
    fi

    log "Installing sqlmap..."
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$OS" == "kali" ]]; then
        sudo apt-get install -y -qq sqlmap 2>/dev/null && success "sqlmap installed via apt" && return
    fi

    # Fallback: git clone
    git clone --quiet https://github.com/sqlmapproject/sqlmap.git "$HOME/tools/sqlmap" 2>/dev/null || true
    echo '#!/bin/bash' | sudo tee /usr/local/bin/sqlmap > /dev/null
    echo "python3 $HOME/tools/sqlmap/sqlmap.py \"\$@\"" | sudo tee -a /usr/local/bin/sqlmap > /dev/null
    sudo chmod +x /usr/local/bin/sqlmap
    success "sqlmap installed (from git)"
}

# ─────────────────────────────────────────────
install_amass() {
    header "Amass"

    if command -v amass &>/dev/null; then
        success "amass already installed"
        return
    fi

    log "Installing amass (OWASP subdomain enumeration)..."
    if [[ "$OS" == "kali" ]]; then
        sudo apt-get install -y -qq amass 2>/dev/null && success "amass installed" && return
    fi

    install_go_tool "amass" "github.com/owasp-amass/amass/v4/...@master" "OWASP subdomain enum"
}

# ─────────────────────────────────────────────
install_wordlists() {
    header "Wordlists"

    WORDLIST_DIR="$HOME/wordlists"
    mkdir -p "$WORDLIST_DIR"

    # SecLists
    if [ -d "$WORDLIST_DIR/SecLists" ]; then
        success "SecLists already downloaded"
    else
        log "Downloading SecLists (this may take a moment)..."
        git clone --quiet --depth 1 https://github.com/danielmiessler/SecLists.git "$WORDLIST_DIR/SecLists" \
            && success "SecLists downloaded → $WORDLIST_DIR/SecLists" \
            || warn "SecLists download failed"
    fi

    # Common quick wordlist
    if [ ! -f "$WORDLIST_DIR/common.txt" ]; then
        wget -q https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/common.txt \
            -O "$WORDLIST_DIR/common.txt" \
            && success "common.txt downloaded" || true
    fi
}

# ─────────────────────────────────────────────
install_nuclei_templates() {
    header "Nuclei Templates"
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

    NUCLEI_BIN=""
    for candidate in /usr/local/bin/nuclei "$HOME/go/bin/nuclei" "$(command -v nuclei 2>/dev/null)"; do
        if [ -x "$candidate" ]; then
            NUCLEI_BIN="$candidate"
            break
        fi
    done

    if [ -n "$NUCLEI_BIN" ]; then
        log "Updating nuclei templates..."
        "$NUCLEI_BIN" -update-templates -silent 2>/dev/null && success "Nuclei templates updated" || warn "Template update failed"
    else
        warn "nuclei not found — skipping template update"
    fi
}

# ─────────────────────────────────────────────
create_workspace() {
    header "Workspace Setup"

    mkdir -p "$RESULTS_DIR"/{recon,scans,reports,loot}

    cat > "$RESULTS_DIR/scan.sh" << 'SCANEOF'
#!/usr/bin/env bash
# Quick recon script — edit TARGET before running
TARGET="dev.receipttrack.co.uk"
OUT="$HOME/bugbounty/recon/${TARGET}_$(date +%Y%m%d_%H%M)"
mkdir -p "$OUT"

echo "[*] Running httpx..."
httpx -u "https://$TARGET" -title -tech-detect -status-code -tls-grab -json -o "$OUT/httpx.json" -silent

echo "[*] Running subfinder..."
subfinder -d "$TARGET" -silent -o "$OUT/subdomains.txt"

echo "[*] Running nuclei..."
nuclei -u "https://$TARGET" -severity critical,high,medium -json-export "$OUT/nuclei.json" -silent -rate-limit 50

echo "[*] Running ffuf (dir bruteforce)..."
ffuf -u "https://$TARGET/FUZZ" -w "$HOME/wordlists/common.txt" -o "$OUT/ffuf.json" -of json -mc 200,301,302,403 -silent

echo "[✓] Done! Results in: $OUT"
SCANEOF
    chmod +x "$RESULTS_DIR/scan.sh"

    success "Workspace created → $RESULTS_DIR"
    success "Quick scan script → $RESULTS_DIR/scan.sh"
}

# ─────────────────────────────────────────────
print_summary() {
    header "Installation Summary"

    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin:/usr/local/bin

    TOOLS=(httpx nuclei ffuf subfinder katana naabu dnsx gobuster dalfox gau waybackurls feroxbuster sqlmap nmap nikto whatweb amass)

    INSTALLED=0
    MISSING=0

    echo ""
    printf "  %-20s %s\n" "TOOL" "STATUS"
    printf "  %-20s %s\n" "────────────────────" "──────────"
    for tool in "${TOOLS[@]}"; do
        # Check PATH, ~/go/bin, and /usr/local/bin
        if command -v "$tool" &>/dev/null || [ -f "$HOME/go/bin/$tool" ] || [ -f "/usr/local/bin/$tool" ]; then
            printf "  ${GREEN}%-20s ✓ installed${NC}\n" "$tool"
            INSTALLED=$((INSTALLED + 1))
        else
            printf "  ${YELLOW}%-20s ✗ not found${NC}\n" "$tool"
            MISSING=$((MISSING + 1))
        fi
    done

    echo ""
    echo -e "  ${GREEN}$INSTALLED installed${NC} / ${YELLOW}$MISSING missing${NC}"
    echo ""

    if [ $MISSING -gt 0 ]; then
        echo -e "  ${YELLOW}To retry missing tools:${NC}"
        echo -e "  ${CYAN}source ~/.bashrc && ./install_bugbounty.sh${NC}"
        echo ""
    fi

    echo -e "  ${BOLD}Reload your shell:${NC}  ${CYAN}source ~/.bashrc${NC}"
    echo -e "  ${BOLD}Quick recon:${NC}        ${CYAN}$RESULTS_DIR/scan.sh${NC}"
    echo -e "  ${BOLD}Wordlists:${NC}          ~/wordlists/SecLists/"
    echo -e "  ${BOLD}Results:${NC}            ~/bugbounty/"
    echo ""
}

# ─────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────
main() {
    banner
    check_root
    detect_os

    install_dependencies
    install_go
    install_go_tools
    install_feroxbuster
    install_sqlmap
    install_amass
    install_wordlists
    install_nuclei_templates
    create_workspace
    print_summary
}

main "$@"
