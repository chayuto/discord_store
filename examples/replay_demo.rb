# frozen_string_literal: true

# Rebuild a SQLite database from a Discord channel.
#
#   ruby -Ilib examples/replay_demo.rb
#
# Runs against an in-memory Discord, so it needs no bot token and touches no
# network. Point it at a real guild by swapping `http: FAKE` for real
# credentials; nothing else in the script changes.
#
# The argument this makes: Discord is not being used as a database here, it is
# being used as the write-ahead log. Every statement that changes data is
# appended to a channel, encrypted, and the local SQLite file is a materialized
# view of that log. So reads are ordinary SQL at ordinary speed -- joins,
# aggregates, indexes, no network -- and the durable record of what happened
# lives somewhere that was never meant to hold it.
#
# The proof is at the bottom: a second database, on an empty file, that has
# never seen the first one, reconstructed from the channel alone.

require "fileutils"
require "tmpdir"
require "active_record"
require "active_record/connection_adapters/discord_adapter"

DIR = Dir.mktmpdir("discord-store-demo")
at_exit { FileUtils.remove_entry(DIR) }

APPLICATION_ID = "111111111111111111"
FAKE = DiscordStore::Transport::Fake.new(application_id: APPLICATION_ID)
SECRET_KEY = DiscordStore.generate_key

def discord_options
  {
    i_understand_this_violates_discord_tos: true,
    token: "fake-token",
    application_id: APPLICATION_ID,
    secret_key: SECRET_KEY,
    log_channel_ids: ["9001"],
    http: FAKE # drop this line to talk to the real Discord
  }
end

def heading(text) = puts("\n#{text}\n#{"-" * text.length}")

# -- 1. An ordinary Rails application -----------------------------------------

ActiveRecord::Base.establish_connection(
  adapter: "discord", database: File.join(DIR, "primary.sqlite3"), discord: discord_options
)

heading "Connection"
puts "adapter: #{ActiveRecord::Base.connection.adapter_name}"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :shots, force: true do |t|
    t.string   :club
    t.float    :carry
    t.integer  :spin
    t.binary   :trace
    t.datetime :struck_at
    t.timestamps
  end
end

class Shot < ActiveRecord::Base; end

Shot.create!(club: "7i", carry: 152.4, spin: 6800,
             trace: "\x00\xFF\x10".b, struck_at: Time.utc(2026, 9, 9, 10, 30))
Shot.create!(club: "Dr", carry: 268.1, spin: 2400,
             trace: "\x01\x02".b, struck_at: Time.utc(2026, 9, 9, 10, 35))

ActiveRecord::Base.transaction do
  Shot.create!(club: "PW", carry: 118.0, spin: 9100)
  Shot.where(club: "7i").update_all(spin: 6750)
end

Shot.where(club: "Dr").first.destroy

heading "Writes went through Rails, unchanged"
puts "rows:       #{Shot.count}"
puts "aggregate:  #{Shot.group(:club).sum(:carry)}"
puts "messages:   #{FAKE.messages_in("9001").size} in the channel"
puts "log tip:    #{ActiveRecord::Base.connection.log_tip}"

# -- 2. A new machine, an empty disk, the same channel ------------------------

heading "Rebuilding somewhere else, from Discord alone"

class Replica < ActiveRecord::Base
  self.abstract_class = true
end

Replica.establish_connection(
  adapter: "discord", database: File.join(DIR, "replica.sqlite3"), discord: discord_options
)
replica = Replica.connection

puts "tables before: #{replica.tables.inspect}"
puts "replay:        #{replica.replay!.inspect}"
puts "tables after:  #{(replica.tables - ["discord_store_journal"]).inspect}"

class ReplicaShot < Replica
  self.table_name = "shots"
end

columns = ->(model) { model.order(:id).map { |s| [s.club, s.carry, s.spin, s.trace, s.struck_at] } }
primary_rows = columns.call(Shot)
replica_rows = columns.call(ReplicaShot)

heading "Result"
puts "primary:  #{primary_rows.inspect}"
puts "replica:  #{replica_rows.inspect}"
puts "identical: #{primary_rows == replica_rows}"

# Replaying twice must not double-apply. The cursor is stored in the replica, so
# this is also what makes replay resumable after a crash halfway through.
puts "replaying again applies: #{replica.replay![:applied]}"
