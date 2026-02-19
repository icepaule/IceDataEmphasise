# IceDataEmphasise

**Cribl Stream & Edge PoC** -- Intelligente Log-Pipeline-Infrastruktur mit lokaler KI-Klassifizierung fuer regulierte Umgebungen.

> **[Live-Dokumentation auf GitHub Pages](https://icepaule.github.io/IceDataEmphasise/)**

---

## Kurzfassung

IceDataEmphasise ist ein Proof of Concept, der zeigt, wie **Cribl Stream & Edge** zusammen mit einer **lokal betriebenen KI (Ollama)** die Log-Analyse in regulierten Bankenumgebungen grundlegend verbessern kann -- bei gleichzeitiger **Reduktion der Splunk-Lizenzkosten um 40--60 %**.

### Das Problem

In regulierten Umgebungen (MaRisk, BAIT, DORA) muessen alle sicherheitsrelevanten Ereignisse lueckenlos erfasst, aufbewahrt und auswertbar sein. Der klassische Ansatz -- Splunk Universal Forwarder schickt *alles* an den Indexer -- fuehrt zu hohen Lizenzkosten, weil auch operationale Massentelemetrie (Health-Checks, Debug-Logs, Container-Noise) das teure Splunk-Lizenzvolumen belastet. Gleichzeitig fehlt eine fruehe Datenklassifizierung: Sicherheitsrelevante Events sind erst nach der Indexierung identifizierbar.

### Die Loesung

IceDataEmphasise setzt eine **dreistufige Verarbeitungskette** vor den Splunk-Indexer:

1. **Cribl Edge** sammelt Logs direkt auf den Endpunkten (Linux + Windows) -- als Drop-in-Ersatz fuer den Splunk Universal Forwarder, mit voller Unterstuetzung fuer Sysmon, auditd, PowerShell Script Block Logging und fail2ban.

2. **Cribl Stream** verarbeitet, normalisiert und klassifiziert die Daten in Echtzeit ueber 7 spezialisierte Pipelines:
   - **MITRE ATT&CK-Anreicherung** -- SSH Brute-Force (T1110), verdaechtige Prozesse und Netzwerkverbindungen werden automatisch mit ATT&CK-Techniken annotiert
   - **PII-Maskierung** -- E-Mail-Adressen, IP-Adressen und API-Tokens werden DSGVO-konform reduziert, bevor sie den Endpunkt verlassen
   - **Intelligentes Sampling** -- 100 % der ERROR/CRITICAL-Events bleiben erhalten, DEBUG-Logs werden auf 10 % reduziert, ohne Informationsverlust bei sicherheitsrelevanten Daten
   - **Multi-Destination-Routing** -- Sicherheitsdaten gehen an Splunk, operationale Daten an guenstigere Speicher (S3, Elasticsearch)

3. **Lokale KI-Klassifizierung (Ollama)** entscheidet fuer jedes Ereignis: *SIEM-relevant* oder *operativ*?
   - **Stufe 1 (Regelbasiert):** 40+ Regeln fuer bekannte Muster (Windows Security Event IDs, Sysmon, auditd, SSH) -- unter 1 ms Latenz, 85--95 % Trefferquote
   - **Stufe 2 (KI-Fallback):** Unbekannte Events werden an ein lokal laufendes **Qwen2.5-14B-Sprachmodell** uebergeben, das den Kontext analysiert und eine Klassifizierung mit Begruendung liefert
   - **Kein Cloud-Abfluss:** Das KI-Modell laeuft vollstaendig on-premise -- keine Log-Daten verlassen das Netzwerk

### Konkrete Analysefaehigkeiten

| Faehigkeit | Beschreibung |
|---|---|
| **Interaktiver Splunk Check & Fix** | Browser-Panel prueft ueber die Splunk REST API automatisch alle Indexes, HEC-Tokens, S2S-Ports und Apps -- fehlende Konfigurationen werden per Klick angelegt |
| **AI Status Dashboard** | Echtzeit-Visualisierung der KI-Klassifizierung: SIEM/Operational-Verteilung, Regel- vs. Ollama-Anteile, Konfidenzwerte, Durchsatzmetriken |
| **MITRE ATT&CK Mapping** | Sicherheitsevents werden automatisch mit Technik-IDs und Taktiken annotiert -- direkt in Splunk durchsuchbar |
| **A/B-Test Regel vs. KI** | Uebung 10 vergleicht systematisch Latenzen und Trefferquoten beider Methoden fuer datenbasierte Entscheidungen |
| **PII-Compliance-Report** | Nachweis der DSGVO-konformen Datenreduktion vor Indexierung (E-Mail, IP, Token-Redaktion) |
| **Persistent Queues** | Kein Datenverlust bei Splunk-Ausfaellen -- Events werden gepuffert und nach Wiederherstellung automatisch nachgeliefert |
| **Fleet Management** | Zentrale Verwaltung von bis zu 100 Edge-Agenten (Windows + Linux) ueber eine Oberflaeche |

### Regulatorischer Mehrwert

Die gesamte Dokumentation (17 HTML-Seiten) ist **ITSO-konform** aufgebaut und adressiert explizit:

- **MaRisk AT 7.2** -- Integritaet, Verfuegbarkeit, Authentizitaet der Log-Daten; Change-Management ueber Git
- **BAIT** -- IT-Governance (RBAC in Cribl), Informationsrisikomanagement, IT-Betrieb (Monitoring, Alerting, Backup)
- **DORA** -- IKT-Risikomanagement, IKT-Vorfallmanagement (Log-Daten als forensische Grundlage), Resilienz-Tests (PQ-Ausfallsimulation)
- **DSGVO** -- Datenminimierung durch Pipeline-Filterung, PII-Maskierung, Aufbewahrungsbegrenzung, Rechenschaftspflicht

### Wirtschaftlichkeit

| Aspekt | Splunk UF (Ist-Zustand) | Cribl Stream + Edge (PoC) |
|---|---|---|
| Datenreduktion | Keine (100 % gehen an Indexer) | 40--60 % durch Sampling, Filterung, Routing |
| Lizenzmodell | Pro GB indexiertes Volumen | Cribl Free Tier: 1 TB/Tag, 100 Edge Nodes |
| Datenklassifizierung | Erst nach Indexierung (in Splunk ES) | Vor Indexierung (in Pipeline + lokale KI) |
| MITRE-Anreicherung | Nur mit Splunk Enterprise Security | In Cribl-Pipeline (kostenlos) |
| Multi-Destination | Nur Splunk | Splunk, S3, Elasticsearch, Kafka, ... |
| PII-Maskierung | Manuell in Splunk | Automatisch in Pipeline vor Indexierung |

---

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
├── docs/                           # ITSO-Dokumentation (17 HTML-Seiten, deutsch)
│   ├── index.html                  # GitHub Pages Landing Page
│   ├── screenshots/                # Seitenvorschau-Bilder
│   ├── 01-architektur.html         # Architekturuebersicht
│   ├── 02-installation.html        # Installationshandbuch
│   ├── 03-stream-konfiguration.html
│   ├── 04-edge-konfiguration.html
│   ├── 05-quellen.html             # 12 Log-Quellen im Detail
│   ├── 06-ziele.html               # HEC vs. S2S Destinations
│   ├── 07-pipelines-routen.html    # Pipelines + Route-Tabelle
│   ├── 08-splunk-integration.html  # Splunk Check & Fix Panel, Index-Mapping, Apps
│   ├── 09-betriebshandbuch.html    # Tagesbetrieb, Start/Stop, Backup
│   ├── 10-sicherheitshandbuch.html # RBAC, TLS, Haertung, DORA
│   ├── 11-notfallhandbuch.html     # DR, Restore, Eskalation
│   ├── 12-monitoring.html          # KPIs, Alerting, Dashboards
│   ├── 13-compliance.html          # MaRisk, BAIT, DORA Mapping
│   ├── 14-troubleshooting.html     # Diagnose, FAQ
│   ├── 15-phase2-uebungen.html     # Phase 2 Hands-on Uebungen
│   ├── 16-ai-status-panel.html     # AI Status & Control Panel
│   └── 17-edge-security-onboarding.html  # Edge Security Onboarding
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
| `pipeline_ollama_classifier` | KI-Klassifizierung (Ollama) | Alle Quellen |
| `pipeline_universal_classifier` | Regelbasierter Fallback-Klassifizierer | Alle Quellen |

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

Die vollstaendige ITSO-Dokumentation (deutsch, 17 HTML-Seiten) befindet sich im `docs/`-Verzeichnis.

**Online:** [icepaule.github.io/IceDataEmphasise](https://icepaule.github.io/IceDataEmphasise/)

Highlights:
- **Interaktiver Splunk Check & Fix** (08): Automatische REST-API-Pruefung aller Indexes, HEC-Tokens, S2S-Ports und Apps mit Ein-Klick-Fixes
- **AI Status & Control Panel** (16): Live-Dashboard fuer KI-basierte Log-Klassifizierung mit Ollama
- **Edge Security Onboarding** (17): Sysmon, auditd, MITRE ATT&CK Mapping fuer Windows und Linux
