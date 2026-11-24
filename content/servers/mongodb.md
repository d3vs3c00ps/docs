---
title: MongoDB
description: Replica sets, sharded clusters, the balancer and chunk sizing
tags: [servers, mongodb, database, replication, sharding]
type: howto
status: complete
---

# MongoDB

## Replica set

If you do not need to distribute load but simply want the data replicated, deploy
a **replica set**.

Replication is asynchronous — a write acknowledged by the primary is not yet
guaranteed to be on the secondaries. Use a write concern of `majority` if that
matters.

```ini
# /etc/mongodb.conf
# mongod server config file
port = 27017
bind_ip_all = true
dbpath = /opt/mongodb/
fork = true
replSet = rs0
logpath = /var/log/mongodb.log
logappend = yes
```

> [!note] This is the legacy INI config format
> MongoDB 2.6 introduced a YAML configuration file. `mongod` 8.0 still reads the
> INI form shown here, for backward compatibility, but the documentation only
> covers YAML. The modern equivalent:
>
> ```yaml
> net:
>   port: 27017
>   bindIpAll: true
> storage:
>   dbPath: /opt/mongodb
> replication:
>   replSetName: rs0
> systemLog:
>   destination: file
>   path: /var/log/mongodb.log
>   logAppend: true
> processManagement:
>   fork: true
> ```

> [!warning] `bind_ip_all`
> Since MongoDB 3.6, `mongod` and `mongos` listen on `localhost` only by default, so
> without a bind setting the members cannot reach each other and `rs.add()` fails.
> `bind_ip_all = true` listens on every interface; `bind_ip = localhost,<this host's
> address>` is narrower. Either way, firewall port 27017 and turn on access control (a
> `keyFile` shared by the members) before the set holds real data.

On the first node of the cluster:

```javascript
rs.initiate()
```

Then, **from that same node** (which is now the primary), add the others:

```javascript
rs.add("mongo-02:27017")
rs.add("mongo-03:27017")
```

> [!note] Only on the primary
> Membership is replicated: run `rs.add()` **only on the primary**, and only for the
> *other* members. `rs.initiate()` already added the first node.

Check the state:

```javascript
rs.status()
```

> [!note] `mongo` is now `mongosh`
> The legacy `mongo` shell was deprecated in MongoDB 5.0 and removed in 6.0. Use
> `mongosh`; the commands themselves are unchanged.

## Sharded cluster

A sharded cluster adds two more roles:

| Role | Responsibility |
| --- | --- |
| **mongos** | the router — determines where data lives and forwards queries to the right shard. Holds no data itself. |
| **config servers** (`mongod --configsvr`) | hold the cluster metadata: the chunk map that says which range lives on which shard |
| **shards** (`mongod --shardsvr`) | hold the actual data, each shard normally being its own replica set |

> [!note] Metadata
> Only the config servers, `mongod` processes started with `--configsvr`, hold the
> cluster metadata. A plain `mongod` shard server holds data.

`mongos` must listen on a different port from the shard `mongod` processes, since
it is what clients connect to.

### Config server

```ini
# /etc/mongodb_config.conf
port = 27019
bind_ip_all = true
dbpath = /opt/configdb/
fork = true
configsvr = true
replSet = csrs
logpath = /var/log/mongodb_config.log
logappend = yes
```

> [!note] `replSet` is required
> Current versions refuse to start a config server without it:
> `Cannot start a configsvr as a standalone server`.

Start it on the three config hosts, then initiate the config server replica set
once, from one of them (`mongosh --port 27019`):

```javascript
rs.initiate({
  _id: "csrs",
  configsvr: true,
  members: [
    { _id: 0, host: "mongo-01:27019" },
    { _id: 1, host: "mongo-02:27019" },
    { _id: 2, host: "mongo-03:27019" }
  ]
})
```

### mongos

```ini
# /etc/mongodb_mongos.conf
port = 27017
bind_ip_all = true
configdb = csrs/mongo-01:27019,mongo-02:27019,mongo-03:27019
fork = true
logpath = /var/log/mongos.log
logappend = yes
```

> [!note] Config servers must be a replica set
> From MongoDB 3.4 the config servers must be deployed as a replica set (CSRS), and
> `configdb` must be given in `<replSetName>/<host:port>,...` form. A bare host list
> is only valid for the removed SCCC mode.

### Shard

```ini
# /etc/mongodb_shard.conf
port = 27018
bind_ip_all = true
dbpath = /opt/mongodb/
fork = true
shardsvr = true
replSet = rs0
logpath = /var/log/mongodb.log
logappend = yes
```

Start it on the three shard hosts and initiate the shard's replica set, as in the
first section (`mongosh --port 27018`):

```javascript
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo-01:27018" },
    { _id: 1, host: "mongo-02:27018" },
    { _id: 2, host: "mongo-03:27018" }
  ]
})
```

Start `mongos` last: it waits until it can reach the config servers.

### Adding the shard's replica set to the cluster

Connect through `mongos`:

```javascript
sh.addShard("rs0/mongo-01:27018,mongo-02:27018,mongo-03:27018")
sh.enableSharding("database_name")
sh.status()
```

Then choose a shard key per collection — this is the decision that determines
whether sharding helps or hurts:

```javascript
sh.shardCollection("database_name.collection_name", { userId: "hashed" })
```

> [!warning] Do not edit `local.system.replset` directly
> Some guides reconfigure member hosts by reading, mutating and writing
> `db.system.replset` in the `local` database:
>
> ```javascript
> cfg = db.system.replset.findOne({_id:"rs0"})
> cfg.members[0].host = "mongo-01:27018"
> db.system.replset.update({_id:"rs0"}, cfg)
> ```
>
> Direct writes to that collection are unsupported and can corrupt the replica set.
> The supported path is `rs.reconfig()`:
>
> ```javascript
> cfg = rs.conf()
> cfg.members[0].host = "mongo-01:27018"
> rs.reconfig(cfg)
> ```

## The balancer

MongoDB's built-in load distribution spreads chunks across shards, giving
horizontal scaling.

Get the balancer state:

```javascript
sh.getBalancerState()
```

Check whether it is currently running:

```javascript
sh.isBalancerRunning()
```

Start and stop it:

```javascript
sh.startBalancer()
sh.stopBalancer()
```

Stopping it is useful during backups, to get a consistent dump.

Balancing can also be toggled for one collection:

```javascript
sh.enableBalancing("db_name.collection_name")
sh.disableBalancing("db_name.collection_name")
```

> [!note] Enabling is not the same as running
> `sh.enableBalancing()` marks a collection as eligible for balancing; migrations
> only happen when the balancer process itself runs, within its scheduling window.
> `sh.startBalancer()` controls the process.

## Changing the chunk size

The default is 128 MB since MongoDB 6.0 (64 MB before). Reducing it can help when migrations cause too much I/O at
once:

```javascript
use config
db.settings.updateOne(
    { _id: "chunksize" },
    { $set: { value: 32 } },
    { upsert: true }
)
```

> [!warning] `save()` is gone
> `db.settings.save({_id:"chunksize", value: <sizeInMB>})` does not work: `save()`
> belonged to the legacy `mongo` shell. `mongosh` does not have it
> (`TypeError: db.settings.save is not a function`): use `updateOne` with
> `upsert: true` as above.

Two caveats:

- The change only takes effect on insert or update, as chunks are only split when
  written to.
- A smaller chunk size means more splitting work per write, and more migrations.

> [!note] Balancing by data size
> MongoDB 6.0 replaced chunk-count balancing with data-size balancing, and the
> default chunk size became 128 MB. The `chunksize` document above still sets the
> cluster-wide value; one collection can have its own with
> `db.adminCommand({configureCollectionBalancing: "db.coll", chunkSize: 64})`.
> On 6.0+ prefer leaving it alone unless you have measured a reason.

<!-- uplink -->
Part of [[servers/index|Servers]].
