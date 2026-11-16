defmodule OpenPayments.KeyPEMTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Key}
  alias OpenPayments.Types.JWK

  @fixtures File.read!(Path.expand("../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()
  @pem @fixtures["ed25519"]
  @seed Base.decode16!("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
          case: :lower
        )

  test "imports Node's PKCS#8 key and reproduces its public JWK and signature" do
    assert {:ok, key} = Key.from_pem(@pem, "key-1")
    jwk = Key.public_jwk(key)
    expected = Map.merge(@fixtures["public_jwk"], %{"kid" => "key-1", "alg" => "EdDSA"})
    assert JWK.to_map(jwk) == expected
    assert :ok = JWK.validate(jwk)

    assert :crypto.sign(:eddsa, :none, "Open Payments PEM import", [key.private_key, :ed25519]) ==
             Base.decode64!(@fixtures["signature"])
  end

  test "PEM and raw seed imports preserve the same identity" do
    assert {:ok, pem_key} = Key.from_pem(@pem, "  key-α  ")
    assert {:ok, seed_key} = Key.from_seed(@seed, "  key-α  ")
    assert Key.public_jwk(pem_key) == Key.public_jwk(seed_key)
    assert pem_key.private_key == @seed
  end

  test "accepts CRLF and surrounding blank lines" do
    for pem <- [String.replace(@pem, "\n", "\r\n"), "\n\n" <> @pem <> "\n\n"] do
      assert {:ok, key} = Key.from_pem(pem, "key-1")
      assert Key.public_jwk(key).x == @fixtures["public_jwk"]["x"]
    end
  end

  test "rejects other algorithms even when they have valid PKCS#8 encodings" do
    for algorithm <- ~w(ed448 x25519 p256 rsa) do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :pem}]}} =
               Key.from_pem(@fixtures[algorithm], "key-1")
    end
  end

  test "rejects public-only and encrypted keys" do
    for name <- ~w(ed25519_public ed25519_encrypted) do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :pem}]}} =
               Key.from_pem(@fixtures[name], "key-1")
    end
  end

  test "rejects multiple entries instead of silently selecting one" do
    for pem <- [
          @pem <> @pem,
          @pem <> @fixtures["ed25519_public"],
          @fixtures["ed448"] <> @pem,
          @fixtures["ed25519_encrypted"] <> @pem
        ] do
      assert {:error, %Error{validation_errors: [%{field: :pem}]}} = Key.from_pem(pem, "key-1")
    end
  end

  test "requires a 32-byte seed inside the private-key container" do
    [entry] = :public_key.pem_decode(@pem)
    decoded = :public_key.pem_entry_decode(entry)

    for seed <- ["", binary_part(@seed, 0, 31), @seed <> <<0>>, @seed <> @seed] do
      pem =
        decoded
        |> put_elem(2, seed)
        |> then(&:public_key.pem_entry_encode(:PrivateKeyInfo, &1))
        |> then(&:public_key.pem_encode([&1]))

      assert {:error, %Error{validation_errors: [%{field: :pem}]}} = Key.from_pem(pem, "key-1")
    end
  end

  test "rejects malformed PEM and DER without exposing parser exceptions" do
    for pem <- [
          "",
          "not a key",
          "-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n",
          "-----BEGIN PRIVATE KEY-----\n???\n-----END PRIVATE KEY-----\n",
          "-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----\n",
          String.replace(@pem, "-----END PRIVATE KEY-----", ""),
          String.replace(@pem, "PRIVATE KEY", "UNKNOWN KEY"),
          <<255, 0, 1>>
        ] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :pem}]}} =
               Key.from_pem(pem, "key-1")
    end
  end

  test "rejects non-binaries and does not guess raw seed, DER or base64 PEM formats" do
    [{:PrivateKeyInfo, der, :not_encrypted}] = :public_key.pem_decode(@pem)

    for input <- [nil, false, 1, %{}, :binary.bin_to_list(@pem), @seed, der, Base.encode64(@pem)] do
      assert {:error, %Error{validation_errors: [%{field: :pem}]}} = Key.from_pem(input, "key-1")
    end
  end

  test "applies the same key-ID validation as generation and seed import" do
    for id <- [nil, "", "\t\n", 123, <<255>>] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :key_id}]}} =
               Key.from_pem(@pem, id)
    end
  end

  test "aggregates configuration issues without retaining rejected material" do
    pem = "-----BEGIN PRIVATE KEY-----\nprivate-input-must-not-leak\n-----END PRIVATE KEY-----"

    assert {:error, %Error{validation_errors: issues} = error} = Key.from_pem(pem, nil)
    assert Enum.map(issues, & &1.field) == [:key_id, :pem]
    assert error.details == nil
    refute inspect(Map.from_struct(error)) =~ "private-input-must-not-leak"
    refute Exception.message(error) =~ "private-input-must-not-leak"
  end
end
