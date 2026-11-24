---
title: MySQL
description: Resetting a lost root password and setting up passwordless backups with a dedicated user
tags: [servers, mysql, database, backup, security]
type: howto
status: complete
---

# MySQL

## Testing the configuration

```bash
mysqld --validate-config
mysqld --defaults-file=/root/test-my.cnf --validate-config
```

`--validate-config` (MySQL 8.0.16 and later) reads the option files, reports
unknown or invalid options and exits. On MariaDB, which has no such option, use
`mariadbd --verbose --help 1>/dev/null`. See [[servers/config-validation]] for
other daemons.

## Resetting the root password

Whether on a first install or after losing the main MySQL password, you need a way
to change the administrative (`root`) password.

To change it you have to be able to connect — and without the current password
that is circular. Fortunately MySQL can be started with authentication bypassed.

> [!warning] This makes the server wide open while it runs
> During the window below, anyone who can reach the process has full access
> without a password. Do it on a maintenance window, and keep `--skip-networking`
> so only local sockets are accepted. On production, avoid it if there is any other
> route in.

### Restart the server without authentication

Stop MySQL (the unit is `mysqld` on RHEL; `mysql` or `mariadb` elsewhere):

```bash
systemctl stop mysqld
```

Start it by hand as the `mysql` user, bypassing authentication and with
networking disabled:

```bash
runuser -u mysql -- /usr/libexec/mysqld --skip-grant-tables --skip-networking &
```

`/usr/libexec/mysqld` is the server binary on RHEL; it is `/usr/sbin/mysqld` on
most other systems. Since MySQL 8.0, `--skip-grant-tables` also turns on
`--skip-networking` by itself, but saying it does no harm.

> [!note] No `mysqld_safe`
> `mysqld_safe` is not installed with MySQL on systemd-based RPM systems such as
> RHEL 10, where systemd supervises `mysqld` directly.

### Reset the password

Connect — no password will be asked:

```bash
mysql -u root
```

Then, on **MySQL 5.7 and later**:

```sql
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY 'new-password';
```

> [!warning] `ALTER USER`, after `FLUSH PRIVILEGES`
> `UPDATE user SET password=PASSWORD('...')` no longer works: the `password` column was
> renamed `authentication_string` in MySQL 5.7, and `PASSWORD()` was **removed in
> 8.0**. Under `--skip-grant-tables` the grant tables are not loaded, so `ALTER USER`
> fails until you run `FLUSH PRIVILEGES` first, which is why the order above matters.

Stop the server you started by hand, then start the service normally:

```bash
mysqladmin -u root -p shutdown
systemctl start mysqld
```

> [!warning] Shut it down first
> systemd does not know the hand-started server. With it still running,
> `systemctl restart mysqld` fails, because the socket is in use.

## Backing up without supplying a password

Create a dedicated `backup` user with only the privileges a dump needs:

```sql
CREATE USER 'backup'@'localhost' IDENTIFIED BY 'backup-password';

GRANT RELOAD ON *.* TO 'backup'@'localhost';
GRANT REPLICATION CLIENT ON *.* TO 'backup'@'localhost';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'backup'@'localhost';
GRANT CREATE TEMPORARY TABLES ON mysql.* TO 'backup'@'localhost';

FLUSH PRIVILEGES;
```

> [!note] `SUPER` is deliberately not granted
> It would allow far more than a backup needs. `RELOAD` plus `LOCK TABLES` is
> enough for a consistent dump, and `REPLICATION CLIENT` is only needed if you want
> binlog coordinates recorded.

Store the credentials in the backup user's own option file so the password never
appears on a command line — where it would be visible in `ps` and shell history:

```ini
# ~/.my.cnf
[mysqldump]
user = backup
password = backup-password
```

Lock it down:

```bash
chmod 600 ~/.my.cnf
```

Then as the `backup` user, schedule the dump:

```bash
crontab -e
```

```cron
0 5 * * * mysqldump --single-transaction --events --all-databases | gzip -9 > /backup/mysql/$(date +\%d-\%m)-db.sql.gz
```

> [!important] `--single-transaction` for InnoDB
> Without it `mysqldump` locks every table for the duration of the dump. With it,
> InnoDB tables are dumped from a consistent snapshot without blocking writes. Note
> it does **not** apply to MyISAM tables, which still need `--lock-all-tables`.
>
> Also note `%` must be escaped as `\%` in a crontab, or cron truncates the command
> at the first one.

<!-- uplink -->
Part of [[servers/index|Servers]].
