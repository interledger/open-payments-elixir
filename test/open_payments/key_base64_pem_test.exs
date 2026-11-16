defmodule OpenPayments.KeyBase64PEMTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Key}
  alias OpenPayments.Types.JWK

  @fixtures File.read!(Path.expand("../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()
  @pem @fixtures["ed25519"]

  test "imports padded, unpadded and line-wrapped base64 PEM without changing identity" do
    for pem <- [@pem, @pem <> "\n", @pem <> "\n\n"] do
      encoded = Base.encode64(pem)

      wrapped =
        encoded
        |> String.codepoints()
        |> Enum.chunk_every(20)
        |> Enum.map_join(" \t\r\n", &Enum.join/1)

      for input <- [encoded, String.trim_trailing(encoded, "="), wrapped] do
        assert {:ok, key} = Key.from_base64_pem(input, "key-1")
        expected = Map.merge(@fixtures["public_jwk"], %{"kid" => "key-1", "alg" => "EdDSA"})
        assert key |> Key.public_jwk() |> JWK.to_map() == expected

        assert :crypto.sign(:eddsa, :none, "Open Payments PEM import", [key.private_key, :ed25519]) ==
                 Base.decode64!(@fixtures["signature"])
      end
    end
  end

  test "rejects malformed base64 and non-binary input without guessing formats" do
    for input <- [
          nil,
          1,
          false,
          [],
          %{},
          "A",
          "=",
          "A===",
          "AA=A",
          "A=AA",
          "Zg===",
          "Zg==!",
          "Zg__",
          <<255>>,
          @pem
        ] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :base64_pem}]}} =
               Key.from_base64_pem(input, "key-1")
    end
  end

  test "decoded bytes must still be a valid unencrypted Ed25519 private PEM entry" do
    for pem <- [
          "",
          " ",
          "not a private key",
          @fixtures["ed448"],
          @fixtures["x25519"],
          @fixtures["p256"],
          @fixtures["rsa"],
          @fixtures["ed25519_public"],
          @fixtures["ed25519_encrypted"],
          @pem <> @pem
        ] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :pem}]}} =
               Key.from_base64_pem(Base.encode64(pem), "key-1")
    end
  end

  test "does not interpret decoded raw seeds or DER as PEM" do
    [{:PrivateKeyInfo, der, :not_encrypted} = entry] = :public_key.pem_decode(@pem)
    seed = entry |> :public_key.pem_entry_decode() |> elem(2)

    for input <- [der, seed] do
      assert {:error, %Error{validation_errors: [%{field: :pem}]}} =
               Key.from_base64_pem(Base.encode64(input), "key-1")
    end
  end

  test "applies the same key-ID rules as other key imports" do
    encoded = Base.encode64(@pem)

    for id <- [nil, "", "\t\n", 123, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :key_id}]}} =
               Key.from_base64_pem(encoded, id)
    end

    assert {:ok, key} = Key.from_base64_pem(encoded, "  key-α  ")
    assert Key.public_jwk(key).kid == "  key-α  "
  end

  test "aggregates issues without retaining encoded or decoded private values" do
    assert {:error, %Error{validation_errors: issues} = error} =
             Key.from_base64_pem("invalid-secret-encoding!", nil)

    assert Enum.map(issues, & &1.field) == [:key_id, :base64_pem]
    assert error.details == nil
    refute inspect(Map.from_struct(error)) =~ "invalid-secret-encoding"

    secret = "private-decoded-value-must-not-leak"
    encoded = Base.encode64(secret)
    assert {:error, error} = Key.from_base64_pem(encoded, "key-1")
    refute inspect(Map.from_struct(error)) =~ secret
    refute inspect(Map.from_struct(error)) =~ encoded
  end
end
