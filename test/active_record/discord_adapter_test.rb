# frozen_string_literal: true

require "test_helper"
require "active_record"
require "active_record/connection_adapters/discord_adapter"
require "fileutils"
require "tmpdir"

class DiscordAdapterTest < Minitest::Test
  include DiscordStore::TestSupport

  def setup
    @dir = Dir.mktmpdir("discord_store")
    @fake = build_fake
    @key = DiscordStore::Cipher.generate_key
    connect(Primary, "primary")
    define_schema
  end

  def teardown
    [Primary, Replica].each { |base| base.connection_pool.disconnect! if base.connected? }
    FileUtils.rm_rf(@dir)
  end

  class Primary < ActiveRecord::Base
    self.abstract_class = true
  end

  class Replica < ActiveRecord::Base
    self.abstract_class = true
  end

  class Shot < Primary
    self.table_name = "shots"
  end

  class ReplicaShot < Replica
    self.table_name = "shots"
  end

  def discord_options(**overrides)
    { i_understand_this_violates_discord_tos: true, token: "t",
      application_id: DiscordStore::TestSupport::APPLICATION_ID,
      secret_key: @key, log_channel_ids: ["9001"], http: @fake }.merge(overrides)
  end

  def connect(base, name, **overrides)
    base.establish_connection(
      adapter: "discord", database: File.join(@dir, "#{name}.sqlite3"),
      discord: discord_options(**overrides)
    )
  end

  def define_schema
    Primary.connection.create_table :shots, force: true do |t|
      t.string :club
      t.float :carry
      t.integer :spin
      t.binary :trace
      t.datetime :struck_at
    end
  end

  def seed
    Shot.create!(club: "7i", carry: 152.4, spin: 6800, trace: "\x00\xFF\x10".b,
                 struck_at: Time.utc(2026, 9, 9, 10, 30))
    Shot.create!(club: "Dr", carry: 268.1, spin: 2400)
    Primary.transaction do
      Shot.create!(club: "PW", carry: 118.0, spin: 9100)
      Shot.where(club: "7i").update_all(spin: 6750)
    end
    Shot.find_by(club: "Dr").destroy
  end

  def test_it_registers_as_an_adapter
    assert_equal "Discord", Primary.connection.adapter_name
  end

  def test_reads_are_ordinary_sql
    seed

    assert_equal 2, Shot.count
    assert_equal({ "7i" => 6750, "PW" => 9100 }, Shot.pluck(:club, :spin).to_h)
    # Aggregates and grouping work because the read side is just SQLite.
    assert_equal({ "7i" => 152.4, "PW" => 118.0 }, Shot.group(:club).sum(:carry))
  end

  def test_reads_cost_no_requests
    seed
    before = @fake.request_count
    Shot.where(carry: 100..200).order(:spin).to_a
    Shot.count

    assert_equal before, @fake.request_count, "a SELECT must never touch the network"
  end

  def test_a_transaction_is_one_message
    before = @fake.messages_in("9001").size
    Primary.transaction do
      Shot.create!(club: "a")
      Shot.create!(club: "b")
      Shot.create!(club: "c")
    end

    assert_equal 1, @fake.messages_in("9001").size - before
  end

  def test_the_first_statement_of_a_lazy_transaction_is_not_orphaned
    # Rails materialises a transaction on its first write, so that write reaches
    # the adapter before BEGIN does. It still belongs to the transaction.
    Primary.transaction do
      Shot.create!(club: "a")
      Shot.create!(club: "b")
    end

    entries = []
    Primary.connection.journal.each_transaction { |entry, _| entries << entry }
    last = entries.last

    assert_equal 2, last["tx"].size, "both statements belong to one journalled transaction"
  end

  def test_a_rolled_back_transaction_writes_nothing
    before = @fake.messages_in("9001").size

    # ActiveRecord::Rollback is swallowed by the transaction block by design,
    # so this asserts on the effects rather than on an exception.
    Primary.transaction do
      Shot.create!(club: "ghost")
      raise ActiveRecord::Rollback
    end

    assert_equal before, @fake.messages_in("9001").size,
                 "the log must not contain a transaction the database rolled back"
    assert_equal 0, Shot.where(club: "ghost").count
  end

  def test_an_exception_rollback_writes_nothing
    before = @fake.messages_in("9001").size

    assert_raises(RuntimeError) do
      Primary.transaction do
        Shot.create!(club: "ghost")
        raise "boom"
      end
    end

    assert_equal before, @fake.messages_in("9001").size
    assert_equal 0, Shot.where(club: "ghost").count
  end

  def test_replay_rebuilds_an_empty_database_exactly
    seed
    connect(Replica, "replica")

    assert_empty Replica.connection.tables

    report = Replica.connection.replay!

    assert_equal 0, report[:skipped]
    assert_includes Replica.connection.tables, "shots"

    expected = Shot.order(:id).map { |s| [s.club, s.carry, s.spin, s.trace, s.struck_at] }
    actual = ReplicaShot.order(:id).map { |s| [s.club, s.carry, s.spin, s.trace, s.struck_at] }

    assert_equal expected, actual
  end

  def test_binary_columns_survive_the_round_trip
    Shot.create!(club: "x", trace: (0..255).to_a.pack("C*"))
    connect(Replica, "replica")
    Replica.connection.replay!

    assert_equal (0..255).to_a.pack("C*"), ReplicaShot.find_by(club: "x").trace
  end

  def test_replay_is_idempotent
    seed
    connect(Replica, "replica")
    Replica.connection.replay!
    count = ReplicaShot.count

    second = Replica.connection.replay!

    assert_equal 0, second[:applied], "a replay with nothing new must apply nothing"
    assert_equal count, ReplicaShot.count
  end

  def test_replay_resumes_from_where_it_stopped
    seed
    connect(Replica, "replica")
    Replica.connection.replay!

    Shot.create!(club: "late", carry: 1.0)
    report = Replica.connection.replay!

    assert_equal 1, report[:applied]
    assert_equal 1, ReplicaShot.where(club: "late").count
  end

  def test_replay_does_not_append_to_the_log
    seed
    before = @fake.messages_in("9001").size
    connect(Replica, "replica")
    Replica.connection.replay!

    assert_equal before, @fake.messages_in("9001").size,
                 "a replay that writes to the log would grow it on every restart"
  end

  def test_async_mode_batches_transactions_into_fewer_messages
    connect(Replica, "async", journal_mode: :async)
    conn = Replica.connection
    before = @fake.messages_in("9001").size

    conn.create_table :things, force: true
    20.times { |i| conn.execute("INSERT INTO things DEFAULT VALUES /* #{i} */") }
    conn.flush_journal!

    added = @fake.messages_in("9001").size - before

    assert_operator added, :<, 21, "async mode should pack many transactions per message"
    assert_equal 0, conn.journal.pending_count
  end

  def test_off_mode_writes_nothing
    connect(Replica, "off", journal_mode: :off)
    before = @fake.messages_in("9001").size
    Replica.connection.create_table :local_only, force: true

    assert_equal before, @fake.messages_in("9001").size
    refute_predicate Replica.connection.journal, :recording?
  end

  def test_a_write_ahead_log_refuses_to_be_sharded
    connect(Replica, "sharded", log_channel_ids: %w[9001 9002])

    error = assert_raises(DiscordStore::ConfigurationError) { Replica.connection.journal }
    assert_match(/one total order/, error.message)
  end

  def test_savepoints_are_refused_while_journalling
    error = assert_raises(DiscordStore::Error) do
      Primary.transaction do
        Shot.create!(club: "a")
        Primary.transaction(requires_new: true) { Shot.create!(club: "b") }
      end
    end
    assert_match(/cannot be un-sent/, error.message)
  end

  def test_log_status_reports_both_ends
    seed
    status = Primary.connection.log_status

    assert_equal Primary.connection.log_tip, status[:remote_cursor]
    assert_equal :sync, status[:mode]
  end
end
