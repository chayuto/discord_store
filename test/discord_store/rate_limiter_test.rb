# frozen_string_literal: true

require "test_helper"

class RateLimiterTest < Minitest::Test
  def setup
    @limiter = DiscordStore::Transport::RateLimiter.new(rate: 1000)
  end

  def test_learns_a_bucket_from_response_headers
    @limiter.acquire("POST /channels/1/messages")
    @limiter.observe("POST /channels/1/messages", {
                       "X-RateLimit-Bucket" => "abc123",
                       "X-RateLimit-Limit" => "5",
                       "X-RateLimit-Remaining" => "4",
                       "X-RateLimit-Reset-After" => "5.0"
                     })

    state = @limiter.inspect_buckets.fetch("POST /channels/1/messages")

    assert_equal "abc123", state[:hash_key]
    assert_equal 5, state[:limit]
    assert_equal 4, state[:remaining]
  end

  def test_routes_sharing_a_bucket_hash_share_one_window
    ["GET /channels/1", "GET /channels/2"].each do |route|
      @limiter.acquire(route)
      @limiter.observe(route, { "X-RateLimit-Bucket" => "shared", "X-RateLimit-Remaining" => "3",
                                "X-RateLimit-Limit" => "5", "X-RateLimit-Reset-After" => "5" })
    end

    # Both routes now point at the same Bucket object, so drawing one down
    # draws down the other. Keeping separate counts would over-issue.
    @limiter.acquire("GET /channels/1")
    @limiter.acquire("GET /channels/1")
    remaining = @limiter.inspect_buckets.fetch("GET /channels/2")[:remaining]

    assert_equal 1, remaining
  end

  def test_takes_the_pessimistic_view_of_remaining
    @limiter.acquire("POST /x")
    @limiter.observe("POST /x", { "X-RateLimit-Bucket" => "b", "X-RateLimit-Limit" => "5",
                                  "X-RateLimit-Remaining" => "1", "X-RateLimit-Reset-After" => "5" })
    # A later response reporting a higher remaining must not raise our estimate:
    # requests already in flight are not reflected in the server's count.
    @limiter.observe("POST /x", { "X-RateLimit-Bucket" => "b", "X-RateLimit-Limit" => "5",
                                  "X-RateLimit-Remaining" => "4", "X-RateLimit-Reset-After" => "5" })

    assert_equal 1, @limiter.inspect_buckets.fetch("POST /x")[:remaining]
  end

  def test_global_429_penalises_the_token_not_the_route
    wait = @limiter.penalize("POST /y", { "X-RateLimit-Global" => "true", "Retry-After" => "0.05" })

    assert_in_delta 0.05, wait
    assert_in_delta 0.0, @limiter.quota.available
  end

  def test_scoped_429_penalises_only_the_route
    @limiter.penalize("POST /z", { "X-RateLimit-Scope" => "user", "X-RateLimit-Reset-After" => "0.05" })

    assert_operator @limiter.quota.available, :>, 0.0, "the token budget is untouched"
    assert_equal 0, @limiter.inspect_buckets.fetch("POST /z")[:remaining]
  end

  def test_recognises_both_spellings_of_a_global_limit
    assert @limiter.global?({ "X-RateLimit-Global" => "true" })
    assert @limiter.global?({ "x-ratelimit-scope" => "global" })
    refute @limiter.global?({ "x-ratelimit-scope" => "user" })
  end
end
