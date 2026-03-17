# b1tza Scanner 🔐

```
  _       _    _              _
 | |__   / |  | |_   ____  _ | |
 | '_ \  | |  | __|  |_  / | || |
 | |_) | | |  | |_    / /  | || |
 |_.__/  |_|   \__|  /___|  |_||_|
```

> **Interactive Bug Bounty & Penetration Testing Toolkit**  
> For authorised security testing only. Always obtain written permission before scanning any target.

---

## 📸 Features

- 🎛 **Interactive TUI** — arrow-key menus, animated spinners, live progress bars
- 🔍 **11-phase intelligent scan chain** — each phase feeds results into the next
- 📊 **Live findings counter** — watch vulnerabilities appear in real-time during nuclei scans
- 📄 **Auto-generated HTML + JSON report** — ready to attach to compliance submissions
- ⚡ **Quick / Full / Custom modes** — run everything or pick individual phases
- 🛡 **Scope confirmation** — requires explicit authorisation acknowledgement before scanning

---

## 🔧 Tools Used

| Tool | Purpose |
|------|---------|
| `httpx` | HTTP probing, tech detection, TLS info |
| `nuclei` | CVE & misconfiguration scanning |
| `ffuf` | Directory & endpoint fuzzing |
| `subfinder` | Passive subdomain enumeration |
| `amass` | OWASP subdomain mapping |
| `katana` | Active web crawler |
| `naabu` | Fast port scanning |
| `dnsx` | DNS resolution & brute force |
| `dalfox` | XSS scanning |
| `gau` | URL harvesting from archives |
| `waybackurls` | Wayback Machine URL extraction |
| `feroxbuster` | Recursive directory bruteforcing |
| `sqlmap` | SQL injection testing |
| `nmap` | Network & service detection |
| `nikto` | Web server vulnerability scanner |
| `whatweb` | Technology fingerprinting |

---

## ⚙️ Installation

### 1. Clone the repo

```bash
git clone https://github.com/b1tza/b1tza-scanner.git
cd b1tza-scanner
chmod +x install_bugbounty.sh scan.sh
```

### 2. Install all tools

```bash
./install_bugbounty.sh
source ~/.bashrc
```

This installs Go, all tools above, SecLists wordlists, and sets up your workspace at `~/bugbounty/`.

> **Requirements:** Ubuntu 20.04 / 22.04 / 24.04, Debian 11/12, or Kali Linux  
> Go 1.22+ will be installed automatically if not present.

---

## 🚀 Usage

```bash
./scan.sh
```

The scanner walks you through a 3-step setup wizard:

```
Step 1 — Enter target domain
Step 2 — Choose scan mode (Quick / Full / Custom)
Step 3 — Set rate limit and threads
```

Then confirms before running anything.

### Scan Modes

| Mode | Phases | Time |
|------|--------|------|
| ⚡ Quick | Passive recon + live hosts + nuclei | ~5 min |
| 🔍 Full | All 11 phases | ~30–60 min |
| 🎛 Custom | You choose which phases to run | Varies |

---

## 📋 Scan Phases

```
Phase 0  — Preflight        Tool checks, workspace setup, wordlist download
Phase 1  — Passive Recon    DNS records, WHOIS, crt.sh, Wayback Machine
Phase 2  — Subdomain Enum   subfinder + amass + dnsx brute force
Phase 3  — Live Hosts       httpx probing with tech detection & TLS info
Phase 4  — Port Scanning    naabu (top 1000) + nmap service detection
Phase 5  — Tech Stack       whatweb fingerprinting
Phase 6  — Dir Fuzzing      ffuf + feroxbuster recursive (depth 3)
Phase 7  — URL Harvest      gau + waybackurls + katana crawler
Phase 8  — XSS Scanning     dalfox on all parameterised URLs
Phase 9  — Vuln Scan        nuclei (CVE, misconfig, exposure, default-login)
Phase 10 — SQL Injection     sqlmap on discovered param URLs
Phase 11 — Report           HTML + JSON report auto-generated
```

Each phase reads output from the previous one — subdomains feed into live host detection, live hosts feed into nuclei, harvested URLs feed into XSS and SQLi testing.

---

## 📁 Output Structure

Results are saved to `~/bugbounty/scans/<target>_<timestamp>/`:

```
scan_results/
├── passive/
│   ├── dns_A.txt
│   ├── whois.txt
│   ├── crtsh.txt
│   └── wayback.txt
├── subdomains/
│   ├── all.txt          ← merged unique subdomains
│   ├── subfinder.txt
│   └── amass.txt
├── hosts/
│   ├── httpx.json       ← full httpx output
│   └── live_urls.txt    ← clean list of live URLs
├── ports/
│   ├── nmap.txt
│   └── naabu.json
├── fuzz/
│   ├── ffuf_*.json
│   └── all_paths.txt    ← merged discovered paths
├── urls/
│   ├── all.txt
│   ├── params.txt       ← URLs with parameters (XSS/SQLi targets)
│   └── js.txt           ← JavaScript files
├── vulns/
│   ├── nuclei.json      ← raw nuclei findings
│   ├── nuclei.txt
│   └── dalfox.txt       ← XSS findings
├── sqli/
│   └── sqlmap_output/
├── report/
│   ├── report.html      ← 🌐 Open this in browser
│   └── summary.json     ← 📎 Attach to compliance pack
└── scan.log
```

---

## 📊 HTML Report

The auto-generated `report.html` includes:

- Executive summary with severity counts
- Full vulnerability findings table (nuclei)
- Discovered paths and endpoints
- Live hosts and subdomains
- Technology stack detected
- Suitable for HMRC, ISO 27001, or internal compliance submissions

---

## ⚠️ Legal & Ethics

This tool is for **authorised security testing only**.

- ✅ Only scan targets you own
- ✅ Only scan targets you have **written permission** to test
- ❌ Do not use against third-party targets without authorisation
- ❌ Do not use for illegal activity

The scanner requires you to explicitly confirm authorisation before every scan. Unauthorised scanning may violate the **Computer Misuse Act 1990** (UK) or equivalent laws in your jurisdiction.

---

## 🗂 File Overview

| File | Description |
|------|-------------|
| `scan.sh` | Main interactive scanner — run this |
| `install_bugbounty.sh` | Installs all tools and wordlists |
| `pentest_runner.py` | Python script for targeted httpx + nuclei + HTML report |

---

## 📦 Wordlists

SecLists is downloaded automatically to `~/wordlists/SecLists/` during installation.

Key wordlists used:
- `Discovery/Web-Content/raft-medium-directories.txt` — directory fuzzing
- `Discovery/DNS/subdomains-top1million-5000.txt` — DNS brute force
- `Discovery/Web-Content/common.txt` — fallback wordlist

---

## 🤝 Contributing

Pull requests welcome. Please ensure any contributions:
- Don't add active exploitation capabilities
- Include appropriate scope/authorisation checks
- Are tested on Ubuntu 22.04+

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

<div align="center">
  <sub>Built by b1tza • For authorised testing only</sub>
</div>
