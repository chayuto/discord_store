# frozen_string_literal: true

require "test_helper"

class KVTest < Minitest::Test
  include DiscordStore::TestSupport

  def setup
    @client, @fake = build_client
    @kv = @client.kv
  end

  def test_string_round_trip
    @kv.string("layout").set("cards")

    assert_equal "cards", @kv.string("layout").value
  end

  def test_overwriting_edits_the_message_instead_of_adding_one
    @kv.string("layout").set("cards")
    before = @fake.messages_in("2001").size
    5.times { |i| @kv.string("layout").set("v#{i}") }

    assert_equal before, @fake.messages_in("2001").size,
                 "an update is a message edit, not a new message"
    assert_equal "v4", @kv.string("layout").value
  end

  def test_typed_scalars_cast
    @kv.integer("count").set(42)
    @kv.boolean("on").set(true)
    @kv.json("blob").set({ "a" => [1, 2] })

    assert_equal 42, @kv.integer("count").value
    assert @kv.boolean("on").value
    assert_equal({ "a" => [1, 2] }, @kv.json("blob").value)
  end

  def test_missing_keys_are_nil
    assert_nil @kv.string("nope").value
    refute_predicate @kv.string("nope"), :exists?
  end

  def test_clear_removes_a_key
    @kv.string("k").set("v")
    @kv.string("k").clear

    assert_nil @kv.string("k").value
    refute_includes @kv.keys, "k"
  end

  def test_state_survives_a_fresh_process
    @kv.string("layout").set("cards")
    @kv.integer("count").set(7)

    reborn = DiscordStore::Client.new(config: build_config, http: @fake).kv

    assert_equal "cards", reborn.string("layout").value
    assert_equal 7, reborn.integer("count").value
  end

  def test_deleted_keys_stay_deleted_across_a_rebuild
    @kv.string("k").set("v")
    @kv.string("k").clear

    reborn = DiscordStore::Client.new(config: build_config, http: @fake).kv

    assert_nil reborn.string("k").value
  end

  def test_counter_sums_its_increments
    counter = @kv.counter("views")
    5.times { counter.increment }
    counter.increment(by: 10)
    counter.decrement(by: 3)

    assert_equal 12, counter.value
  end

  def test_concurrent_counters_do_not_lose_writes
    # The whole reason counters are append-only. Two clients, no coordination,
    # no compare-and-swap available, and nothing is lost.
    a = @kv.counter("shared")
    b = DiscordStore::Client.new(config: build_config, http: @fake).kv.counter("shared")

    10.times { a.increment }
    10.times { b.increment }

    assert_equal 20, a.value
    assert_equal 20, b.value
  end

  def test_a_last_write_wins_scalar_does_lose_them
    # The contrast that justifies the counter's existence.
    a = @kv.integer("naive")
    b = DiscordStore::Client.new(config: build_config, http: @fake).kv.integer("naive")
    a.set(0)
    b.set((b.value || 0) + 1)
    a.set((a.value(cached: true) || 0) + 1)

    assert_equal 1, a.value, "one of the two increments was lost, as designed"
  end

  def test_compaction_preserves_the_total
    counter = @kv.counter("views")
    20.times { counter.increment }

    assert_equal 20, counter.compact!
    assert_equal 20, counter.value

    counter.increment

    assert_equal 21, counter.value
  end

  def test_reset_sets_an_absolute_value
    counter = @kv.counter("views")
    5.times { counter.increment }
    counter.reset(amount: 100)

    assert_equal 100, counter.value
  end

  def test_list_append_and_remove
    list = @kv.list("recent")
    list.append("a", "b", "c")

    assert_equal %w[a b c], list.elements

    list.remove("b")

    assert_equal %w[a c], list.elements
    assert_equal 2, list.size
  end

  def test_list_survives_a_rebuild
    @kv.list("recent").append("x", "y")

    reborn = DiscordStore::Client.new(config: build_config, http: @fake).kv

    assert_equal %w[x y], reborn.list("recent").elements
  end

  def test_flag_marks_and_lapses
    flag = @kv.flag("onboarded")

    refute_predicate flag, :marked?

    flag.mark

    assert_predicate flag, :marked?

    flag.remove

    refute_predicate flag, :marked?
  end

  def test_flag_expiry_is_evaluated_on_read
    flag = @kv.flag("temp")
    flag.mark(expires_in: -1) # already lapsed

    refute_predicate flag, :marked?
  end
end
