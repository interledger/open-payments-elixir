defmodule OpenPayments.KeyTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Key}
  alias OpenPayments.Types.{JWK, JWKS}

  # Published test material from https://www.rfc-editor.org/rfc/rfc8032#section-7.1,
  # test 1. These are public test fixtures, not operational credentials.
  @seed Base.decode16!("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
          case: :lower
        )
  @public Base.decode16!("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
            case: :lower
          )
  @signature Base.decode16!(
               "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" <>
                 "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
               case: :lower
             )
  @jwk %{
    "kid" => "key-1",
    "alg" => "EdDSA",
    "kty" => "OKP",
    "crv" => "Ed25519",
    "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  }

  test "seed import derives the RFC 8032 public key and preserves its signing identity" do
    assert {:ok, key} = Key.from_seed(@seed, "key-1")
    assert key.public_key == @public
    assert key.private_key == @seed

    assert :crypto.sign(:eddsa, :none, "", [key.private_key, :ed25519]) == @signature
    assert :crypto.verify(:eddsa, :none, "", @signature, [key.public_key, :ed25519])
    assert Key.public_jwk(key) |> JWK.to_map() == @jwk
  end

  test "public export produces schema-valid typed keys and sets without private material" do
    {:ok, key} = Key.from_seed(@seed, "key-1")
    assert %JWK{} = jwk = Key.public_jwk(key)
    assert %JWKS{keys: [^jwk]} = jwks = Key.public_jwks(key)
    assert :ok = JWK.validate(jwk)
    assert :ok = JWKS.validate(jwks)
    assert JWK.to_map(jwk) == @jwk
    assert JWKS.to_map(jwks) == %{"keys" => [@jwk]}
    assert Jason.decode!(Jason.encode!(jwks)) == %{"keys" => [@jwk]}
    refute Map.has_key?(JWK.to_map(jwk), "d")
    refute Map.has_key?(JWK.to_map(jwk), "use")
  end

  test "key generation produces a fresh usable key for each explicit call" do
    assert {:ok, first} = Key.generate("key-1")
    assert {:ok, second} = Key.generate("key-1")
    refute first.public_key == second.public_key

    for key <- [first, second] do
      jwk = Key.public_jwk(key)
      assert {:ok, public} = Base.url_decode64(jwk.x, padding: false)
      assert byte_size(public) == 32
      assert :ok = JWK.validate(jwk)
      signature = :crypto.sign(:eddsa, :none, "open payments", [key.private_key, :ed25519])
      assert :crypto.verify(:eddsa, :none, "open payments", signature, [public, :ed25519])
    end
  end

  test "reimporting a seed retains identity across key IDs without generating a replacement" do
    assert {:ok, first} = Key.from_seed(@seed, "key-1")
    assert {:ok, second} = Key.from_seed(@seed, "key-2")
    assert Key.public_jwk(first).x == Key.public_jwk(second).x
    assert Key.public_jwk(second).kid == "key-2"
  end

  test "key IDs must be nonblank UTF-8 strings for both generation and seed import" do
    for id <- [nil, 1, false, :key, "", " ", "\t\n", "\u00A0", <<255>>] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :key_id}]}} =
               Key.generate(id)

      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :key_id}]}} =
               Key.from_seed(@seed, id)
    end
  end

  test "preserves valid key IDs without trimming or normalizing them" do
    for id <- ["key-α", "  key-1  ", "https://wallet.example.com/keys/1"] do
      assert {:ok, key} = Key.from_seed(@seed, id)
      assert Key.public_jwk(key).kid == id
    end
  end

  test "requires raw 32-byte seeds without accepting encodings or expanded key pairs" do
    for seed <- [
          nil,
          false,
          32,
          :seed,
          :binary.bin_to_list(@seed),
          <<1::1>>,
          "",
          binary_part(@seed, 0, 31),
          @seed <> <<0>>,
          @seed <> @public,
          Base.encode16(@seed),
          Base.encode64(@seed)
        ] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :seed}]}} =
               Key.from_seed(seed, "key-1")
    end
  end

  test "returns all configuration issues without retaining input values" do
    seed = "invalid-secret-seed"
    assert {:error, %Error{validation_errors: issues} = error} = Key.from_seed(seed, nil)
    assert Enum.map(issues, & &1.field) == [:key_id, :seed]
    assert error.details == nil
    refute inspect(Map.from_struct(error)) =~ seed
    refute Exception.message(error) =~ seed
  end

  test "inspection redacts private bytes and the private key has no JSON encoder" do
    seed = String.duplicate("private-seed-", 2) <> "123456"
    assert byte_size(seed) == 32
    {:ok, key} = Key.from_seed(seed, "key-1")
    rendered = inspect(key)
    assert rendered =~ "key-1"
    refute rendered =~ seed
    refute rendered =~ "private_key"
    error = assert_raise Protocol.UndefinedError, fn -> Jason.encode!(key) end
    refute Exception.message(error) =~ seed
  end

  test "signs the RFC 8032 vector through the opaque key API" do
    {:ok, key} = Key.from_seed(@seed, "key-1")
    assert Key.key_id(key) == "key-1"
    assert Key.sign(key, "") == {:ok, @signature}
  end

  test "signing errors do not retain input or private material" do
    {:ok, key} = Key.from_seed(@seed, "key-1")
    invalid_key = %{key | private_key: "private-seed-must-not-leak"}

    for {signing_key, data} <- [
          {invalid_key, "private-body-must-not-leak"},
          {key, ["private-body-must-not-leak"]},
          {nil, "private-body-must-not-leak"}
        ] do
      assert {:error, %Error{kind: :signing} = error} = Key.sign(signing_key, data)
      refute inspect(Map.from_struct(error)) =~ "private-seed-must-not-leak"
      refute inspect(Map.from_struct(error)) =~ "private-body-must-not-leak"
    end
  end
end
