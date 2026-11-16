defmodule OpenPayments.KeyJWKTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Key}
  alias OpenPayments.Types.{JWK, JWKS}

  @fixtures File.read!(Path.expand("../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()
  @jwk @fixtures["private_jwk"]

  test "imports Node's private JWK and preserves its public identity and signature" do
    assert {:ok, key} = Key.from_jwk(@jwk, "key-1")
    assert {:ok, pem_key} = Key.from_pem(@fixtures["ed25519"], "key-1")
    assert Key.public_jwk(key) == Key.public_jwk(pem_key)

    assert :crypto.sign(:eddsa, :none, "Open Payments PEM import", [key.private_key, :ed25519]) ==
             Base.decode64!(@fixtures["signature"])

    assert JWK.to_map(Key.public_jwk(key)) ==
             Map.merge(@fixtures["public_jwk"], %{"kid" => "key-1", "alg" => "EdDSA"})
  end

  test "requires both public and private values with the Ed25519 key type and curve" do
    for {wire, field} <- [{"kty", :kty}, {"crv", :crv}, {"d", :d}, {"x", :x}],
        input <- [Map.delete(@jwk, wire), Map.put(@jwk, wire, nil)] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: ^field}]}} =
               Key.from_jwk(input, "key-1")
    end

    for {wire, field, value} <- [
          {"kty", :kty, "RSA"},
          {"kty", :kty, "EC"},
          {"kty", :kty, :OKP},
          {"crv", :crv, "Ed448"},
          {"crv", :crv, "X25519"},
          {"crv", :crv, 123}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Key.from_jwk(Map.put(@jwk, wire, value), "key-1")
    end
  end

  test "rejects encodings with wrong byte lengths, padding, whitespace or invalid characters" do
    for {wire, field} <- [{"d", :d}, {"x", :x}],
        value <- [
          "",
          "abc",
          Base.url_encode64(<<0::248>>, padding: false),
          Base.url_encode64(<<0::264>>, padding: false),
          Base.url_encode64(<<0::512>>, padding: false),
          @jwk[wire] <> "=",
          @jwk[wire] <> "\n",
          " " <> @jwk[wire],
          String.duplicate("+", 43),
          String.duplicate("/", 43),
          <<255>>,
          123,
          false
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Key.from_jwk(Map.put(@jwk, wire, value), "key-1")
    end
  end

  test "rejects noncanonical trailing bits even if decoding produces the same bytes" do
    for {wire, field} <- [{"d", :d}, {"x", :x}] do
      canonical = @jwk[wire]
      alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
      <<last>> = String.last(canonical)
      {index, 1} = :binary.match(alphabet, <<last>>)
      noncanonical = binary_part(canonical, 0, 42) <> binary_part(alphabet, index + 1, 1)

      assert Base.url_decode64(noncanonical, padding: false) ==
               Base.url_decode64(canonical, padding: false)

      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Key.from_jwk(Map.put(@jwk, wire, noncanonical), "key-1")
    end
  end

  test "rejects mismatched public and private key material" do
    zeroes = Base.url_encode64(<<0::256>>, padding: false)

    for input <- [Map.put(@jwk, "x", zeroes), Map.put(@jwk, "d", zeroes)] do
      assert {:error, %Error{validation_errors: [%{field: :x}]}} = Key.from_jwk(input, "key-1")
    end
  end

  test "accepts optional signing metadata and uses the explicitly supplied key ID" do
    for operations <- [["sign"], ["sign", "verify"], ["verify", "sign"]] do
      input =
        Map.merge(@jwk, %{
          "alg" => "EdDSA",
          "use" => "sig",
          "key_ops" => operations,
          "kid" => "metadata-key-id",
          "custom" => %{"labels" => [nil, "example"]}
        })

      assert {:ok, key} = Key.from_jwk(input, "  registered-key-id  ")
      public = Key.public_jwk(key)
      assert public.kid == "  registered-key-id  "
      assert public.extensions == %{}

      assert JWK.to_map(public) ==
               Map.merge(@fixtures["public_jwk"], %{
                 "kid" => "  registered-key-id  ",
                 "alg" => "EdDSA"
               })
    end
  end

  test "rejects incompatible or null metadata instead of ignoring signing restrictions" do
    for {wire, field, values} <- [
          {"alg", :alg, [nil, "Ed25519", "ES256", "", 1]},
          {"use", :use, [nil, "enc", "", false]},
          {"key_ops", :key_ops,
           [
             nil,
             "sign",
             [],
             ["verify"],
             ["encrypt"],
             ["sign", "encrypt"],
             ["sign", "sign"],
             ["sign" | :invalid],
             [:sign],
             ["sign", 1]
           ]},
          {"kid", :kid, [nil, 1, false, <<255>>]}
        ],
        value <- values do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Key.from_jwk(Map.put(@jwk, wire, value), "key-1")
    end
  end

  test "validates the explicit ID separately from optional metadata" do
    for id <- [nil, "", "\t\n", 123, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :key_id}]}} = Key.from_jwk(@jwk, id)
    end

    assert {:ok, key} = Key.from_jwk(Map.put(@jwk, "kid", ""), "key-α")
    assert Key.public_jwk(key).kid == "key-α"
  end

  test "rejects non-object input and invalid JSON metadata without atom coercion" do
    for input <- [nil, [], "jwk", 1, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :jwk}]}} = Key.from_jwk(input, "key-1")
    end

    for metadata <- [%{custom: "value"}, %{"custom" => self()}, %{d: "secret"}] do
      assert {:error, %Error{validation_errors: [%{field: :jwk}]}} =
               Key.from_jwk(Map.merge(@jwk, metadata), "key-1")
    end
  end

  test "aggregates configuration errors without retaining rejected key values" do
    assert {:error, %Error{validation_errors: issues} = error} =
             Key.from_jwk(%{"d" => "private-jwk-input-must-not-leak"}, nil)

    assert Enum.map(issues, & &1.field) == [:key_id, :kty, :crv, :d, :x]
    assert error.details == nil
    refute inspect(Map.from_struct(error)) =~ "private-jwk-input-must-not-leak"
  end

  test "private import remains separate from public models and exports" do
    assert {:ok, key} = Key.from_jwk(@jwk, "key-1")
    public = Key.public_jwk(key) |> JWK.to_map()
    refute Map.has_key?(public, "d")
    assert {:error, %Error{validation_errors: [%{field: :d}]}} = Key.from_jwk(public, "key-1")
    assert :ok = JWK.validate(Key.public_jwk(key))
    assert :ok = JWKS.validate(Key.public_jwks(key))
    refute Jason.encode!(Key.public_jwks(key)) =~ @jwk["d"]
    refute inspect(key) =~ @jwk["d"]
  end
end
