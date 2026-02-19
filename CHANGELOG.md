# Changelog

Alle wesentlichen Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.1.0/).

## [1.2.0] - 2026-02-19

### Hinzugefuegt
- **Interaktiver Splunk Check & Fix Panel** (08-splunk-integration.html):
  Automatische REST-API-Pruefung aller Splunk-Konfigurationen (15 Indexes, HEC-Token,
  S2S-Port, 8 Apps/TAs) mit Ein-Klick-Behebung
- Nginx-Reverse-Proxy fuer Splunk REST API (`/proxy/splunk-api/`)
- Splunkbase-App-Installation via REST API (mit Splunk.com-Credentials)
- Stub-App-Erkennung (leere Platzhalter nach fehlgeschlagener REST-Installation)
- Screenshots der Dokumentationsseiten (`docs/screenshots/`)
- Landing Page (index.html) mit Screenshot-Vorschau

### Geaendert
- README.md: Aktualisierte Verzeichnisstruktur (17 Seiten), GitHub Pages Link, Pipeline-Tabelle
- CHANGELOG.md: Versionshistorie nachgefuehrt

### Behoben
- Splunk REST API CSRF-Schutz blockierte Browser-Requests (Origin-Header wird in Nginx gestrippt)
- HEC Allowed Indexes Update: Korrektes Splunk-API-Format (wiederholte `indexes=` Parameter + `index=`)
- HEC Token-Suche: Erkennt alle Cribl-Tokens statt hart-kodiertem Token-Wert

## [1.1.0] - 2026-02-17

### Hinzugefuegt
- Universal Classifier Pipeline und Edge-Integration
- AI Status & Control Panel (16-ai-status-panel.html)
- Edge Security Onboarding (17-edge-security-onboarding.html)
- Phase 2 Hands-on Uebungen (15-phase2-uebungen.html)
- Phase 2 Infrastruktur-Skripte (10-15)

## [1.0.0] - 2026-02-10

### Hinzugefuegt
- Initiale Projektstruktur und Repository-Setup
- Installationsskripte fuer Cribl Stream 4.16.0 und Cribl Edge
- Tailscale/Headscale-Anbindung
- 12 Log-Quellen-Konfigurationen (Systemd, Apache, Samba, Docker, SSH, etc.)
- Splunk HEC + S2S Destination-Konfigurationen
- 5 Processing Pipelines mit Route-Tabelle
- Windows Edge Deployment (PowerShell)
- ITSO-konforme Dokumentation (14 HTML-Seiten, deutsch)
- End-to-End-Verifikationssuite
- Backup- und Monitoring-Skripte
