# 🧪 GrowthBook – Proxmox-Installer

Ein-Klick-Installer für [GrowthBook](https://github.com/growthbook/growthbook) (MIT) auf
Proxmox VE – im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

**GrowthBook** ist die Open-Source-Plattform für **Feature-Flags & A/B-Testing** (freier
Ersatz für LaunchDarkly/Optimizely): Flags per UI/SDK schalten, bei Bedarf mit
Experiment-Auswertung (Bayesian & Frequentist) gegen dein Data Warehouse, Segmente,
SDK-Connections (Streaming & Polling) für alle gängigen Plattformen (JS, React, Node,
Python, Go, Android, iOS, …) und MCP-Support für KI-Agents.

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthBook-Proxmox/main/install/growthbook.sh)"
```

Das Script:

- erstellt einen **unprivilegierten LXC** (Default: 2 vCPU, 4 GB RAM, 12 GB Disk,
  Debian 13 bevorzugt, `nesting=1 keyctl=1`, `onboot=1`, Hostname `growthbook`,
  nächste freie CT-ID ab 200). Das Template wird **arch-bewusst** gewählt (amd64/arm64
  passend zum Host) und der Container-Start aktiv verifiziert – `pct create --start`
  meldet einen gescheiterten Spawn nicht über den Exit-Code.
- installiert Docker CE und startet die **offiziellen Images** (kein Build im CT):
  `growthbook/growthbook:<pin>` + `mongo:8`
- generiert `.env` (chmod 600) mit den Pflicht-Secrets: `JWT_SECRET` (bei
  `NODE_ENV=production` Pflicht – ohne wirft GrowthBook beim Boot einen Fehler),
  `ENCRYPTION_KEY` (verschlüsselt SDK-Credentials), `MONGO_PASS` (einmalig generiert,
  danach fix – Mongo-Volume initialisiert sich mit diesen Credentials)
- härtet den Stack: Mongo bleibt komplett im internen Compose-Netz (kein 27017-Exposure),
  nur Web-UI (3000) und API/SDK-Streaming (3100) sind im LAN erreichbar
- **Telemetrie ist standardmäßig AUS** (`DISABLE_TELEMETRY=true` – dokumentierte Option)
- `APP_ORIGIN` + `API_HOST` werden beim Boot automatisch auf die aktuelle CT-IP
  synchronisiert (DHCP-IP-Hüpfer überlebt damit; `https://`-Werte bleiben unangetastet)
- richtet **systemd** ein (`growthbook.service`, `Restart=always`) → reboot-sicher
- verifiziert: Service aktiv, Compose-Services oben (Mongo mit Healthcheck-Gate),
  Web-UI antwortet, vom Host erreichbar

Am Ende bekommst du die URLs:

- **Web-UI:** `http://<LXC-IP>:3000` – der **erste registrierte Account** wird
  Organisations-Admin
- **API/SDK-Streaming:** `http://<LXC-IP>:3100` – Host, den die UI bei SDK-Connections
  vorschlägt

### Optionen (hinter dem schließenden Anführungszeichen anhängen)

```bash
... " --id 210 --memory 4096 --port 3000 --stream-port 3100
... " --ip 192.168.1.50/24 --gateway 192.168.1.1     # statische IP (empfohlen)
... " --version git-6c38e93                          # Image-Pin überschreiben
... " --force                                        # bestehenden CT neu aufsetzen
```

## Warum `git-…` als Image-Pin?

GrowthBook veröffentlicht Docker-Tags als `latest` + `git-<commit-sha>` (kein Semver).
Der Installer pinnt daher einen konkreten Commit-Stand (`git-6c38e93` ≈ Release
v5.2.1) statt des beweglichen `:latest` – Updates laufen bewusst über
`--update`, nicht unbemerkt beim Boot. Die Pins werden hier bei Releases aktualisiert.

## Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthBook-Proxmox/main/install/growthbook.sh)" --update
```

- zieht die im Installer gepinnte Image-Version (der Pin im Repo wird bei Releases aktualisiert)
- `.env` inkl. aller Secrets bleibt erhalten
- Daten (Mongo-Volume `mongodata` + Upload-Volume `uploads`) bleiben erhalten
- beliebiger Stand: `... " --update --version git-<sha>`

## Status / Deinstallation / Debug

```bash
... " --status      # Service, Stack, APP_ORIGIN/API_HOST, Pin, Web-UI-Erreichbarkeit
... " --uninstall   # Container stoppen + löschen (ALLE Daten weg!); --yes überspringt Rückfrage
... " --debug       # voller bash -x-Trace
```

Bei Fehlern gibt das Script die **komplette Fehlerkette** aus (Zeile, Befehl,
Exit-Code, Log-Auszüge, Container-Logs) und bleibt zur Inspektion stehen
(`pct enter <CT-ID>`).

## Architektur im LXC

```
┌─ LXC „growthbook“ (unprivileged, Docker-in-LXC) ────────────┐
│  systemd: growthbook.service (Restart=always, ExecStartPre  │
│            sync-app-url.sh → APP_ORIGIN/API_HOST = CT-IP)   │
│                                                             │
│  docker compose (name: growthbook):                         │
│   mongo       mongo:8                    intern (KEIN Expose)│
│   growthbook  growthbook/growthbook:<pin> 0.0.0.0:<PORT>→3000│
│                                           0.0.0.0:<STREAM>→3100│
│                                                             │
│  /opt/growthbook/.env  (600) – Secrets, APP_ORIGIN, API_HOST│
│  Volumes: mongodata (/data/db), uploads (…/back-end/uploads)│
└─────────────────────────────────────────────────────────────┘
```

- **3000** – Web-UI (Next.js) + API im selben Container (offizielles Single-Image-Setup)
- **3100** – API/SDK-Endpoints (Streaming-Connections für SDKs, Visual-Editor-Proxy)

## Domain-Modus (Reverse-Proxy, optional)

Setze in `/opt/growthbook/.env` `APP_ORIGIN=https://gb.beispiel.de` (und `API_HOST`
passend) – der IP-Sync beim Boot erkennt `https://` und greift dann **nicht mehr**,
deine Domain bleibt erhalten. Dahinter kannst du einen Reverse-Proxy deiner Wahl
hängen.

## E-Mail (optional)

Einladungen, Alerts und Passwort-Resets brauchen SMTP: `EMAIL_ENABLED=true` plus
`EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`, `EMAIL_FROM`
in `/opt/growthbook/.env`, dann `... " --update` (oder `systemctl restart growthbook`
im CT).

## Backup

```bash
vzdump <CT-ID> --mode snapshot        # oder pct backup <CT-ID>
```

Alle Flags/Experimente/Ergebnisse liegen im Docker-Volume `mongodata`, hochgeladene
Dateien in `uploads`.

## Harness

`harness/run.sh` testet den Installer End-to-End gegen gemockte Proxmox-/Docker-
Umgebung (unshare + Fakebin; pct/pveam/curl/apt/docker/systemctl gemockt, das
In-Container-Setup läuft echt): Install (inkl.
Bootstrap-Reihenfolge nacktes Debian → curl → docker), Compose-/Env-/Unit-/Sync-
Inhalte, Update (Secrets bleiben), Uninstall, Status, alle Fehlerketten inkl.
Arch-Filter und Spawn-Fail-Erkennung: **193 Assertions in 43 Cases**.

```bash
bash harness/run.sh    # Exit 0 = alle grün
```

## Lizenz

MIT – siehe [LICENSE](LICENSE). GrowthBook selbst: MIT
([growthbook/growthbook](https://github.com/growthbook/growthbook)).
