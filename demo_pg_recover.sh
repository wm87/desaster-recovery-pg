#!/bin/bash
set -euo pipefail

# -----------------------------
# Konfiguration
# -----------------------------
PGDATA=/tmp/pgdata_test
PGPORT=5433
PGUSER=$(whoami)
BACKUPDIR=/tmp/pgbackup
ARCHIVEDIR=/tmp/pgwal
DB=testdb
TABLE=testtable
PG_BIN=/usr/lib/postgresql/18/bin
RECOVERY_TIMEOUT=60  # Max. Sekunden, um Recovery abzuwarten

# -----------------------------
# Cleanup vorheriger Test
# -----------------------------
rm -rf "$PGDATA" "$BACKUPDIR" "$ARCHIVEDIR"
mkdir -p "$BACKUPDIR" "$ARCHIVEDIR"

# -----------------------------
# PostgreSQL initialisieren
# -----------------------------
echo "==> Initialisiere PostgreSQL Cluster"
"$PG_BIN/initdb" -D "$PGDATA"
chmod 700 "$PGDATA"

# Replikation für WAL Backup erlauben
echo "local   replication     $PGUSER     trust" >>"$PGDATA/pg_hba.conf"

# Konfiguration für WAL & Archive
cat >>"$PGDATA/postgresql.conf" <<EOF
wal_level = replica
archive_mode = on
archive_command = 'cp %p ${ARCHIVEDIR}/%f || true'
listen_addresses = 'localhost'
port = ${PGPORT}
EOF

# -----------------------------
# PostgreSQL starten
# -----------------------------
echo "==> Starte PostgreSQL"
"$PG_BIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k $PGDATA" -w start

# -----------------------------
# Testdatenbank & Tabelle
# -----------------------------
echo "==> Erstelle Testdatenbank und Tabelle"
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d postgres -c "CREATE DATABASE $DB;"
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "CREATE TABLE $TABLE (id INT, name TEXT);"

"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
INSERT INTO $TABLE VALUES
(1,'Alice'),(2,'Bob'),(3,'Carol'),(4,'Dave'),(5,'Eve'),
(6,'Frank'),(7,'Grace'),(8,'Heidi'),(9,'Ivan'),(10,'Judy');
EOF

echo "==> Tabelle vor Base Backup"
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE;"

# WAL Switch vor Base Backup
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 1  # kurze Pause, damit Archivierung startet

# -----------------------------
# Base Backup
# -----------------------------
echo "==> Erstelle Base Backup"
"$PG_BIN/pg_basebackup" -D "$BACKUPDIR" -h localhost -p "$PGPORT" -U "$PGUSER" -Fp -Xs -P -c fast
"$PG_BIN/pg_verifybackup" "$BACKUPDIR"

# -----------------------------
# Recovery-Zeitpunkt festlegen (vor Desaster!)
# -----------------------------
TARGET_TIME=$(date +"%Y-%m-%d %H:%M:%S")
echo "Recovery-Zeitpunkt festgelegt: $TARGET_TIME"

# -----------------------------
# Desaster simulieren
# -----------------------------
echo "==> Simuliere Desaster (DELETE)"
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "DELETE FROM $TABLE WHERE id <= 8;"

echo "==> Tabelle nach Desaster"
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE;"

# WAL Switch nach Desaster, Archivierung sicherstellen
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 2

# -----------------------------
# PostgreSQL stoppen für Restore
# -----------------------------
echo "==> Stoppe PostgreSQL für Restore"
"$PG_BIN/pg_ctl" -D "$PGDATA" -m fast -w stop

# -----------------------------
# Restore Base Backup
# -----------------------------
echo "==> Restore Base Backup"
rm -rf "${PGDATA:?}/"*
cp -a "$BACKUPDIR/"* "$PGDATA"
chmod -R 700 "$PGDATA"

# -----------------------------
# Recovery konfigurieren
# -----------------------------
touch "$PGDATA/recovery.signal"

cat >"$PGDATA/postgresql.auto.conf" <<EOF
restore_command = 'cp ${ARCHIVEDIR}/%f %p'
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'
EOF

# -----------------------------
# PostgreSQL starten für PITR
# -----------------------------
echo "==> Starte PostgreSQL für PITR Recovery"
"$PG_BIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k $PGDATA" -w start

# -----------------------------
# Warten bis Recovery abgeschlossen oder Timeout
# -----------------------------
echo "==> Überwache Recovery (Timeout=${RECOVERY_TIMEOUT}s)..."
START=$(date +%s)
while true; do
    STATUS=$("$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At -c "SELECT pg_is_in_recovery();")
    if [ "$STATUS" = "f" ]; then
        echo "✅ Recovery abgeschlossen"
        break
    fi
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [ "$ELAPSED" -ge "$RECOVERY_TIMEOUT" ]; then
        echo "❌ Recovery Timeout erreicht!"
        exit 1
    fi
    sleep 1
done

# WAL Replay LSN prüfen
REPLAY_LSN=$("$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At -c "SELECT pg_last_wal_replay_lsn();")
if [ -z "$REPLAY_LSN" ]; then
    echo "❌ Fehler: WAL-Replay-LSN leer!"
    exit 1
fi
echo "✅ WAL-Replay-LSN: $REPLAY_LSN"

# -----------------------------
# Datenintegrität prüfen
# -----------------------------
ROW_COUNT=$("$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At -c "SELECT count(*) FROM $TABLE;")
if [ "$ROW_COUNT" -ne 10 ]; then
    echo "❌ Fehler: Erwartet 10 Zeilen, gefunden $ROW_COUNT"
    exit 1
fi

MISSING_IDS=$("$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At <<EOF
SELECT count(*) FROM generate_series(1,10) s
WHERE NOT EXISTS (
  SELECT 1 FROM $TABLE t WHERE t.id = s
);
EOF
)
if [ "$MISSING_IDS" -ne 0 ]; then
    echo "❌ Fehler: Fehlende IDs nach Recovery!"
    exit 1
fi
echo "✅ Datenintegrität OK"

# -----------------------------
# Tabelle nach Recovery anzeigen
# -----------------------------
echo "==> Tabelle nach Recovery"
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE;"

# -----------------------------
# Cleanup
# -----------------------------
rm -f "$PGDATA/recovery.signal"
echo "==> Stoppe Cluster nach Test"
"$PG_BIN/pg_ctl" -D "$PGDATA" -m fast -w stop || true

echo "==> Lösche Testcluster, WAL & Backup"
rm -rf "$PGDATA" "$ARCHIVEDIR" "$BACKUPDIR"

echo "==> PITR Test erfolgreich abgeschlossen ✅"
