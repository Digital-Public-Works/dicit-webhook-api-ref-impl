require "openssl"
# Example signature verifier
module SignatureVerifier
  def self.generate(body, timestamp, api_key)
    payload = "#{timestamp}:#{body}"
    OpenSSL::HMAC.hexdigest(
      OpenSSL::Digest.new("sha512"),
      api_key.encode("utf-8"),
      payload
    )
  end

  def self.verify(body, timestamp, signature, api_key)
    return false if body.nil? || timestamp.nil? || signature.nil? || api_key.nil?

    expected = generate(body, timestamp, api_key)
    secure_compare(expected, signature)
  end

  def self.secure_compare(a, b)
    return false unless a.bytesize == b.bytesize
    l = a.unpack("C*")
    r = b.unpack("C*")
    result = 0
    l.zip(r) { |x, y| result |= x ^ y }
    result.zero?
  end
end
