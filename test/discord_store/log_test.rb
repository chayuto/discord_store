# frozen_string_literal: true

require "test_helper"

class LogTest < Minitest::Test
  include DiscordStore::TestSupport

  def setup
    @client, @fake = build_client
    @log = @client.log
  end

  def test_append_and_read
    @log.append(stream: "orders", data: { "id" => 1 })
    @log.append(stream: "orders", data: { "id" => 2 })

    assert_equal([1, 2], @log.read(stream: "orders").map { |r| r.data["id"] })
  end

  def test_lsn_is_the_message_id_and_carries_its_own_timestamp
    record = @log.append(stream: "orders", data: { "id" => 1 })

    assert DiscordStore::Snowflake.valid?(record.lsn)
    assert_in_delta Time.now.to_f, record.created_at.to_f, 5.0
  end

  def test_records_are_encrypted_on_the_wire
    @log.append(stream: "orders", data: { "card" => "4111111111111111" })
    content = @fake.messages_in("1001").first["content"]

    refute_includes content, "4111111111111111"
    refute_includes content, "card"
  end

  def test_plaintext_mode_is_readable_when_asked_for
    client, fake = build_client(build_fake, cipher: :none, secret_key: nil)
    client.log.append(stream: "audit", data: { "actor" => "alice" })

    assert_includes fake.messages_in("1001").first["content"], "alice"
  end

  def test_messages_from_other_people_are_skipped
    @log.append(stream: "orders", data: { "id" => 1 })
    @fake.seed_foreign_message("1001", content: "anyone up for a game")
    @fake.seed_foreign_message("1001", content: "DS1 i 1\\nnot really ours either")

    assert_equal 1, @log.read(stream: "orders").size
  end

  def test_batching_costs_far_fewer_requests_than_records
    records = (1..100).map { |i| DiscordStore::Log::Record.new(stream: "bulk", data: { "i" => i }) }
    before = @fake.request_count
    @log.append_all(records)
    requests = @fake.request_count - before

    assert_operator requests, :<, 20, "100 records should not cost 100 requests"
    assert_equal 100, @log.read(stream: "bulk").size
  end

  def test_transaction_lands_in_one_message
    written = @log.transaction do |tx|
      tx.append(stream: "orders", data: { "id" => 1 })
      tx.append(stream: "orders", data: { "id" => 2 })
      tx.append(stream: "orders", data: { "id" => 3 })
    end

    assert_equal 1, written.map(&:lsn).uniq.size, "an atomic batch is exactly one message"
    assert_equal [0, 1, 2], written.map(&:position)
  end

  def test_transaction_writes_nothing_when_the_block_raises
    before = @fake.messages_in("1001").size

    assert_raises(RuntimeError) do
      @log.transaction do |tx|
        tx.append(stream: "orders", data: { "id" => 1 })
        raise "nope"
      end
    end

    assert_equal before, @fake.messages_in("1001").size
  end

  def test_an_atomic_batch_may_not_span_partitions
    client, = build_client(build_fake, log_channel_ids: %w[1001 1002])
    log = client.log
    streams = %w[a b c d e f g h].group_by { |s| log.shard.for(s) }
    skip "single-partition assignment" if streams.size < 2

    a = streams.values[0].first
    b = streams.values[1].first

    error = assert_raises(DiscordStore::PayloadTooLargeError) do
      log.transaction do |tx|
        tx.append(stream: a, data: { "x" => 1 })
        tx.append(stream: b, data: { "x" => 2 })
      end
    end
    assert_match(/must share a partition/, error.message)
  end

  def test_resuming_from_a_cursor_yields_each_record_exactly_once
    (1..30).each { |i| @log.append(stream: "orders", data: { "id" => i }) }
    all = @log.read(stream: "orders")

    seen = []
    cursor = nil
    6.times do
      page = @log.read(stream: "orders", after: cursor, limit: 5)
      break if page.empty?

      seen.concat(page)
      cursor = page.last.cursor
    end

    assert_equal all.map(&:cursor), seen.map(&:cursor)
    assert_equal seen.map(&:cursor).uniq, seen.map(&:cursor), "no record delivered twice"
  end

  def test_resuming_mid_message_does_not_replay_the_batch
    written = @log.transaction do |tx|
      3.times { |i| tx.append(stream: "orders", data: { "id" => i }) }
    end

    # Resume from the middle of a packed message: the two after it, and no more.
    rest = @log.read(stream: "orders", after: written[0].cursor)

    assert_equal([1, 2], rest.map { |r| r.data["id"] })
  end

  def test_tip_reports_the_newest_cursor
    assert_nil @log.tip(stream: "orders")

    @log.append(stream: "orders", data: { "id" => 1 })
    last = @log.append(stream: "orders", data: { "id" => 2 })

    assert_equal last.cursor, @log.tip(stream: "orders")
  end

  def test_replace_edits_in_place_without_adding_a_message
    record = @log.append(stream: "kv", data: { "v" => "before" })
    before = @fake.messages_in("1001").size

    @log.replace(record, data: { "v" => "after" })

    assert_equal before, @fake.messages_in("1001").size
    assert_equal "after", @log.read(stream: "kv").first.data["v"]
  end

  def test_tombstones_are_appends_not_deletes
    record = @log.append(stream: "orders", data: { "id" => 1 })
    @log.tombstone(stream: "orders", target: record.cursor)

    records = @log.read(stream: "orders")

    assert_equal 2, records.size
    assert_predicate records.last, :tombstone?
  end

  def test_compaction_reports_before_it_deletes
    record = @log.append(stream: "orders", data: { "id" => 1 })
    @log.tombstone(stream: "orders", target: record.cursor)

    report = @log.compact(stream: "orders", dry_run: true)

    assert_equal 1, report[:tombstoned]
    assert_equal 0, report[:deleted]
    assert_equal 2, @fake.messages_in("1001").size, "a dry run deletes nothing"
  end

  def test_compaction_deletes_tombstoned_messages
    record = @log.append(stream: "orders", data: { "id" => 1 })
    @log.tombstone(stream: "orders", target: record.cursor)

    report = @log.compact(stream: "orders")

    assert_equal 1, report[:deleted]
    refute(@fake.messages_in("1001").any? { |m| m["id"] == record.lsn })
  end

  def test_large_records_spill_to_attachments_and_come_back
    @log.append(stream: "big", data: { "blob" => "x" * 20_000 })
    record = @log.read(stream: "big").first

    assert_equal 20_000, record.data["blob"].length
  end

  def test_retries_survive_a_rate_limit
    @fake.inject_rate_limits(count: 2)
    record = @log.append(stream: "orders", data: { "id" => 1 })

    assert_equal 1, @log.read(stream: "orders").first.data["id"]
    refute_nil record.lsn
  end
end
