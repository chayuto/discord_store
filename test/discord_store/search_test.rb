# frozen_string_literal: true

require "test_helper"

class SearchTest < Minitest::Test
  include DiscordStore::TestSupport

  def setup
    @fake = build_fake
    @client, = build_client(@fake)
  end

  def test_finds_our_own_messages_across_channels
    @client.log.append(stream: "a", data: { "n" => 1 })
    @client.blobs.put("photo", "x" * 200)

    result = @client.search.ours

    assert_operator result.size, :>=, 2
    assert(result.messages.all? { |m| m["content"].to_s.start_with?("DS1") })
  end

  def test_finds_attachments_by_extension
    @client.blobs.put("photo", "x" * 200)

    names = @client.search.attachments.messages
                   .flat_map { |m| m["attachments"].map { |a| a["filename"] } }

    assert_equal ["0.ds1"], names
  end

  # The guard that matters. Search reads across a guild rather than a channel it
  # was handed, so it is the one call that could turn this into a scraper.
  def test_refuses_to_search_for_another_author
    error = assert_raises(DiscordStore::SearchScopeError) do
      @client.search.messages(author_id: ["999999999999999999"])
    end

    assert_match(/own_messages_only is on/, error.message)
  end

  def test_author_is_pinned_on_the_request_itself
    @client.log.append(stream: "a", data: { "n" => 1 })
    @client.search.ours

    search = @fake.requests.reverse.find { |r| r.url.include?("/messages/search") }

    assert_includes search.url, "author_id=#{DiscordStore::TestSupport::APPLICATION_ID}"
  end

  def test_another_author_s_messages_are_never_returned
    @fake.seed_foreign_message("1001", content: "DS1 not ours")

    assert_empty(@client.search.ours.messages.reject { |m| m.dig("author", "id") == APPLICATION_ID })
  end

  # Discord answers 202 until it has indexed the guild. A write is durable when
  # create_message returns and findable some unspecified time later.
  def test_retries_through_an_unindexed_guild
    @client.log.append(stream: "a", data: { "n" => 1 })
    @fake.delay_search_index(count: 3)

    assert_operator @client.search.ours.size, :>=, 1
  end

  def test_gives_up_on_an_index_that_never_arrives
    @fake.delay_search_index(count: 99)

    assert_raises(DiscordStore::IndexNotReadyError) { @client.search.ours }
  end

  def test_a_missing_intent_says_so
    @fake.deny_search!

    error = assert_raises(DiscordStore::MissingIntentError) { @client.search.ours }

    assert_match(/MESSAGE_CONTENT/, error.message)
  end

  def test_results_never_claim_to_be_exact
    @client.log.append(stream: "a", data: { "n" => 1 })

    assert_predicate @client.search.ours, :approximate?
  end

  # Discord: "search may return slightly fewer results than the limit
  # specified", and clients "should not rely on the length of the messages
  # array to paginate results". Paging on offset survives that; paging on the
  # returned size does not.
  def test_paging_survives_an_index_that_under_returns
    30.times { |i| @client.log.append(stream: "a", data: { "n" => i }) }
    @fake.search_under_returns!

    walked = @client.search.each(content: "DS1").to_a

    refute_empty walked
    assert_equal walked.uniq { |m| m["id"] }.size, walked.size
  end

  def test_offset_beyond_discord_s_ceiling_is_refused
    assert_raises(ArgumentError) { @client.search.messages(offset: 10_000) }
  end

  # The floor exists so a 202 with retry_after 0 does not turn into a hot loop.
  # Everything else in this file sets it to zero; this one pays it once.
  def test_the_retry_floor_is_actually_honoured
    client, fake = build_client(nil, search_retry_floor: REAL_SEARCH_RETRY_FLOOR)
    client.log.append(stream: "a", data: { "n" => 1 })
    fake.delay_search_index(count: 1)

    started = Time.now
    client.search.ours

    assert_operator Time.now - started, :>=, REAL_SEARCH_RETRY_FLOOR
  end

  def test_searching_needs_a_guild
    config = build_config(guild_id: nil)

    assert_raises(DiscordStore::ConfigurationError) do
      DiscordStore::Search.new(rest: @client.rest, config: config)
    end
  end
end
