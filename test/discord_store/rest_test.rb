# frozen_string_literal: true

require "test_helper"

class RestTest < Minitest::Test
  include DiscordStore::TestSupport

  def setup
    @client, @fake = build_client
    @rest = @client.rest
  end

  def test_verify_catches_a_mismatched_application_id
    client, = build_client(build_fake, application_id: "222222222222222222")

    error = assert_raises(DiscordStore::ConfigurationError) { client.verify! }
    # This misconfiguration is otherwise invisible: every write succeeds and
    # every read comes back empty.
    assert_match(/silently return nothing/, error.message)
  end

  def test_reading_someone_else_s_message_by_id_is_refused
    message = @fake.seed_foreign_message("1001", content: "private")

    assert_raises(DiscordStore::ForeignMessageError) { @rest.get_message("1001", message["id"]) }
  end

  def test_listing_filters_out_other_authors
    @rest.create_message("1001", content: "ours")
    @fake.seed_foreign_message("1001", content: "theirs")

    contents = @rest.list_messages("1001").map { |m| m["content"] }

    assert_equal ["ours"], contents
  end

  def test_the_guard_can_be_disabled_explicitly
    client, fake = build_client(build_fake, own_messages_only: false, application_id: nil)
    fake.seed_foreign_message("1001", content: "theirs")

    assert_equal 1, client.rest.list_messages("1001").size
  end

  def test_nonce_deduplicates_a_retried_write
    first = @rest.create_message("1001", content: "x", nonce: "stable")
    second = @rest.create_message("1001", content: "x", nonce: "stable")

    assert_equal first["id"], second["id"]
    assert_equal 1, @fake.messages_in("1001").size
  end

  def test_bulk_delete_reports_what_was_too_old
    fresh = @rest.create_message("1001", content: "new")["id"]
    # A snowflake from a month ago: past the two-week bulk-delete window.
    stale = DiscordStore::Snowflake.from_time(Time.now - (30 * 24 * 3600)).to_s

    too_old = @rest.bulk_delete_messages("1001", [fresh, stale])

    assert_equal [stale], too_old
    assert_empty @fake.messages_in("1001")
  end

  def test_a_429_is_retried_and_succeeds
    @fake.inject_rate_limits(count: 3)

    assert_equal "ok", @rest.create_message("1001", content: "ok")["content"]
  end

  def test_retries_are_bounded
    client, fake = build_client(build_fake, max_retries: 2)
    fake.inject_rate_limits(count: 10)

    assert_raises(DiscordStore::ExhaustedError) { client.rest.create_message("1001", content: "x") }
  end

  def test_it_actually_waits_for_discord_s_real_channel_window
    client, = build_client(build_fake(rate_limit: REAL_CHANNEL_LIMIT))
    rest = client.rest

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    6.times { |i| rest.create_message("1001", content: "m#{i}") }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    # Five messages per five seconds means the sixth cannot go out immediately.
    # This is the number that caps the whole library, and it is not tunable.
    assert_operator elapsed, :>, 4.0,
                    "the limiter let a sixth message through inside the window"
  end
end
