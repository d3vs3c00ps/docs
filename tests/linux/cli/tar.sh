#!/usr/bin/env bash
# note: linux/cli/tar.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/tar
cd "$(mktemp -d)"
echo "SELECT 1;" >dump.sql
echo "[mysqld]" >my.cnf
echo "full" >dump_complete.sql
mkdir -p /etc/ssh && echo "Port 22" >/etc/ssh/sshd_config   # the container has no sshd

section "Creating"
check "uncompressed archive (from the note)" bash -ec "$(note_block "$NOTE" Creating 1)"
check "gzip archive (from the note)" bash -ec "$(note_block "$NOTE" Creating 2 | sed -n 1p)"
check "-a with .tar.zst (from the note)" bash -ec "$(note_block "$NOTE" Creating 2 | sed -n 2p)"
check_output "-a picked zstd from the name" 'Zstandard' file backup.tar.zst
check_output "-f last in the group: -cfv takes 'v' as the file name" '^v$' \
  bash -c 'tar -cfv x.tar dump.sql 2>/dev/null; ls v 2>/dev/null'
check "an archive from -C / (from the note)" bash -ec "$(note_block "$NOTE" Creating 3)"
check_output "stores etc/ssh relative" '^etc/ssh/' tar -tf etc-backup.tar.gz
mkdir -p project/.git && echo x >project/a.log && echo y >project/keep.txt && echo z >project/.git/HEAD
check "--exclude (from the note)" bash -ec "$(note_block "$NOTE" Creating 4)"
list=$(tar -tf project.tar.gz)
assert_match "keeps the other files" 'project/keep.txt' "$list"
assert_no_match "leaves out *.log" '\.log$' "$list"
assert_no_match "leaves out .git" '\.git' "$list"
check_output "an absolute path prints the note's message" "Removing leading \`/' from member names" \
  bash -c 'tar -czf abs.tar.gz /etc/ssh 2>&1'
check_output "and stores the name without /" '^etc/ssh/' tar -tf abs.tar.gz

section "Listing"
check_output "tar -tvf on a .tar.gz, no -z (from the note)" 'dump\.sql' bash -ec "$(note_block "$NOTE" Listing 1)"
check_output "same command on a .tar.zst" 'dump\.sql' tar -tvf backup.tar.zst
tar -cJf backup.tar.xz dump.sql
check_output "and on a .tar.xz" 'dump\.sql' tar -tvf backup.tar.xz

section "Extracting"
mkdir x && cp backup.tar.gz x/ && (cd x && bash -ec "$(note_block "$NOTE" Extracting 1)" >/dev/null)
check "tar -xvf extracts a .tar.gz without -z" test -f x/my.cnf
mkdir y && cp backup.tar.gz y/ && (cd y && bash -ec "$(note_block "$NOTE" Extracting 2)" >/dev/null)
check "extract a single file" test -f y/dump.sql
check_fails "and only that file" test -e y/my.cnf
mkdir -p app-1.2/bin && echo app >app-1.2/bin/run && tar -czf app-1.2.tar.gz app-1.2
check "extract with -C and --strip-components (from the note)" bash -ec "$(note_block "$NOTE" Extracting 3)"
check "the top directory is gone" test -f /opt/app/bin/run

section "Owners and permissions"
useradd -m alice
echo s >secret && chmod 640 secret && chown 1234:1234 secret
tar -cf /tmp/perms.tar secret && chmod 644 /tmp/perms.tar
mkdir r && tar -xf /tmp/perms.tar -C r
check_output "as root, tar -x restores the stored owner and mode" '^1234:1234 640$' stat -c '%u:%g %a' r/secret
as_alice() { runuser -u alice -- bash -c "cd ~ && rm -f secret && umask 077 && $1 && stat -c '%U %a' secret"; }
check_output "as a normal user, the file is theirs and the umask applies" '^alice 600$' as_alice 'tar -xf /tmp/perms.tar'
check_output "-p keeps the stored mode for a normal user" '^alice 640$' as_alice 'tar -xpf /tmp/perms.tar'
check_output "--numeric-owner stores the ID, not the name" '1234/1234' \
  bash -c 'tar -cf n.tar --numeric-owner secret && tar -tvf n.tar'

section "Incremental backups"
mkdir data && echo a >data/a && echo b >data/b
check "full then incremental (from the note)" bash -ec "$(note_block "$NOTE" 'Incremental' 1 | sed -n 1p)"
echo c >data/c && rm data/b
check "the incremental run" bash -ec "$(note_block "$NOTE" 'Incremental' 1 | sed -n 2p)"
list=$(tar -tf incr-1.tar.gz)
assert_match "the incremental archive has the new file" 'data/c' "$list"
assert_no_match "and not the unchanged one" 'data/a$' "$list"
mkdir restore && tar -xf full.tar.gz -g /dev/null -C restore && tar -xf incr-1.tar.gz -g /dev/null -C restore
check "restoring full then incremental gives the new file" test -f restore/data/c
check_fails "and replays the deletion" test -e restore/data/b

section "Modifying an existing archive"
check "append a file (from the note)" bash -ec "$(note_block "$NOTE" 'Modifying' 1)"
check_output "it is in the archive" 'dump_complete\.sql' tar -tf backup.tar
check "remove it (from the note)" bash -ec "$(note_block "$NOTE" 'Modifying' 2)"
check_fails "it is gone" bash -c 'tar -tf backup.tar | grep -q dump_complete'
check_output "on a .tar.gz, -r stops with the note's message" 'Cannot update compressed archives' \
  bash -c 'tar -rzf backup.tar.gz dump_complete.sql 2>&1; true'
check_fails "and --delete fails too" tar -zf backup.tar.gz --delete dump.sql

section "bsdtar"
zypper -n -q install --no-recommends bsdtar >/dev/null
check_fails "bsdtar has no --delete" bsdtar -f backup.tar --delete dump.sql
check_fails "and no -g (incremental)" bsdtar -czf b.tar.gz -g b.snar data
check_output "it detects the compression when reading" 'dump\.sql' bsdtar -tf backup.tar.zst
check "and has -a" bsdtar -caf b.tar.xz dump.sql
check_output "which picks the compression from the name" 'XZ compressed' file b.tar.xz
check "bsdtar also accepts --zstd" bsdtar --zstd -cf b.tar.zst dump.sql
