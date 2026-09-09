# Contributing

Thanks for looking. A few things about this project are unusual, so they are
worth stating before you spend time on a change.

## What this gem is

Discord is used as a write-ahead log; a local SQLite file is the materialized
view. That inversion is the whole design, and it is the reason the library is
not just a slow filesystem. Changes that move reads back onto the network need
to argue for themselves.

**Using Discord this way violates Discord's Terms of Service.** The gem refuses
to make a single request until you set
`i_understand_this_violates_discord_tos = true`. That guard is not decoration
and pull requests that soften, default, or work around it will be declined.

## Running the suite

No bot token, no network:

```sh
bin/setup
bundle exec rake          # tests + RuboCop
bundle exec rake test     # tests only
ruby -Ilib examples/replay_demo.rb
```

Everything runs against `DiscordStore::Transport::Fake`, an in-memory Discord
that models the behaviour which actually shapes this library — expiring CDN
links, nonce deduplication, the two-week bulk-delete window, 429s, messages from
other authors. If you are adding a feature that depends on some Discord
behaviour, teach the fake that behaviour first. A test that passes because the
fake is too generous is worse than no test.

## Every supported Rails version

```sh
bundle exec appraisal install     # regenerate gemfiles/
bundle exec appraisal rake        # the suite against Rails 7.2, 8.0 and 8.1
BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle exec rake   # just one
```

## The vendored conformance suite

`test/support/shared_service_tests.rb` is copied verbatim from Rails and is the
suite every first-party ActiveStorage service passes. Do not edit it to make it
pass — the value of running it is precisely that nobody here wrote it. If a case
genuinely cannot apply to a Discord-backed service, skip it explicitly in
`test/active_storage/discord_service_test.rb` with a comment saying why.

To refresh it for a newer Rails, re-download it and re-apply the provenance
header; the file says how.

## What is not verified

Three numbers are discovered at runtime rather than hardcoded, because
hardcoding them is how every previous library in this genre broke:

- the real attachment ceiling (`rake discord:probe`)
- whether the CDN honours HTTP `Range`
- real sharded throughput

None of them have been measured against live Discord. If you run this against a
real guild, a report of what you saw is more valuable than most code changes.

## House style

- RuboCop must pass. The config carries the deviations and why.
- Comments explain decisions, not mechanics. This library exists partly to
  argue for a set of choices, so the reasoning is part of the deliverable.
- YARD tags on public methods.
- Conventional-ish commit subjects, imperative mood, no trailers.
