defmodule OpenPayments.Signature.HeadersTest do
  use ExUnit.Case, async: true

  alias MessageSignatures.Message
  alias OpenPayments.{Error, Key}
  alias OpenPayments.Signature.{ContentHeaders, Headers}

  @fixtures File.read!(Path.expand("../../fixtures/signatures/node-signatures.json", __DIR__))
            |> Jason.decode!()
  @keys File.read!(Path.expand("../../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()
  @created 1_618_884_473

  test "reproduces deterministic Node signature headers and verifies their independent bases" do
    public = Base.url_decode64!(@keys["public_jwk"]["x"], padding: false)

    for fixture <- @fixtures["cases"] do
      {:ok, key} = Key.from_pem(@keys["ed25519"], fixture["key_id"])
      message = request(fixture)
      body_present? = not is_nil(fixture["body_base64"])

      assert Headers.build(key, message, body_present?, fixture["created"]) ==
               {:ok, fixture["signature_headers"]},
             fixture["name"]

      "sig1=:" <> encoded = fixture["signature_headers"]["signature"]
      signature = encoded |> String.trim_trailing(":") |> Base.decode64!()

      assert :crypto.verify(:eddsa, :none, fixture["signature_base"], signature, [
               public,
               :ed25519
             ])
    end
  end

  test "covers authorization with any header casing and content fields for a present body" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")
    {:ok, content} = ContentHeaders.build("")

    for name <- ["authorization", "Authorization", "AuThOrIzAtIoN"] do
      message =
        Message.from_request(
          method: :post,
          url: "https://wallet.example.com/tenant",
          headers: [{name, "GNAP public-test-token"} | Map.to_list(content)]
        )

      assert {:ok, headers} = Headers.build(key, message, true, @created)

      assert headers["signature-input"] ==
               ~s|sig1=("@method" "@target-uri" "authorization" "content-digest" "content-length" "content-type");keyid="key-1";created=1618884473|
    end
  end

  test "signs requests without an access token or body using only method and target URI" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")
    message = Message.from_request(method: :get, url: "https://wallet.example.com/tenant")
    assert {:ok, headers} = Headers.build(key, message, false, @created)

    assert headers["signature-input"] ==
             ~s|sig1=("@method" "@target-uri");keyid="key-1";created=1618884473|
  end

  test "requires all three content fields when a body is present" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")
    {:ok, content} = ContentHeaders.build("{}")

    for field <- ~w(content-digest content-length content-type) do
      message =
        Message.from_request(
          method: :post,
          url: "https://wallet.example.com/tenant",
          headers: content |> Map.delete(field) |> Map.to_list()
        )

      assert {:error, %Error{kind: :signing, code: "component_not_found"}} =
               Headers.build(key, message, true, @created)
    end
  end

  test "accepts the structured-field timestamp boundaries and rejects invalid timestamps" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")
    message = Message.from_request(method: :get, url: "https://wallet.example.com/tenant")

    for created <- [0, 999_999_999_999_999] do
      assert {:ok, headers} = Headers.build(key, message, false, created)
      assert String.ends_with?(headers["signature-input"], ";created=#{created}")
    end

    for created <- [-1, 1_000_000_000_000_000, 1.0, "1", nil, true] do
      assert {:error, %Error{validation_errors: [%{field: :created}]}} =
               Headers.build(key, message, false, created)
    end
  end

  test "reports invalid input types without dependency exceptions" do
    response = Message.from_response(status: 200)

    for message <- [
          response,
          nil,
          %Message{kind: :request},
          %Message{kind: :request, method: "GET"}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: issues}} =
               Headers.build(nil, message, nil, nil)

      assert Enum.map(issues, & &1.field) == [:key, :request, :body_present, :created]
    end
  end

  test "rejects key IDs that cannot be represented as RFC structured-field strings" do
    message = Message.from_request(method: :get, url: "https://wallet.example.com/tenant")

    for id <- ["key-α", "key-\r\nprivate-input-must-not-leak"] do
      {:ok, key} = Key.from_pem(@keys["ed25519"], id)

      assert {:error, %Error{kind: :signing, code: "malformed_signature_input"} = error} =
               Headers.build(key, message, false, @created)

      refute inspect(Map.from_struct(error)) =~ "private-input-must-not-leak"
    end
  end

  test "dependency and crypto failures do not retain authorization values or private key bytes" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")

    message =
      Message.from_request(
        method: :get,
        url: "https://wallet.example.com/tenant",
        headers: [{"authorization", "GNAP private-token-must-not-leak\r\ninvalid"}]
      )

    assert {:error, %Error{kind: :signing, code: "malformed_field_value"} = error} =
             Headers.build(key, message, false, @created)

    assert error.details == nil
    refute inspect(Map.from_struct(error)) =~ "private-token-must-not-leak"

    message = Message.from_request(method: :get, url: "https://wallet.example.com/tenant")
    invalid_key = %{key | private_key: "private-seed-must-not-leak"}

    assert {:error, %Error{kind: :signing} = error} =
             Headers.build(invalid_key, message, false, @created)

    refute inspect(Map.from_struct(error)) =~ "private-seed-must-not-leak"
  end

  test "independent Node signature fails verification after covered request or parameter tampering" do
    fixture = Enum.find(@fixtures["cases"], &(&1["name"] == "unicode-body"))
    assert {:ok, _} = verify_fixture(fixture)
    {:ok, changed_content} = ContentHeaders.build(~s({"message":"changed"}))

    tampered = [
      Map.put(fixture, "method", "PUT"),
      Map.put(fixture, "url", fixture["url"] <> "?changed=1"),
      put_in(fixture, ["headers", "authorization"], "GNAP changed-test-token"),
      put_in(fixture, ["headers", "content-digest"], changed_content["content-digest"]),
      put_in(fixture, ["headers", "content-length"], "999"),
      put_in(fixture, ["headers", "content-type"], "text/plain"),
      update_in(
        fixture,
        ["signature_headers", "signature-input"],
        &String.replace(&1, "1618884473", "1618884474")
      )
    ]

    for changed <- tampered do
      assert {:error, %MessageSignatures.Error{reason: :signature_mismatch}} =
               verify_fixture(changed)
    end
  end

  defp request(fixture) do
    Message.from_request(
      method: fixture["method"],
      url: fixture["url"],
      headers: Map.to_list(fixture["headers"])
    )
  end

  defp verify_fixture(fixture) do
    public = Base.url_decode64!(@keys["public_jwk"]["x"], padding: false)
    headers = Map.merge(fixture["headers"], fixture["signature_headers"])
    message = request(Map.put(fixture, "headers", headers))

    MessageSignatures.verify(message,
      key_resolver: fn _id, _context -> {:ok, {:ed25519, public}} end,
      now: @created,
      policy: [
        required_components:
          ~w(@method @target-uri authorization content-digest content-length content-type)
      ]
    )
  end
end
