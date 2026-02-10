# Cribl Edge -- Windows Deployment

Anleitung zur Installation und Konfiguration von Cribl Edge auf Windows-Arbeitsplatzrechnern im Managed-Modus. Der Edge-Knoten verbindet sich nach der Installation automatisch mit dem Cribl Leader und wird der Fleet **windows-workstations** zugewiesen.

---

## Voraussetzungen

| Anforderung | Minimum |
|---|---|
| Betriebssystem | Windows 10 (Build 1809+) oder Windows Server 2019+ |
| PowerShell | Version 5.1 oder neuer |
| Rechte | Lokaler Administrator |
| Netzwerk | Tailscale installiert und verbunden |
| Konnektivitaet | Ausgehend HTTPS zu `cdn.cribl.io` (MSI-Download) |
| Konnektivitaet | TCP-Port 4200 zum Cribl Leader (Tailscale-IP) |

### Tailscale pruefen

```powershell
tailscale status
```

Die Tailscale-IP des Cribl Leaders muss erreichbar sein:

```powershell
Test-NetConnection -ComputerName 100.64.0.1 -Port 4200
```

---

## Installation Schritt fuer Schritt

### 1. Skript herunterladen

Das Installationsskript befindet sich im Repository unter `windows/install-cribl-edge.ps1`.

### 2. Leader-IP anpassen

Oeffne das Skript in einem Editor und setze die Variable `$LeaderHost` auf die Tailscale-IP deines Cribl Leaders:

```powershell
$LeaderHost = "100.64.0.1"   # Tailscale-IP des Leaders anpassen
```

### 3. Ausfuehrungsrichtlinie setzen (einmalig)

Falls PowerShell-Skripte auf dem System blockiert sind:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 4. Skript als Administrator ausfuehren

```powershell
# Variante 1: Rechtsklick auf die Datei -> "Mit PowerShell ausfuehren"
# (Das Skript fordert automatisch erhoehte Rechte an, falls noetig.)

# Variante 2: Aus einer Admin-PowerShell
.\install-cribl-edge.ps1
```

Das Skript fuehrt folgende Schritte automatisch durch:

1. Prueft Administrator-Rechte (und fordert Erhoehung an, falls noetig)
2. Laedt die Cribl Edge MSI von `cdn.cribl.io` herunter
3. Installiert Cribl Edge nach `C:\Program Files\Cribl\Edge`
4. Konfiguriert den Managed-Edge-Modus mit Verbindung zum Leader
5. Weist den Knoten der Fleet `windows-workstations` zu
6. Konfiguriert die Windows Event Log Erfassung (Application, Security, System)
7. Registriert und startet den Windows-Dienst `CriblEdge`

### 5. Installation pruefen

```powershell
Get-Service -Name CriblEdge
```

Der Dienst sollte den Status `Running` haben. Im Cribl Leader-UI sollte der neue Edge-Knoten innerhalb von 1-2 Minuten unter **Manage Edge Nodes** erscheinen.

---

## Konfiguration der Windows Event Log Quellen

Nach der Installation sammelt Cribl Edge automatisch Ereignisse aus den folgenden Windows Event Log Kanaelen:

| Kanal | Beschreibung |
|---|---|
| Application | Anwendungsereignisse (Fehler, Warnungen, Informationen) |
| Security | Sicherheitsereignisse (Anmeldungen, Rechteanpassungen, Auditing) |
| System | Systemereignisse (Treiber, Dienste, Hardware) |

### Zusaetzliche Kanaele hinzufuegen

Die Konfiguration liegt unter:

```
C:\Program Files\Cribl\Edge\local\cribl\inputs\win_event_logs.yml
```

Um weitere Kanaele (z.B. `Microsoft-Windows-Sysmon/Operational`) hinzuzufuegen, ergaenze die `channels`-Liste:

```yaml
channels:
  - "Application"
  - "Security"
  - "System"
  - "Microsoft-Windows-Sysmon/Operational"
```

Nach der Aenderung den Dienst neu starten:

```powershell
Restart-Service -Name CriblEdge
```

---

## Fehlerbehebung

### Firewall blockiert Verbindung zum Leader

**Symptom:** Der Edge-Knoten erscheint nicht im Leader-UI.

**Loesung:**

1. Pruefen, ob Tailscale aktiv ist:
   ```powershell
   tailscale status
   ```

2. Konnektivitaet zum Leader testen:
   ```powershell
   Test-NetConnection -ComputerName 100.64.0.1 -Port 4200
   ```

3. Falls noetig, Windows Firewall-Regel fuer Cribl Edge erstellen:
   ```powershell
   New-NetFirewallRule -DisplayName "Cribl Edge Outbound" `
       -Direction Outbound `
       -Program "C:\Program Files\Cribl\Edge\bin\cribl.exe" `
       -Action Allow
   ```

### Dienst startet nicht

**Symptom:** Service-Status ist `Stopped` oder `StartPending`.

**Loesung:**

1. Installationslog pruefen:
   ```powershell
   Get-Content "$env:TEMP\CriblEdgeInstall\cribl-edge-install.log" -Tail 50
   ```

2. Windows-Ereignisprotokoll pruefen:
   ```powershell
   Get-EventLog -LogName Application -Source "CriblEdge" -Newest 20
   ```

3. Dienst manuell starten und Ausgabe beobachten:
   ```powershell
   & "C:\Program Files\Cribl\Edge\bin\cribl.exe" start
   ```

### Umgebungsvariablen pruefen

Die folgenden Systemumgebungsvariablen muessen gesetzt sein:

```powershell
[System.Environment]::GetEnvironmentVariable("CRIBL_DIST_MODE", "Machine")
# Erwarteter Wert: managed-edge

[System.Environment]::GetEnvironmentVariable("CRIBL_DIST_MASTER_URL", "Machine")
# Erwarteter Wert: tcp://100.64.0.1:4200
```

### Verbindung zum Leader schlaegt fehl

**Symptom:** Im Cribl Edge Log erscheinen Verbindungsfehler.

**Loesung:**

1. Log-Datei pruefen:
   ```powershell
   Get-Content "C:\Program Files\Cribl\Edge\log\cribl.log" -Tail 100
   ```

2. Sicherstellen, dass der Leader auf Port 4200 lauscht (auf dem Leader-Server):
   ```bash
   ss -tlnp | grep 4200
   ```

3. Tailscale-Verbindung beider Seiten pruefen (Leader und Edge muessen im selben Tailnet sein).

---

## Deinstallation

### 1. Dienst stoppen und entfernen

```powershell
Stop-Service -Name CriblEdge -Force -ErrorAction SilentlyContinue
& "C:\Program Files\Cribl\Edge\bin\cribl.exe" boot-start disable
```

### 2. MSI deinstallieren

```powershell
# Ueber Systemsteuerung:
# Einstellungen -> Apps -> Cribl Edge -> Deinstallieren

# Oder per Kommandozeile:
$product = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -match "Cribl" }
if ($product) {
    $product.Uninstall()
}
```

### 3. Verbleibende Dateien entfernen

```powershell
Remove-Item -Recurse -Force "C:\Program Files\Cribl\Edge" -ErrorAction SilentlyContinue
```

### 4. Umgebungsvariablen bereinigen

```powershell
[System.Environment]::SetEnvironmentVariable("CRIBL_DIST_MODE", $null, "Machine")
[System.Environment]::SetEnvironmentVariable("CRIBL_DIST_MASTER_URL", $null, "Machine")
```

### 5. Knoten im Leader entfernen

Im Cribl Leader-UI unter **Manage Edge Nodes** den entsprechenden Knoten loeschen, damit er nicht als offline angezeigt wird.
