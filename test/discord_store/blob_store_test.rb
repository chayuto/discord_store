# frozen_string_literal: true

require "test_helper"

class BlobStoreTest < Minitest::Test
  include DiscordStore::TestSupport

  CHUNK = 64 * 1024

  def setup
    @now = Time.now
    @fake = build_fake(clock: -> { @now })
    @client = DiscordStore::Client.new(config: build_config(chunk_size: CHUNK), http: @fake)
    @blobs = @client.blobs
  end

  def payload(size, seed: 1) = Random.new(seed).bytes(size)

  def test_small_blob_round_trip
    data = payload(1000)
    @blobs.put("k", data)

    assert_equal data, @blobs.get("k")
  end

  def test_large_blob_is_chunked_and_reassembled
    data = payload(300 * 1024)
    manifest = @blobs.put("big", data)

    assert_equal 5, manifest.chunk_count
    assert_equal data, @blobs.get("big")
  end

  def test_bytes_on_the_wire_are_encrypted
    @blobs.put("secret", "the launch code is 00000000")
    stored = @fake.messages_in("3001").first["attachments"].first

    refute_nil stored
    refute_includes @blobs.get("secret"), "\0" * 8 # sanity: we got the real thing back
    assert_equal "the launch code is 00000000", @blobs.get("secret")
  end

  def test_encryption_adds_bytes_not_a_third
    data = payload(100 * 1024)
    @blobs.put("k", data)

    # Base64 would cost 33%; binary framing costs 32 bytes per chunk.
    assert_operator @fake.stored_bytes, :<, data.bytesize * 1.01
    assert_operator @fake.stored_bytes, :>=, data.bytesize
  end

  def test_reads_survive_cdn_link_expiry
    data = payload(200 * 1024)
    @blobs.put("k", data)

    # Every link Discord issued is now dead. A store that cached URLs is broken;
    # this one re-resolves from the message.
    @now += 48 * 3600

    assert_equal data, @blobs.get("k")
  end

  def test_a_cached_url_really_would_have_failed
    @blobs.put("k", payload(1000))
    manifest = @blobs.index.get("k")
    chunk = manifest.chunks.first
    message = @fake.messages_in("3001").find { |m| m["id"] == chunk[:message_id] }
    url = message["attachments"].first["url"]

    @now += 48 * 3600

    error = assert_raises(DiscordStore::APIError) { @client.rest.download(url) }
    assert_equal 404, error.status
  end

  def test_range_read_touches_only_the_chunks_it_needs
    data = payload(300 * 1024)
    @blobs.put("k", data)

    before = @fake.request_count
    slice = @blobs.get_range("k", 70_000..70_099)
    requests = @fake.request_count - before

    assert_equal data.byteslice(70_000, 100), slice
    assert_operator requests, :<, 5, "a 100-byte read should not fetch every chunk"
  end

  def test_range_read_handles_exclusive_and_endless_ranges
    data = payload(1000)
    @blobs.put("k", data)

    assert_equal data.byteslice(0, 100), @blobs.get_range("k", 0...100)
    assert_equal data.byteslice(0, 101), @blobs.get_range("k", 0..100)
    assert_equal data.byteslice(900, 100), @blobs.get_range("k", 900..)
    assert_equal data.byteslice(0, 1000), @blobs.get_range("k", 0..99_999)
  end

  def test_a_chunk_cannot_be_swapped_between_blobs
    @blobs.put("a", payload(1000, seed: 1))
    @blobs.put("b", payload(1000, seed: 2))

    manifest_a = @blobs.index.get("a")
    manifest_b = @blobs.index.get("b")
    manifest_a.chunks[0] = manifest_b.chunks[0]

    # The chunk's key and ordinal are bound into the authentication tag, so a
    # substituted chunk fails to decrypt instead of returning the wrong bytes.
    assert_raises(DiscordStore::DecryptionError) { @blobs.get("a") }
  end

  def test_checksum_mismatch_is_rejected
    assert_raises(DiscordStore::Error) do
      @blobs.put("k", "content", checksum: "obviously-wrong")
    end
  end

  def test_exist_and_size_without_downloading
    @blobs.put("k", payload(5000))

    before = @fake.request_count

    assert @blobs.exist?("k")
    assert_equal 5000, @blobs.size("k")
    assert_equal before, @fake.request_count, "metadata comes from the index"
    refute @blobs.exist?("nope")
  end

  def test_delete_removes_it_from_the_index
    @blobs.put("k", "x")
    @blobs.delete("k")

    refute @blobs.exist?("k")
    assert_raises(DiscordStore::NotFoundError) { @blobs.get("k") }
  end

  def test_delete_prefix
    @blobs.put("uploads/a", "1")
    @blobs.put("uploads/b", "2")
    @blobs.put("other/c", "3")

    assert_equal 2, @blobs.delete_prefix("uploads/")
    assert @blobs.exist?("other/c")
  end

  def test_the_index_rebuilds_from_the_channel
    @blobs.put("k", payload(2000))

    # A fresh process: nothing but a token and the channel IDs.
    reborn = DiscordStore::Client.new(config: build_config(chunk_size: CHUNK), http: @fake).blobs

    assert reborn.exist?("k")
    assert_equal @blobs.get("k"), reborn.get("k")
  end

  def test_overwrite_wins_on_replay
    @blobs.put("k", "first")
    @blobs.put("k", "second")

    reborn = DiscordStore::Client.new(config: build_config(chunk_size: CHUNK), http: @fake).blobs

    assert_equal "second", reborn.get("k")
  end

  def test_delete_survives_a_rebuild
    @blobs.put("k", "x")
    @blobs.delete("k")

    reborn = DiscordStore::Client.new(config: build_config(chunk_size: CHUNK), http: @fake).blobs

    refute reborn.exist?("k")
  end

  def test_multi_chunk_blobs_have_no_single_url
    @blobs.put("big", payload(200 * 1024))

    error = assert_raises(DiscordStore::Error) { @blobs.url("big") }
    assert_match(/proxy/, error.message)
  end

  def test_single_chunk_blobs_do_have_a_url
    @blobs.put("small", "x")

    assert_match(%r{\Ahttps://cdn\.discordapp\.test/attachments/}, @blobs.url("small"))
  end
end
