# frozen_string_literal: true

require "test_helper"

class QuotaTest < Minitest::Test
  # A clock we control, so the tests assert on arithmetic rather than on sleep.
  class FakeClock
    def initialize = @now = 0.0
    def call = @now
    def advance(seconds) = @now += seconds
  end

  def setup
    @clock = FakeClock.new
    @quota = DiscordStore::Transport::Quota.new(rate: 10, clock: -> { @clock.call })
  end

  def test_starts_full
    assert_in_delta 10.0, @quota.available
  end

  def test_permits_are_consumed
    3.times { @quota.acquire }

    assert_in_delta 7.0, @quota.available
  end

  def test_refills_at_the_configured_rate
    10.times { @quota.acquire }

    assert_in_delta 0.0, @quota.available

    @clock.advance(0.5)

    assert_in_delta 5.0, @quota.available
  end

  def test_never_refills_past_capacity
    @clock.advance(1000)

    assert_in_delta 10.0, @quota.available
  end

  def test_times_out_rather_than_waiting_forever
    # Real clock here on purpose: the deadline is measured with the same clock
    # that refills the bucket, so a frozen one would wait forever by definition.
    quota = DiscordStore::Transport::Quota.new(rate: 1)
    quota.acquire

    error = assert_raises(DiscordStore::QuotaTimeoutError) { quota.acquire(timeout: 0.01) }
    # The message has to say this is not a pool-size problem, because that is
    # the first thing anyone will try.
    assert_match(/larger pool will not fix it/, error.message)
  end

  def test_release_returns_a_permit
    5.times { @quota.acquire }
    @quota.release

    assert_in_delta 6.0, @quota.available
  end

  def test_release_cannot_inflate_the_budget
    20.times { @quota.release }

    assert_in_delta 10.0, @quota.available
  end

  def test_penalty_drains_and_holds
    @quota.penalize(5.0)

    assert_in_delta 0.0, @quota.available

    @clock.advance(2.0)

    assert_in_delta 0.0, @quota.available, 0.001, "still inside the penalty window"

    @clock.advance(4.0)

    assert_operator @quota.available, :>, 0.0
  end

  def test_is_safe_across_threads
    quota = DiscordStore::Transport::Quota.new(rate: 1000)
    counter = 0
    mutex = Mutex.new

    threads = 8.times.map do
      Thread.new do
        25.times do
          quota.acquire(timeout: 5)
          mutex.synchronize { counter += 1 }
        end
      end
    end
    threads.each(&:join)

    assert_equal 200, counter
  end
end
