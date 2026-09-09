# discord_store

[![CI](https://github.com/chayuto/discord_store/actions/workflows/main.yml/badge.svg)](https://github.com/chayuto/discord_store/actions/workflows/main.yml)
[![Gem Version](https://badge.fury.io/rb/discord_store.svg)](https://rubygems.org/gems/discord_store)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D.svg)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/rails-7.2%20%7C%208.0%20%7C%208.1-D30001.svg)](https://rubyonrails.org)

Uses Discord as a database.

It works. The data goes in, the data comes back out, ActiveRecord can query it,
ActiveStorage can serve files from it, and a machine with an empty disk can
rebuild the whole database from a chat channel and a bot token.

You should almost certainly not use it.

---

## Read this part first

Storing application data in Discord messages and attachments is an explicit
violation of the [Discord Developer Terms of Service][tos] and the
[Discord API Developer Policy][policy]. Discord has acted against this class of
project before — in late 2023 it began signing CDN links with an expiring HMAC,
which broke essentially every Discord-backed filesystem in existence within
about twenty-four hours — and it can revoke your bot token, remove your
application, and action your account without warning.

This library will not make a network request until you say so in code:

```ruby
DiscordStore.configure do |config|
  config.i_understand_this_violates_discord_tos = true
end
```

Do not put this in an application you did not build for yourself, and do not put
anybody else's data in it.

[tos]: https://support-dev.discord.com/hc/en-us/articles/8562894815383-Discord-Developer-Terms-of-Service
[policy]: https://support-dev.discord.com/hc/en-us/articles/8563934450327-Discord-Developer-Policy

### What it will not do

discord_store only ever reads messages **its own bot wrote**. That check lives in
code, not in this README:

```ruby
# lib/discord_store/transport/rest.rb
def own_message?(message)
  message.dig("author", "id").to_s == config.application_id.to_s
end
```

There is no message search, no member enumeration, no history export, and there
will not be. The distance between a storage backend and a scraper is exactly
whether it can read other people's messages, and this one cannot.

---

## The honest numbers

| | |
|---|---|
| Write throughput | ~1 transaction/second (5 messages per 5 seconds, per channel) |
| Bulk throughput | ~12 log records per request when batched |
| Object storage | a few MiB/s, hard-capped by rate limits nobody can raise for you |
| Read latency (adapter) | SQLite speed — reads never touch the network |
| Durability | at the pleasure of a company that owes you nothing |
| Transactions | one message = one atomic append; that is all there is |
| Deletes | expensive, and worse after 14 days |

If those numbers work for your problem, your problem is small enough that
SQLite would also have worked, and SQLite does not have a Terms of Service.

---

## Why it isn't a stunt

The naive version of this idea maps a channel to a table and scans it for every
query. That version tops out in the single-digit megabytes per second and cannot
do a join, because Discord gives a bot no query interface at all: no `WHERE`, no
index, no server-side filter. There is a channel, and you may page through it a
hundred messages at a time.

So Discord is not asked to be a query engine here. It is asked to be a durable,
replicated, ordered **write-ahead log** — which it is unexpectedly good at — and
a local SQLite file is the materialized view you actually query.

```
   writes ──▶ Discord channel (the log, source of truth)
                    │
                    └── replay ──▶ SQLite file (the materialized view)
                                        ▲
   reads ───────────────────────────────┘
```

That is a materialized view over a replicated log, which is a normal thing that
normal systems do. The unusual part is only where the log segment lives.

The test that decides whether this is a real design:

```
$ rm storage/production.sqlite3 && rake discord:replay
replayed 9 transactions (10 statements) in 0.3s
```

Binary columns, timestamps, schema and all, on any machine, from nothing but a
token and a channel ID.

### Three things Discord is accidentally good at

**Snowflake IDs are a real clustered primary key.** Message IDs encode a
millisecond timestamp in their high bits and are monotonic within a channel, so
the log sequence number, the `created_at`, and cursor pagination are all free.
Better still, a wall-clock range maps onto an ID range, and Discord's
`before`/`after` parameters take snowflakes — so "everything written between
09:00 and 10:00" is a server-side range scan, not a client-side filter.

```ruby
DiscordStore::Snowflake.at(175928847299117063)
# => 2016-04-30 11:18:25 UTC

# a synthetic bound that sorts exactly where a real ID would
DiscordStore::Snowflake.from_time(Time.utc(2026, 9, 9))
```

**Editing is a real UPDATE.** A bot can edit its own messages forever, so a
mutable value is one message that gets rewritten, not a delete-and-reinsert.

**Deleting is not.** Bulk deletion only covers messages under two weeks old;
past that it is one request per message against the limit that was already
binding. So the cheap way to retire a record is to append a marker saying it is
gone and let readers skip it.

That marker is a tombstone. Cassandra — the database Discord itself ran on —
does exactly this, for exactly this reason, and the volume of tombstones a chat
app generates is precisely what made Cassandra untenable for them and forced
their migration to ScyllaDB. Building a store on Discord means writing
tombstones into a database whose tombstones are stored as tombstones.

Compaction is therefore not optional. `rake discord:compact STREAM=orders`.

---

## Compatibility

| | |
|---|---|
| Ruby | 3.1, 3.2, 3.3, 3.4 |
| Rails | 7.2, 8.0, 8.1 — for the ActiveRecord and ActiveStorage layers |

The gem itself depends on no part of Rails; the adapters are optional and load
only if you require them. `base64` is the single runtime dependency, and only
because it leaves the default gems in Ruby 3.4.

The Rails floor is 7.2 and it is a hard one:
`ActiveRecord::ConnectionAdapters.register` arrived in 7.2, and registering an
adapter before that means defining a `discord_connection` factory method
instead. Supporting both paths is possible; claiming to support both without
running the suite against both is not.

CI runs every supported combination — ten of them — on every push.

## Install

```ruby
# Gemfile
gem "discord_store"
```

```sh
gem install discord_store   # no Bundler, no Rails: the log and blob store
                            # work on their own
```

The version number is an honest 0. Three values in here are discovered at
runtime rather than hardcoded — the real attachment ceiling, whether the CDN
honours HTTP `Range`, and sharded throughput — and none of them has been
measured against a live guild. That is deliberate, because hardcoding them is
exactly how every previous library in this genre broke, but it does mean the
library has never met the thing it is named after. `rake discord:doctor` and
`rake discord:probe` are how you find out; reports are welcome.

Create a bot, invite it to a server you own with **Send Messages**, **Read
Message History** and **Manage Messages**, and make some channels for it.

```bash
$ rake discord:key
K7XmPq2vN8wLdR4tYbG9hJfE3sA6uZcW1nT5oI0pQxM=
```

```ruby
DiscordStore.configure do |config|
  config.i_understand_this_violates_discord_tos = true
  config.token           = ENV.fetch("DISCORD_BOT_TOKEN")
  config.application_id  = ENV.fetch("DISCORD_APPLICATION_ID")
  config.guild_id        = ENV.fetch("DISCORD_GUILD_ID")
  config.secret_key      = ENV.fetch("DISCORD_STORE_KEY")
  config.log_channel_ids = ["1234567890123456789"]
end

DiscordStore.client.verify!
```

`rake discord:doctor` checks the token, the channels, and the attachment ceiling.

---

## The four layers

Each is usable on its own.

### L0 — Transport

A rate-limit-aware REST client. It learns Discord's bucket topology from
response headers rather than hardcoding a table of limits that will be wrong by
next quarter, honours `X-RateLimit-Scope` on 429s, and retries with full jitter.

The interesting part is what replaces the connection pool. A conventional
adapter checks out a socket, because sockets are scarce and the database will
answer as fast as you can ask. Over an HTTP API the opposite holds: connections
are free and *permission to ask* is what runs out. So the checkout primitive is
a semaphore over quota, `pool:` in `database.yml` means nothing, and the timeout
error says so:

> waited 15.0s for Discord request quota (45/s) and never got it. This is not a
> connection pool problem and a larger pool will not fix it.

Connections are cached per fiber, not per thread — under a fiber scheduler two
fibers on one thread would otherwise interleave bytes on one socket.

### L1 — Log

An encrypted, append-only log across one or more channels.

```ruby
log = DiscordStore.client.log

log.append(stream: "orders", data: { id: 1, total: 9.99 })

log.transaction do |tx|          # one message = one atomic append
  tx.append(stream: "orders", data: { id: 2 })
  tx.append(stream: "orders", data: { id: 3 })
end

log.read(stream: "orders", after: cursor, limit: 100)
```

Records are packed many-per-message (a message holds 2000 characters, and a
request that carries one 80-byte record spends the same permit as one carrying
twenty), encrypted with AES-256-GCM, and spilled to an attachment when too
large. Retries are deduplicated by Discord itself using the message `nonce`.

**Channels are partitions.** More channels means more throughput, because the
harshest limit is per-channel — and it means less ordering, because message IDs
are only ordered *within* a channel. So the promise is Kafka's: total order
within a partition, none across them, and a stream always lands in the same
partition. Rendezvous hashing, so adding a channel moves 1/n of the streams
rather than most of them.

### L2a — ActiveStorage

```yaml
# config/storage.yml
discord:
  service: Discord
  token: <%= ENV["DISCORD_BOT_TOKEN"] %>
  application_id: <%= ENV["DISCORD_APPLICATION_ID"] %>
  secret_key: <%= ENV["DISCORD_STORE_KEY"] %>
  blob_channel_ids: ["...", "..."]
  manifest_channel_id: "..."
  i_understand_this_violates_discord_tos: true
```

```ruby
# config/environments/production.rb
config.active_storage.resolve_model_to_route = :rails_storage_proxy
```

That last line is the whole reason this layer is worth building on Rails.

When Discord started signing CDN links with an expiring HMAC, every project that
had stored URLs in a database broke about a day later. The community's fix was
to deploy caching proxies on Cloudflare Workers that re-fetch the message and
hand back a fresh link — which works, and which concedes the entire premise,
because the storage is only free if you ignore the server you now have to run.

Rails has shipped that proxy for years. It is
`ActiveStorage::Blobs::ProxyController`. In proxy mode the browser gets a Rails
URL that never expires, and the Discord link is re-resolved per request,
server-side, where it belongs.

This library never stores a URL — only `channel_id`, `message_id` and
`attachment_id` — and resolves at read time. Redirect mode works, but only for
blobs small enough to be a single attachment: a blob split across attachments has
no single URL, and there is no honest way to invent one.

### L2b — ActiveRecord

```yaml
# config/database.yml
production:
  adapter: discord
  database: storage/production.sqlite3
  discord:
    i_understand_this_violates_discord_tos: true
    token: <%= ENV["DISCORD_BOT_TOKEN"] %>
    application_id: <%= ENV["DISCORD_APPLICATION_ID"] %>
    secret_key: <%= ENV["DISCORD_STORE_KEY"] %>
    log_channel_ids: ["1234567890123456789"]
```

Every write is mirrored to the channel; every read is served by SQLite. Joins,
indexes, aggregates and migrations all work, because SQLite does them.

```bash
rake discord:status     # how far behind the local file is
rake discord:replay     # rebuild it from the channel
rake discord:compact STREAM=wal DRY_RUN=1
```

Three details that are load-bearing:

- **The log is written before SQLite commits, not after.** There is no two-phase
  commit between a SQLite file and a chat server, so one has to go first, and it
  has to be the one that can reconstruct the other.
- **Savepoints are refused while journalling.** A sent message cannot be
  un-sent, so a rolled-back savepoint would still replay.
- **`journal_mode:`** is `:sync` (one message per transaction, ~1 tx/s),
  `:async` (batched, ~12 tx/s, with a durability window), or `:off`.

### L3 — KV

Kredis-shaped values, with the storage strategy chosen per type according to
what Discord can actually promise.

```ruby
kv = DiscordStore.client.kv

kv.string("layout").set("cards")   # one message, edited in place
kv.counter("views").increment      # an append; sums on read
kv.list("recent").append("a", "b")
kv.flag("onboarded").mark(expires_in: 1.hour)
```

Scalars are last-write-wins, because Discord has no compare-and-swap and there is
no way to build one on top of message editing. Counters are append-only for that
exact reason: two processes incrementing at once both count, because appends do
not collide. It is the reason distributed systems reach for CRDTs, arrived at
from the same constraint.

```ruby
a.increment  # from one process
b.increment  # from another, no coordination
a.value      # => 2
```

---

## What does not work

- **No server-side query.** Anything not in the local view means scanning a
  channel.
- **No cross-partition atomicity.** One message is the largest all-or-nothing
  unit that exists.
- **No compare-and-swap**, so no safe read-modify-write on a document.
- **No direct upload.** Every byte goes through your application.
- **Anyone with Manage Messages can delete your database** from the Discord
  client, and `NotFoundError` is a routine occurrence rather than an exceptional
  one. AES-GCM at least means tampering surfaces as a decryption failure instead
  of silently corrupt data.
- **Non-deterministic SQL** (`RANDOM()`, `CURRENT_TIMESTAMP`) will not replay
  identically. The adapter warns when it journals one.
- **The attachment ceiling moves.** It has been 8 MiB, 25 MB and 10 MB, and
  published write-ups disagree because each was right when written. This library
  discovers it from the guild's boost tier, and `rake discord:probe` measures it
  empirically.

---

## Testing without a token

The whole stack runs against an in-memory Discord, including the parts that only
break in production:

```ruby
fake = DiscordStore::Transport::Fake.new(application_id: "111111111111111111")
client = DiscordStore::Client.new(config: my_config, http: fake)
```

It models monotonic snowflakes, nonce deduplication, the 14-day bulk-delete
window, rate-limit headers and 429s on demand, messages from other authors — and
CDN links that carry a real expiry and stop working when it passes. Code that
caches a URL instead of re-resolving it fails in the test suite rather than in
production a day after deploy:

```ruby
@now += 48 * 3600
assert_equal data, @blobs.get("k")   # passes: it re-resolves
```

```sh
bundle exec rake              # 145 tests and RuboCop, no network
bundle exec appraisal rake    # the same, against Rails 7.2, 8.0 and 8.1
ruby -Ilib examples/replay_demo.rb
```

### Somebody else's tests

Everything above tests this library against expectations this library's author
wrote down, which is a closed loop. So the suite also vendors
[Rails' own ActiveStorage conformance tests][shared] verbatim and points them at
the Discord service — the same suite Disk, S3, GCS and Azure have to pass,
written by people who have never heard of this gem and have no stake in it
passing.

It found two real bugs on the first run. `compose` was simply missing. And
streaming downloads were yielding one Discord chunk at a time — sized by the
guild's attachment ceiling, 8 MiB to 100 MiB — where every other service yields
5 MB slices and Rails asserts it exactly. That is storage geometry leaking into
an interface, and no test written from inside this project was ever going to
catch it.

All 14 pass, with nothing skipped.

[shared]: https://github.com/rails/rails/blob/v8.1.3.1/activestorage/test/service/shared_service_tests.rb

---

## Prior art

This is a Ruby entry in a long tradition, and the interesting parts of the design
came from reading what broke for everyone else: `discord-fs` for chunking and
journaling, `DiscordFS` for streaming rather than buffering, `discord-drive` for
the semaphore-bounded concurrency, `discbase` and `Discord_DB` for the mapping,
and `discord-cdn-proxy` for the re-resolution trick that Rails turns out to ship
already.

The tombstone observation is owed to Discord's own engineering write-ups on
migrating from Cassandra to ScyllaDB.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
