# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

module DiscordStore
  # Payload encryption.
  #
  # Discord's own Developer Terms require that end-user data stored off-platform
  # be encrypted at rest, so a library that stores data *on* the platform has no
  # excuse for shipping plaintext as the default. Encryption is also the only
  # thing standing between your records and every member of the guild who can
  # scroll up.
  #
  # AES-256-GCM, not the AES-256-CBC that earlier Discord filesystems used: GCM
  # authenticates, so a member with Manage Messages who edits one of our messages
  # produces a decryption failure rather than silently corrupted data.
  module Cipher
    # Envelope prefix, so the format can change without ambiguity later.
    VERSION_TAG = "ds1"
    SEPARATOR = "."
    IV_BYTES = 12
    TAG_BYTES = 16
    ALGORITHM = "aes-256-gcm"

    # Builds the cipher named by +config+.
    #
    # @param config [DiscordStore::Configuration]
    # @return [#seal, #open]
    def self.build(config)
      case config.cipher
      when :none then Null.new
      when :aes_256_gcm then AES256GCM.new(config.secret_key_bytes)
      else
        raise ConfigurationError, "unknown cipher #{config.cipher.inspect}"
      end
    end

    # Generates a fresh key, base64-encoded and ready to paste into an
    # environment variable.
    #
    # @return [String]
    def self.generate_key
      Base64.strict_encode64(SecureRandom.bytes(32))
    end

    # Passthrough. Writes readable JSON into the channel: good for a log you
    # want humans to read in the Discord client, wrong for anything else.
    class Null
      def seal(plaintext, aad: nil) = plaintext.to_s
      def open(ciphertext, aad: nil) = ciphertext.to_s
      def seal_binary(plaintext, aad: nil) = plaintext.to_s
      def open_binary(ciphertext, aad: nil) = ciphertext.to_s
      def encrypting? = false
      def overhead = 0
      def binary_overhead = 0
    end

    # Authenticated encryption over a compact, markdown-safe envelope:
    #
    #   ds1.<iv>.<tag>.<ciphertext>     (each field urlsafe base64, unpadded)
    #
    # Base64url is used rather than standard base64 because Discord renders
    # message content as markdown, and the urlsafe alphabet contains no
    # characters the renderer will try to interpret.
    class AES256GCM
      def initialize(key)
        raise ConfigurationError, "encryption key is missing" if key.nil?
        raise ConfigurationError, "encryption key must be 32 bytes" unless key.bytesize == 32

        @key = key
      end

      def encrypting? = true

      # Worst-case added length for a given plaintext size, so the packer can
      # decide whether a record still fits in a message before encrypting it.
      #
      # @return [Integer]
      def overhead
        # version tag + 3 separators + base64(iv) + base64(tag), plus the ~4/3
        # expansion of the ciphertext itself, which the packer accounts for.
        VERSION_TAG.bytesize + 3 + b64_len(IV_BYTES) + b64_len(TAG_BYTES)
      end

      # @param plaintext [String]
      # @param aad [String, nil] additional authenticated data; bound into the
      #   tag but not stored. Pass the channel ID to make a record undecryptable
      #   if it is moved to another channel.
      # @return [String]
      def seal(plaintext, aad: nil)
        cipher = OpenSSL::Cipher.new(ALGORITHM).encrypt
        cipher.key = @key
        iv = cipher.random_iv
        cipher.auth_data = aad.to_s
        ciphertext = cipher.update(plaintext.to_s) + cipher.final

        [VERSION_TAG, encode(iv), encode(cipher.auth_tag), encode(ciphertext)].join(SEPARATOR)
      end

      # @param ciphertext [String] an envelope produced by {#seal}
      # @param aad [String, nil] must match the value passed to {#seal}
      # @return [String]
      # @raise [DecryptionError] if the envelope is malformed, was written with
      #   a different key, or has been tampered with
      def open(ciphertext, aad: nil)
        version, iv, tag, body = ciphertext.to_s.split(SEPARATOR, 4)

        unless version == VERSION_TAG && iv && tag && body
          raise DecryptionError, "not a #{VERSION_TAG} envelope"
        end

        cipher = OpenSSL::Cipher.new(ALGORITHM).decrypt
        cipher.key = @key
        cipher.iv = decode(iv)
        cipher.auth_tag = decode(tag)
        cipher.auth_data = aad.to_s
        cipher.update(decode(body)) + cipher.final
      rescue OpenSSL::Cipher::CipherError
        raise DecryptionError,
              "payload failed authentication: wrong key, wrong channel, or the " \
              "message was edited by someone with Manage Messages"
      rescue ArgumentError => e
        raise DecryptionError, "malformed envelope: #{e.message}"
      end

      # Attachments are binary, so they skip base64 entirely.
      #
      #   DS1B | iv (12 bytes) | tag (16 bytes) | ciphertext
      #
      # Text envelopes have to survive being message content, which is why they
      # are base64. Paying that 33% on an attachment would mean uploading four
      # bytes for every three stored, against a rate limit that is already the
      # binding constraint.
      BINARY_MAGIC = "DS1B"

      # @param plaintext [String]
      # @param aad [String, nil]
      # @return [String] binary
      def seal_binary(plaintext, aad: nil)
        cipher = OpenSSL::Cipher.new(ALGORITHM).encrypt
        cipher.key = @key
        iv = cipher.random_iv
        cipher.auth_data = aad.to_s
        ciphertext = cipher.update(plaintext.to_s) + cipher.final

        (+"").force_encoding(Encoding::BINARY) << BINARY_MAGIC << iv << cipher.auth_tag << ciphertext
      end

      # @param blob [String] binary, as produced by {#seal_binary}
      # @param aad [String, nil]
      # @return [String]
      # @raise [DecryptionError]
      def open_binary(blob, aad: nil)
        iv, tag, body = split_binary(blob)

        cipher = OpenSSL::Cipher.new(ALGORITHM).decrypt
        cipher.key = @key
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = aad.to_s
        cipher.update(body) + cipher.final
      rescue OpenSSL::Cipher::CipherError
        raise DecryptionError, "attachment failed authentication: wrong key, or the bytes were altered"
      end

      # @return [Integer] bytes added to a binary payload
      def binary_overhead = BINARY_MAGIC.bytesize + IV_BYTES + TAG_BYTES

      private

      # @return [Array(String, String, String)] iv, tag and ciphertext
      def split_binary(blob)
        blob = blob.to_s.dup.force_encoding(Encoding::BINARY)
        raise DecryptionError, "not a #{BINARY_MAGIC} payload" unless blob.start_with?(BINARY_MAGIC)

        offset = BINARY_MAGIC.bytesize
        iv = blob.byteslice(offset, IV_BYTES)
        tag = blob.byteslice(offset + IV_BYTES, TAG_BYTES)
        body = blob.byteslice(offset + IV_BYTES + TAG_BYTES, blob.bytesize) || +""

        raise DecryptionError, "payload is truncated" if iv.nil? || tag.nil? || tag.bytesize < TAG_BYTES

        [iv, tag, body]
      end

      def encode(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

      def decode(string) = Base64.urlsafe_decode64(string)

      def b64_len(bytes) = ((bytes * 4) / 3.0).ceil
    end
  end
end
