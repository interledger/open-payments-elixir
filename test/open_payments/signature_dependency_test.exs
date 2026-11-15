defmodule OpenPayments.SignatureDependencyTest do
  use ExUnit.Case, async: true

  alias MessageSignatures.Message

  # Public test key and expected signature from RFC 9421, Appendix B.2.6.
  @pem """
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIJ+DYvh6SEqVTm50DFtMDoQikTmiCqirVv9mWG9qfSnF
  -----END PRIVATE KEY-----
  """
  @signature "wqcAqbmYJ2ji2glfAMaRy4gruYYnx2nEFN2HN6jrnDnQCK1u02Gb04v9EDgwUPiu4A0w6vuQv5lIp5WPpBKRCw=="
  @created 1_618_884_473

  test "Ed25519 signing reproduces RFC 9421 Appendix B.2.6 byte for byte" do
    {:ok, key} = MessageSignatures.Key.from_pem(@pem, :ed25519)

    message =
      Message.from_request(
        method: :post,
        url: "https://example.com/foo?param=Value&Pet=dog",
        headers: [
          {"date", "Tue, 20 Apr 2021 02:07:55 GMT"},
          {"content-type", "application/json"},
          {"content-length", "18"}
        ]
      )

    assert {:ok, headers} =
             MessageSignatures.sign(message,
               key: key,
               key_id: "test-key-ed25519",
               label: "sig-b26",
               components: ~w(date @method @path @authority content-type content-length),
               params: [created: @created]
             )

    assert Map.new(headers)["signature"] == "sig-b26=:#{@signature}:"
  end
end
