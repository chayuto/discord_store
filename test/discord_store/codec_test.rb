# frozen_string_literal: true

require "test_helper"

class CodecTest < Minitest::Test
  include DiscordStore::TestSupport

  def setup
    @cipher = DiscordStore::Cipher.build(build_config)
    @codec = DiscordStore::Codec.new(cipher: @cipher, content_budget: 1900)
  end

  def record(data, stream: "s") = DiscordStore::Log::Record.new(stream: stream, data: data)

  def test_round_trip
    packed = @codec.pack([record({ "a" => 1 })], aad: "1001").first
    message = { "id" => "123", "channel_id" => "1001", "content" => packed[:content] }

    assert_equal [{ "a" => 1 }], @codec.unpack(message, aad: "1001").map(&:data)
  end

  def test_packs_many_records_into_few_messages
    records = (1..50).map { |i| record({ "i" => i }) }
    packed = @codec.pack(records, aad: "1001")

    assert_operator packed.size, :<, 10, "packing should beat one message per record by a lot"
    assert_equal(50, packed.sum { |m| m[:records].size })
  end

  def test_no_message_exceeds_discord_s_hard_limit
    records = (1..200).map { |i| record({ "i" => i, "pad" => "x" * 40 }) }

    @codec.pack(records, aad: "1001").each do |message|
      assert_operator message[:content].length, :<=,
                      DiscordStore::Configuration::MESSAGE_CONTENT_LIMIT
    end
  end

  def test_positions_are_assigned_within_a_message
    packed = @codec.pack([record({ "a" => 1 }), record({ "a" => 2 })], aad: "1001").first
    message = { "id" => "123", "channel_id" => "1001", "content" => packed[:content] }
    unpacked = @codec.unpack(message, aad: "1001")

    assert_equal [0, 1], unpacked.map(&:position)
    assert_equal %w[123:0000 123:0001], unpacked.map(&:cursor)
  end

  def test_oversized_records_spill_to_an_attachment
    packed = @codec.pack([record({ "blob" => "x" * 5000 })], aad: "1001")

    assert_equal 1, packed.size
    assert_equal 1, packed.first[:files].size
    assert_match(/\ADS1 s 1\z/, packed.first[:content])
  end

  def test_spilled_records_round_trip
    packed = @codec.pack([record({ "blob" => "x" * 5000 })], aad: "1001").first
    message = { "id" => "9", "channel_id" => "1001", "content" => packed[:content],
                "attachments" => [{ "id" => "1" }] }
    body = packed[:files].first[:content]

    assert_equal 5000, @codec.unpack(message, attachment_body: body, aad: "1001").first.data["blob"].length
  end

  def test_atomic_packing_refuses_to_split
    records = (1..500).map { |i| record({ "i" => i }) }

    error = assert_raises(DiscordStore::PayloadTooLargeError) do
      @codec.pack(records, aad: "1001", atomic: true)
    end
    assert_match(/commits all-or-nothing/, error.message)
  end

  def test_recognises_its_own_messages
    packed = @codec.pack([record({ "a" => 1 })], aad: "1001").first

    assert @codec.ours?({ "content" => packed[:content] })
    refute @codec.ours?({ "content" => "hey has anyone seen my keys" })
    refute @codec.ours?({ "content" => "" })
  end

  def test_a_truncated_message_is_detected_not_silently_accepted
    packed = @codec.pack([record({ "a" => 1 }), record({ "a" => 2 })], aad: "1001").first
    truncated = packed[:content].lines[0..1].join
    message = { "id" => "123", "channel_id" => "1001", "content" => truncated }

    assert_raises(DiscordStore::CorruptRecordError) { @codec.unpack(message, aad: "1001") }
  end

  def test_wrong_channel_fails_authentication
    packed = @codec.pack([record({ "a" => 1 })], aad: "1001").first
    message = { "id" => "123", "channel_id" => "2002", "content" => packed[:content] }

    assert_raises(DiscordStore::DecryptionError) { @codec.unpack(message, aad: "2002") }
  end
end
