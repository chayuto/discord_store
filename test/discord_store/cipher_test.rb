# frozen_string_literal: true

require "test_helper"

class CipherTest < Minitest::Test
  def setup
    @cipher = DiscordStore::Cipher::AES256GCM.new(
      Base64.strict_decode64(DiscordStore::Cipher.generate_key)
    )
  end

  def test_round_trip
    assert_equal "hello", @cipher.open(@cipher.seal("hello"))
  end

  def test_envelope_is_markdown_safe
    envelope = @cipher.seal("*bold* _italic_ ```code```")

    # Base64url only. Discord renders content as markdown, and an envelope that
    # contained * or _ would be mangled on display and, worse, on some clients.
    assert_match(/\Ads1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/, envelope)
  end

  def test_envelope_never_contains_a_newline
    100.times do
      refute_includes @cipher.seal(SecureRandom.hex(200)), "\n"
    end
  end

  def test_tampering_is_detected
    envelope = @cipher.seal("balance: 100")
    version, iv, tag, body = envelope.split(".")
    flipped = body.sub(/.\z/) { |c| c == "A" ? "B" : "A" }

    assert_raises(DiscordStore::DecryptionError) do
      @cipher.open([version, iv, tag, flipped].join("."))
    end
  end

  def test_aad_binds_the_payload_to_its_channel
    envelope = @cipher.seal("secret", aad: "channel-1")

    assert_equal "secret", @cipher.open(envelope, aad: "channel-1")
    # Moving the message to another channel makes it undecryptable.
    assert_raises(DiscordStore::DecryptionError) { @cipher.open(envelope, aad: "channel-2") }
  end

  def test_another_key_cannot_read_it
    other = DiscordStore::Cipher::AES256GCM.new(Base64.strict_decode64(DiscordStore::Cipher.generate_key))

    assert_raises(DiscordStore::DecryptionError) { other.open(@cipher.seal("secret")) }
  end

  def test_binary_payloads_skip_base64
    bytes = Random.new(1).bytes(4096)
    sealed = @cipher.seal_binary(bytes)

    assert_equal bytes, @cipher.open_binary(sealed)
    # 32 bytes of framing, not a third of the payload.
    assert_equal bytes.bytesize + @cipher.binary_overhead, sealed.bytesize
  end

  def test_binary_tampering_is_detected
    sealed = @cipher.seal_binary("payload")
    sealed.setbyte(sealed.bytesize - 1, sealed.getbyte(sealed.bytesize - 1) ^ 0xFF)

    assert_raises(DiscordStore::DecryptionError) { @cipher.open_binary(sealed) }
  end

  def test_null_cipher_is_a_passthrough
    null = DiscordStore::Cipher::Null.new

    assert_equal "plain", null.open(null.seal("plain"))
    refute_predicate null, :encrypting?
  end
end
