# IceDataEmphasise

**Cribl Stream & Edge PoC** - Log-Pipeline-Infrastruktur als Alternative zum Splunk Universal Forwarder.

Evaluierung von Cribl Stream 4.16.0 und Cribl Edge fuer den Einsatz in regulierten Umgebungen (ITSO-konforme Dokumentation fuer deutsche Banken nach MaRisk/BAIT/DORA).

## Architektur

```
  Log-Quellen (12)          Cribl Edge           Cribl Stream         Splunk
 +-----------------+     +-------------+     +----------------+    +---------+
 | Systemd Journal |     |             |     |                |    |         |
 | Apache Logs     |---->| Edge Agent  |---->|  Pipelines (5) |--->| HEC     |
 | SSH Auth        |     | (Managed)   |     |  Routes   (7)  |    | :8088   |
 | Docker/HA       |     | Port 4200   |     |                |--->| S2S     |
 | Samba, Tor, ... |     +-------------+     |  Stream UI     |    | :9997   |
 +-----------------+                         |  Port 9000     |    +---------+
                                             +----------------+
                                                    |
                                              Tailscale VPN
                                              (Headscale)
```

## Schnellstart

```bash
# 1. Repository klonen
git clone git@github.com:icepaule/IceDataEmphasise.git
cd IceDataEmphasise

# 2. Umgebung konfigurieren
cp .env.example .env
# .env mit echten Werten befuellen (Passwoerter, Tokens, IPs)

# 3. Voraussetzungen pruefen
sudo ./scripts/00-preflight-check.sh

# 4. Tailscale installieren (fuer VPN-Zugang)
sudo ./scripts/01-install-tailscale.sh

# 5. Cribl Stream installieren
sudo ./scripts/02-install-cribl-stream.sh

# 6. Cribl Edge installieren
sudo ./scripts/03-install-cribl-edge-linux.sh

# 7. Log-Quellen konfigurieren
sudo ./scripts/04-configure-sources.sh

# 8. Splunk-Destinations konfigurieren
./scripts/05-configure-destinations.sh

# 9. Pipelines und Routes konfigurieren
./scripts/06-configure-pipelines.sh

# 10. Deployment verifizieren (20 Tests)
sudo ./scripts/07-verify-deployment.sh
```

## Verzeichnisstruktur

```
IceDataEmphasise/
├── scripts/                        # Installations- und Konfigurationsskripte
│   ├── lib/                        # Shared Libraries (common.sh, api-helpers.sh)
│   ├── 00-preflight-check.sh       # Systemvoraussetzungen pruefen
│   ├── 01-install-tailscale.sh     # Tailscale + Headscale-Anbindung
│   ├── 02-install-cribl-stream.sh  # Cribl Stream 4.16.0 installieren
│   ├── 03-install-cribl-edge-linux.sh  # Cribl Edge (Managed Node)
│   ├── 04-configure-sources.sh     # 12 Log-Quellen via API
│   ├── 05-configure-destinations.sh    # HEC + S2S Destinations
│   ├── 06-configure-pipelines.sh   # 5 Pipelines + Route-Tabelle
│   ├── 07-verify-deployment.sh     # End-to-End-Tests (20 Tests)
│   ├── 08-backup-cribl-config.sh   # Konfigurations-Backup (Cron-faehig)
│   └── 09-uninstall-cribl.sh       # Saubere Deinstallation
├── configs/
│   ├── stream/sources/             # 12 JSON Source-Definitionen
│   ├── stream/destinations/        # HEC + S2S JSON-Konfigurationen
│   └── stream/pipelines/           # 5 Pipelines + Route-Tabelle (JSON)
├── splunk/
│   ├── configure-hec-token.sh      # HEC-Token auf Splunk erstellen
│   ├── configure-s2s-receiver.sh   # S2S-Empfang aktivieren
│   └── indexes.conf.example        # 11 Splunk-Indexes
├── windows/
│   ├── install-cribl-edge.ps1      # Windows Edge Deployment (PowerShell)
│   └── README-Windows.md           # Windows-Anleitung (deutsch)
├── docs/                           # ITSO-Dokumentation (14 HTML-Seiten, deutsch)
│   ├── 01-architektur.html         # Architekturuebersicht
│   ├── 02-installation.html        # Installationshandbuch
│   ├── 03-stream-konfiguration.html
│   ├── 04-edge-konfiguration.html
│   ├── 05-quellen.html             # 12 Log-Quellen im Detail
│   ├── 06-ziele.html               # HEC vs. S2S Destinations
│   ├── 07-pipelines-routen.html    # Pipelines + Route-Tabelle
│   ├── 08-splunk-integration.html  # Splunk-Anbindung
│   ├── 09-betriebshandbuch.html    # Tagesbetrieb, Start/Stop, Backup
│   ├── 10-sicherheitshandbuch.html # RBAC, TLS, Haertung, DORA
│   ├── 11-notfallhandbuch.html     # DR, Restore, Eskalation
│   ├── 12-monitoring.html          # KPIs, Alerting, Dashboards
│   ├── 13-compliance.html          # MaRisk, BAIT, DORA Mapping
│   └── 14-troubleshooting.html     # Diagnose, FAQ
├── .env.example                    # Umgebungsvariablen (Platzhalter)
├── .gitignore
├── CHANGELOG.md
└── README.md
```

## Log-Quellen (12)

| # | Quelle | Typ | Pfad | Splunk-Index |
|---|--------|-----|------|-------------|
| 1 | Systemd Journal | Journald | `/var/log/journal/` | `os_journal` |
| 2 | Apache Access | File Monitor | `/var/log/apache2/access.log*` | `web_apache` |
| 3 | Apache Error | File Monitor | `/var/log/apache2/error.log*` | `web_apache` |
| 4 | Samba | File Monitor | `/var/log/samba/log.*` | `infra_samba` |
| 5 | Docker/HA | File Monitor | `/var/lib/docker/containers/*/*.log` | `iot_homeassistant` |
| 6 | Mosquitto | File Monitor | Docker JSON Logs | `iot_mqtt` |
| 7 | SSH Auth | File Monitor | `/var/log/auth.log` | `sec_auth` |
| 8 | Tor | File Monitor | `/var/log/tor/` | `sec_tor` |
| 9 | dnsmasq | File Monitor | `/var/log/dnsmasq-tor.log` | `infra_dns` |
| 10 | CUPS | File Monitor | `/var/log/cups/access_log` | `infra_cups` |
| 11 | Boot Logs | File Monitor | `/var/log/boot.log*` | `os_boot` |
| 12 | dpkg | File Monitor | `/var/log/dpkg.log*` | `os_packages` |

## Pipelines

| Pipeline | Beschreibung | Anwendung |
|----------|-------------|-----------|
| `pipeline_syslog_enrichment` | Metadata, Timestamp-Extraktion | Journal, Apache Error |
| `pipeline_apache_clf` | Combined Log Format Parser | Apache Access |
| `pipeline_docker_json` | Docker JSON Log Parser | Docker/HA, Mosquitto |
| `pipeline_security_auth` | SSH-Parser, MITRE ATT&CK Tags | SSH Auth |
| `pipeline_generic_passthrough` | Minimal-Metadata | Samba, Tor, Default |

## Routing-Design

- **Security-Quellen** (SSH, Journal, Samba) via **S2S** (zuverlaessiger, natives Protokoll)
- **Web-/IoT-Quellen** (Apache, Docker) via **HEC** (flexibler, HTTP-basiert)

## Lizenz

Cribl Free Tier (kostenlos, kein Ablauf):
- 1 TB/Tag Verarbeitung
- 100 Edge Nodes
- 10 Worker Processes

## Sicherheitshinweis

Dieses Repository enthaelt **keine** sensiblen Daten (IP-Adressen, Passwoerter, Tokens).
Echte Deployment-Credentials befinden sich ausschliesslich in der internen Confluence-Dokumentation.

## Dokumentation

Die vollstaendige ITSO-Dokumentation (deutsch, 14 HTML-Seiten) befindet sich im `docs/`-Verzeichnis.
Oeffnen Sie `docs/01-architektur.html` als Einstiegspunkt.
