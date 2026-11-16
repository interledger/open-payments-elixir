defmodule OpenPayments.Types.JWKTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OpenPayments.Error
  alias OpenPayments.Specification
  alias OpenPayments.Types.JWK

  @key %{
    "kid" => "key-1",
    "alg" => "EdDSA",
    "kty" => "OKP",
    "crv" => "Ed25519",
    "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  }
  @required ~w(kid alg kty crv x)a

  test "the public key contract matches both bundled server schemas" do
    for server <- [:auth, :wallet_address] do
      {:ok, schema} = Specification.fetch_schema(server, "json-web-key")
      assert schema["type"] == "object"
      assert Enum.sort(schema["required"]) == Enum.sort(Enum.map(@required, &Atom.to_string/1))
      assert Map.get(schema, "additionalProperties", true) == true
      assert schema["properties"]["kid"]["type"] == "string"
      refute Map.has_key?(schema["properties"]["kid"], "minLength")

      for {field, value} <- [{"alg", "EdDSA"}, {"kty", "OKP"}, {"crv", "Ed25519"}, {"use", "sig"}] do
        assert Map.take(schema["properties"][field], ~w(type enum)) == %{
                 "type" => "string",
                 "enum" => [value]
               }
      end

      assert Map.take(schema["properties"]["x"], ~w(type pattern)) == %{
               "type" => "string",
               "pattern" => "^[a-zA-Z0-9-_]+$"
             }
    end
  end

  test "decodes the authorization specification example and encodes exact JSON fields" do
    {:ok, schema} = Specification.fetch_schema(:auth, "json-web-key")

    for wire <- schema["examples"] do
      assert {:ok, %JWK{} = key} = JWK.from_map(wire)
      assert key.kid == "key-1"
      assert key.use == "sig"
      assert key.x == @key["x"]
      assert key.extensions == %{}
      assert :ok = JWK.validate(key)
      assert JWK.to_map(key) == wire
      assert Jason.decode!(Jason.encode!(key)) == wire
    end
  end

  test "reports every missing or null required field without supplying defaults" do
    for field <- @required do
      wire_field = Atom.to_string(field)

      for data <- [Map.delete(@key, wire_field), Map.put(@key, wire_field, nil)] do
        assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
                 JWK.from_map(data)
      end
    end

    assert {:error, %Error{validation_errors: issues}} = JWK.from_map(%{})
    assert Enum.map(issues, & &1.field) == @required
  end

  test "rejects unsupported algorithms, key types, and curves without coercion" do
    for {wire_field, field, values} <- [
          {"alg", :alg, ["ES256", "eddsa", :EdDSA, 1]},
          {"kty", :kty, ["RSA", "EC", "okp", 1]},
          {"crv", :crv, ["Ed448", "X25519", "ed25519", 1]}
        ],
        value <- values do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               JWK.from_map(Map.put(@key, wire_field, value))
    end
  end

  test "an omitted use is distinct from null or a use other than sig" do
    assert {:ok, key} = JWK.from_map(@key)
    assert key.use == nil
    refute Map.has_key?(Jason.decode!(Jason.encode!(key)), "use")

    assert {:ok, key} = JWK.from_map(Map.put(@key, "use", "sig"))
    assert key.use == "sig"

    for value <- [nil, "enc", "", :sig, true] do
      assert {:error, %Error{validation_errors: [%{field: :use}]}} =
               JWK.from_map(Map.put(@key, "use", value))
    end
  end

  test "key IDs follow the schema's string constraint without key-selection policy" do
    for kid <- ["", "  ", "key-α", "https://wallet.example.com/keys/1"] do
      assert {:ok, key} = JWK.from_map(Map.put(@key, "kid", kid))
      assert key.kid == kid
    end

    for kid <- [123, :key, false, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :kid}]}} =
               JWK.from_map(Map.put(@key, "kid", kid))
    end
  end

  test "x must use the nonempty unpadded base64url alphabet" do
    for value <- ["", "abc=", "ab+c", "ab/c", " abc", "abc\n", "é", <<255>>, 123, false] do
      assert {:error, %Error{validation_errors: [%{field: :x}]}} =
               JWK.from_map(Map.put(@key, "x", value))
    end
  end

  test "data decoding leaves decoded size and canonical encoding to cryptographic validation" do
    for value <- ["a", "abc", "_-", String.duplicate("A", 100)] do
      assert {:ok, key} = JWK.from_map(Map.put(@key, "x", value))
      assert key.x == value
      assert :ok = JWK.validate(key)
    end
  end

  test "retains additional JSON metadata including nested objects and nulls" do
    wire = Map.merge(@key, %{"key_ops" => ["verify"], "custom" => %{"label" => nil}})
    assert {:ok, key} = JWK.from_map(wire)
    assert key.extensions == Map.take(wire, ["key_ops", "custom"])
    assert JWK.to_map(key) == wire
    assert Jason.decode!(Jason.encode!(key)) == wire
  end

  test "rejects private material without retaining its value in the error" do
    for value <- ["private-seed-must-not-leak", nil] do
      assert {:error, %Error{validation_errors: [%{field: :d}]} = error} =
               JWK.from_map(Map.put(@key, "d", value))

      assert error.details == nil
      refute inspect(Map.from_struct(error)) =~ "private-seed-must-not-leak"
    end
  end

  test "private material is excluded from public export and extension inspection" do
    {:ok, key} = JWK.from_map(@key)

    for field <- ["d", :d] do
      modified = %{key | extensions: %{field => "private-seed-must-not-leak"}}
      assert {:error, %Error{validation_errors: issues}} = JWK.validate(modified)
      assert Enum.any?(issues, &(&1.field == :d))
      assert JWK.to_map(modified) == @key
      assert Jason.decode!(Jason.encode!(modified)) == @key
      refute inspect(modified) =~ "private-seed-must-not-leak"
    end
  end

  test "rejects non-object input and invalid extensions" do
    for data <- [nil, [], "key", 1, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :jwk}]}} = JWK.from_map(data)
    end

    for extension <- [%{custom: "value"}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               JWK.from_map(Map.merge(@key, extension))
    end

    {:ok, key} = JWK.from_map(@key)

    for extensions <- [nil, [], %URI{}, %{"kid" => "spoofed"}, %{"use" => "sig"}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               JWK.validate(%{key | extensions: extensions})
    end

    assert {:error, %Error{validation_errors: [%{field: :use}]}} =
             JWK.validate(%{key | use: "enc"})

    assert JWK.to_map(%{key | extensions: %{"kid" => "spoofed", "use" => "enc"}}) == @key
  end

  property "32-byte public values retain their exact base64url representation through JSON" do
    check all(public <- binary(length: 32), kid <- string(:alphanumeric)) do
      wire = %{@key | "kid" => kid, "x" => Base.url_encode64(public, padding: false)}
      assert {:ok, key} = JWK.from_map(wire)
      assert Jason.decode!(Jason.encode!(key)) == wire
    end
  end
end
