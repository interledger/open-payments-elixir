defmodule OpenPayments.Types.JWKSTest do
  use ExUnit.Case, async: true

  alias OpenPayments.Error
  alias OpenPayments.Specification
  alias OpenPayments.Types.{JWK, JWKS}

  @key %{
    "kid" => "key-1",
    "alg" => "EdDSA",
    "kty" => "OKP",
    "crv" => "Ed25519",
    "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  }

  test "the set contract matches the bundled wallet-address schema" do
    {:ok, schema} = Specification.fetch_schema(:wallet_address, "json-web-key-set")
    assert schema["type"] == "object"
    assert schema["required"] == ["keys"]
    assert schema["additionalProperties"] == false
    assert schema["properties"]["keys"]["type"] == "array"

    assert schema["properties"]["keys"]["items"] == %{
             "$ref" => "#/components/schemas/json-web-key"
           }

    refute Map.has_key?(schema["properties"]["keys"], "minItems")
    refute Map.has_key?(schema["properties"]["keys"], "uniqueItems")
  end

  test "decodes the official example into nested public key structs" do
    {:ok, schema} = Specification.fetch_schema(:wallet_address, "json-web-key-set")

    for wire <- schema["examples"] do
      assert {:ok, %JWKS{keys: [%JWK{} = key]} = set} = JWKS.from_map(wire)
      assert key.kid == "key-1"
      assert :ok = JWKS.validate(set)
      assert JWKS.to_map(set) == wire
      assert Jason.decode!(Jason.encode!(%{"jwks" => set})) == %{"jwks" => wire}
    end
  end

  test "allows an empty set and does not introduce duplicate key-ID restrictions" do
    for keys <- [[], [@key, @key], [@key, Map.put(@key, "kid", "next-key")]] do
      assert {:ok, set} = JWKS.from_map(%{"keys" => keys})
      assert :ok = JWKS.validate(set)
      assert JWKS.to_map(set) == %{"keys" => keys}
      assert Jason.decode!(Jason.encode!(set)) == %{"keys" => keys}
    end
  end

  test "rejects absent, null and non-array keys" do
    assert {:error, %Error{validation_errors: [%{field: :keys}]}} = JWKS.from_map(%{})

    for keys <- [nil, %{}, "keys", 1, false] do
      assert {:error, %Error{validation_errors: [%{field: :keys}]}} =
               JWKS.from_map(%{"keys" => keys})

      assert {:error, %Error{validation_errors: [%{field: :keys}]}} =
               JWKS.validate(%JWKS{keys: keys})
    end
  end

  test "rejects non-object documents and every additional top-level field" do
    for data <- [nil, [], "jwks", 1, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :jwks}]}} = JWKS.from_map(data)
    end

    for extension <- [%{"custom" => nil}, %{custom: true}] do
      assert {:error, %Error{validation_errors: [%{field: :jwks}]}} =
               JWKS.from_map(Map.put(extension, "keys", []))
    end
  end

  test "reports all invalid entries with their original indexes and no rejected values" do
    wire = %{
      "keys" => [
        Map.put(@key, "x", "invalid-secret-value="),
        @key,
        nil,
        Map.put(@key, "alg", "ES256"),
        Map.put(@key, "d", "private-seed-must-not-leak")
      ]
    }

    assert {:error, %Error{kind: :validation, validation_errors: issues} = error} =
             JWKS.from_map(wire)

    assert Enum.map(issues, & &1.field) == ["keys[0].x", "keys[2]", "keys[3].alg", "keys[4].d"]
    refute inspect(Map.from_struct(error)) =~ "invalid-secret-value"
    refute inspect(Map.from_struct(error)) =~ "private-seed-must-not-leak"
  end

  test "aggregates top-level and nested errors" do
    assert {:error, %Error{validation_errors: issues}} =
             JWKS.from_map(%{"keys" => [false], "custom" => true})

    assert Enum.map(issues, & &1.field) == [:jwks, "keys[0]"]
  end

  test "validates manually modified sets including nested fields and non-struct entries" do
    {:ok, set} = JWKS.from_map(%{"keys" => [@key]})
    [key] = set.keys
    modified = %JWKS{keys: [%{key | x: ""}, @key, nil]}

    assert {:error, %Error{validation_errors: issues}} = JWKS.validate(modified)
    assert Enum.map(issues, & &1.field) == ["keys[0].x", "keys[1]", "keys[2]"]
  end

  test "preserves permitted metadata in nested keys while excluding private export" do
    wire = %{"keys" => [Map.put(@key, "custom", %{"label" => nil})]}
    assert {:ok, set} = JWKS.from_map(wire)
    assert JWKS.to_map(set) == wire

    [key] = set.keys
    modified = %{set | keys: [%{key | extensions: Map.put(key.extensions, "d", "private-seed")}]}
    assert {:error, %Error{validation_errors: [%{field: "keys[0].d"}]}} = JWKS.validate(modified)
    assert Jason.decode!(Jason.encode!(modified)) == wire
  end
end
