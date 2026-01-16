#!/bin/bash
set -euo pipefail

# -----------------------------
# 1: Konfiguration
# -----------------------------
PGDATA=/tmp/pgdata_test
PGPORT=5433
PGHOST=127.0.0.1
PGUSER=$(whoami)
BACKUPDIR=/tmp/pgbackup
ARCHIVEDIR=/tmp/pgwal
DB=testdb
TABLE=testtable
PG_BIN=$(pg_config --bindir)
RECOVERY_TIMEOUT=60
GPG_PASSWORD="MeinSicheresPasswort" # Hinweis: In Produktion besser Secret Manager

# -----------------------------
# 2: Cleanup vorheriger Test
# -----------------------------
rm -rf "$PGDATA" "$BACKUPDIR" "$ARCHIVEDIR"
mkdir -p "$BACKUPDIR" "$ARCHIVEDIR"

# -----------------------------
# 3: PostgreSQL initialisieren
# -----------------------------
"$PG_BIN/initdb" -D "$PGDATA"
chmod 700 "$PGDATA"

# -----------------------------
# 4: TCP + Replikation erlauben
# -----------------------------
cat >>"$PGDATA/pg_hba.conf" <<EOF
host    all             all             127.0.0.1/32        trust
host    replication     all             127.0.0.1/32        trust
EOF

cat >>"$PGDATA/postgresql.conf" <<EOF
wal_level = replica
archive_mode = on
archive_command = 'test ! -f ${ARCHIVEDIR}/%f && cp %p ${ARCHIVEDIR}/%f'
listen_addresses = '127.0.0.1'
port = ${PGPORT}
EOF

# -----------------------------
# 5: PostgreSQL starten
# -----------------------------
"$PG_BIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k $PGDATA" -w start

# -----------------------------
# 6: Testdatenbank + Tabelle erstellen
# -----------------------------
"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres <<EOF
CREATE DATABASE $DB;
EOF

"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
CREATE TABLE $TABLE (id INT PRIMARY KEY, name TEXT);
EOF

# -----------------------------
# 7: 5 Datensätze vor Base Backup
# -----------------------------
"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
INSERT INTO $TABLE VALUES
(1,'Alice'),(2,'Bob'),(3,'Carol'),(4,'Dave'),(5,'Eve');
EOF

echo "==> Tabelle vor Base Backup:"
"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE;"

"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 2

# -----------------------------
# 8: Base Backup erstellen + GPG verschlüsseln
# -----------------------------
echo "==> Erstelle Base Backup (Plain-Modus)"
"$PG_BIN/pg_basebackup" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -D "$BACKUPDIR/base" -Fp -Xs -P -c fast

# tar + gzip: nur Clusterinhalt packen
tar -czf "$BACKUPDIR/base_backup.tar.gz" -C "$BACKUPDIR/base" .
gpg --batch --yes --passphrase "$GPG_PASSWORD" -c "$BACKUPDIR/base_backup.tar.gz"
BACKUP_FILE="$BACKUPDIR/base_backup.tar.gz.gpg"
echo "==> Base Backup fertig und verschlüsselt: $BACKUP_FILE"

# -----------------------------
# 9: 5 Datensätze nach Base Backup
# -----------------------------
"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
INSERT INTO $TABLE VALUES
(6,'Frank'),(7,'Grace'),(8,'Heidi'),(9,'Ivan'),(10,'Judy');
EOF

echo "==> Tabelle nach Base Backup, vor Desaster:"
"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE;"

"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 2

# -----------------------------
# 10: Recovery-Zeitpunkt festlegen + Desaster simulieren
# -----------------------------
TARGET_TIME=$(date +"%Y-%m-%d %H:%M:%S")
echo "Recovery-Zeitpunkt festgelegt: $TARGET_TIME"

"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
DELETE FROM $TABLE WHERE id <= 8;
EOF

echo "==> Tabelle nach Desaster:"
"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE;"

"$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 2

# -----------------------------
# 11: Stoppen für Restore
# -----------------------------
"$PG_BIN/pg_ctl" -D "$PGDATA" -m fast -w stop

# -----------------------------
# 12: Restore: GPG entschlüsseln + tar entpacken
# -----------------------------
gpg --batch --yes --passphrase "$GPG_PASSWORD" -d "$BACKUP_FILE" >"$BACKUPDIR/base_backup.tar.gz"

# PGDATA leeren und Clusterinhalt wiederherstellen
rm -rf "${PGDATA:?}/"*
tar -xzf "$BACKUPDIR/base_backup.tar.gz" -C "$PGDATA"
chmod -R 700 "$PGDATA"

# -----------------------------
# 13: Recovery konfigurieren
# -----------------------------
touch "$PGDATA/recovery.signal"
cat >>"$PGDATA/postgresql.auto.conf" <<EOF

restore_command = 'cp ${ARCHIVEDIR}/%f %p'
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'
EOF

# -----------------------------
# 14: PostgreSQL starten + PITR überwachen
# -----------------------------
"$PG_BIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k $PGDATA" -w start

echo "==> Überwache Recovery..."
START=$(date +%s)
while true; do
	STATUS=$("$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At -c "SELECT pg_is_in_recovery();")
	[ "$STATUS" = "f" ] && break
	ELAPSED=$(($(date +%s) - START))
	[ "$ELAPSED" -ge "$RECOVERY_TIMEOUT" ] && {
		echo "❌ Recovery Timeout!"
		exit 1
	}
	sleep 1
done
echo "✅ Recovery abgeschlossen"

# -----------------------------
# 15: Tabelle nach Recovery anzeigen
# -----------------------------
echo "==> Tabelle nach Recovery:"
"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE;"

# -----------------------------
# 16: Datenintegrität prüfen
# -----------------------------
ROW_COUNT=$("$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At -c "SELECT count(*) FROM $TABLE;")
[ "$ROW_COUNT" -ne 10 ] && {
	echo "❌ Fehler: Erwartet 10 Zeilen, gefunden $ROW_COUNT"
	exit 1
}

MISSING_IDS=$(
	"$PG_BIN/psql" -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At <<EOF
SELECT count(*) FROM generate_series(1,10) s
WHERE NOT EXISTS (
  SELECT 1 FROM $TABLE t WHERE t.id = s
);
EOF
)
[ "$MISSING_IDS" -ne 0 ] && {
	echo "❌ Fehler: Fehlende IDs nach Recovery!"
	exit 1
}
echo "✅ Datenintegrität OK"

# -----------------------------
# 17: Cleanup
# -----------------------------
rm -f "$PGDATA/recovery.signal"
"$PG_BIN/pg_ctl" -D "$PGDATA" -m fast -w stop || true
rm -rf "$PGDATA" "$ARCHIVEDIR" "$BACKUPDIR"

echo "==> PITR Test erfolgreich abgeschlossen ✅"
