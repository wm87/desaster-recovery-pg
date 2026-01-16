[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PostgreSQL Version](https://img.shields.io/badge/PostgreSQL-18-blue.svg)](https://www.postgresql.org/)
[![PITR Ready](https://img.shields.io/badge/PITR-Ready-success.svg)]()

# PostgreSQL PITR (Point-in-Time Recovery) - Simulation

## Übersicht

Dieses Repository enthält ein strukturiertes Bash-Skript (`demo_pg_recover.sh`), das den vollständigen Workflow von PostgreSQL Point-in-Time Recovery (PITR) simuliert. Es erstellt einen temporären Test-Cluster, generiert Testdaten, sichert diese Daten mit WAL-Archiven, simuliert ein Desaster und führt anschließend eine Recovery durch, um die Datenintegrität sicherzustellen.

Dieses Skript ist ideal für:

* DevOps Engineers, die PITR-Prozesse automatisieren möchten.
* Datenbankadministratoren (DBAs), die Recovery-Szenarien testen wollen.
* Teams, die Schulungsumgebungen für PostgreSQL Backups und Recovery benötigen.

## Funktionen

1. **Cluster Initialisierung**: Temporärer PostgreSQL-Cluster in `/tmp/pgdata_test`.
2. **Datenbank & Tabelle erstellen**: Testdatenbank und Tabelle mit Beispiel-Datensätzen.
3. **WAL-Archivierung**: Sicherung von Write-Ahead-Logs für PITR.
4. **Base Backup & Verschlüsselung**: Erstellung eines Base Backups und GPG-Verschlüsselung.
5. **Desaster-Simulation**: Löschen von Daten, um eine Recovery-Situation zu simulieren.
6. **Point-in-Time Recovery (PITR)**: Wiederherstellung der Daten bis zu einem definierten Zeitpunkt.
7. **Datenintegrität Prüfung**: Sicherstellen, dass alle ursprünglichen Datensätze nach Recovery vorhanden sind.
8. **Automatischer Cleanup**: Entfernt temporäre Cluster, WAL-Archive und Backups nach Testabschluss.

## Voraussetzungen

* Linux oder macOS
* PostgreSQL 18 installiert (`/usr/lib/postgresql/18/bin`)
* Bash
* Schreibrechte im `/tmp`-Verzeichnis

## Nutzung

```bash
chmod +x demo_pg_recover.sh
./demo_pg_recover.sh
```

Standardmäßig verwendet das Skript den Port **5433** für den temporären PostgreSQL-Cluster.

Das Skript führt folgende Schritte aus:

1. Initialisiert einen temporären PostgreSQL-Cluster.
2. Erstellt eine Testdatenbank `testdb` und Tabelle `testtable` mit 10 Datensätzen.
3. Führt ein WAL-basiertes Base Backup durch und verschlüsselt es optional.
4. Simuliert ein Desaster, indem einige Datensätze gelöscht werden.
5. Stellt die Datenbank bis zu einem definierten Recovery-Zeitpunkt wieder her.
6. Überprüft die Datenintegrität nach der Wiederherstellung.
7. Löscht den Testcluster und temporäre Dateien.

## Konfiguration

Parameter können im Skript angepasst werden:

| Variable           | Beschreibung                                          |
| ------------------ | ----------------------------------------------------- |
| `PGDATA`           | Pfad zum Test-Cluster                                 |
| `PGPORT`           | PostgreSQL Port (Standard: 5433)                      |
| `PGUSER`           | Benutzer für den Cluster                              |
| `BACKUPDIR`        | Verzeichnis für Base Backup                           |
| `ARCHIVEDIR`       | Verzeichnis für WAL-Archive                           |
| `DB`               | Testdatenbankname                                     |
| `TABLE`            | Testtabelle                                           |
| `PG_BIN`           | Pfad zu PostgreSQL Binaries                           |
| `RECOVERY_TIMEOUT` | Max. Wartezeit für Recovery in Sekunden               |
| `GPG_PASSWORD`     | Passwort für die GPG-Verschlüsselung des Base Backups |

## Sicherheit & Best Practices

* Testumgebung läuft isoliert in `/tmp`
* Benutzerrechte werden für WAL-Replikation temporär gesetzt
* Recovery-Zeitpunkt wird dynamisch auf die aktuelle Uhrzeit gesetzt
* Cleanup entfernt alle temporären Daten, um Konflikte zu vermeiden
* In Produktion sollten GPG-Passwörter niemals im Skript stehen – besser Secret Manager verwenden

## Status

✅ Vollständig getestet auf Ubuntu 25.10 mit PostgreSQL 18

## Lizenz

MIT License
