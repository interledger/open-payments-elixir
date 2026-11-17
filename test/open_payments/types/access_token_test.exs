defmodule OpenPayments.Types.AccessTokenTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{AccessOutgoing, AccessQuote, AccessToken}

  @access [%{"type" => "quote", "actions" => ["create"]}]
  @token %{
    "value" => "test-resource-token",
    "manage" => "https://auth.example.com/tenant/token/manage-id",
    "access" => @access
  }

  test "matches the pinned issued-token fields, required data and strict object contract" do
    {:ok, schema} = Specification.fetch_schema(:auth, "access_token")
    assert schema["required"] == ~w(value manage access)
    assert schema["additionalProperties"] == false
    assert schema["properties"]["value"]["type"] == "string"
    refute Map.has_key?(schema["properties"]["value"], "pattern")
    assert schema["properties"]["manage"]["format"] == "uri"
    assert schema["properties"]["access"] == %{"$ref" => "#/components/schemas/access"}
    assert schema["properties"]["expires_in"]["type"] == "integer"
    refute Map.has_key?(schema["properties"]["expires_in"], "minimum")
    refute Map.has_key?(schema["properties"]["expires_in"], "maximum")
  end

  test "round trips tokens from official grant and continuation examples including card results" do
    document = Specification.document(:auth)

    tokens =
      for path <- ["/", "/continue/{id}"],
          {_name, example} <-
            document["paths"][path]["post"]["responses"]["200"]["content"]["application/json"][
              "examples"
            ],
          token = example["value"]["access_token"],
          not is_nil(token),
          do: token

    assert tokens != []

    for wire <- tokens do
      assert {:ok, %AccessToken{} = token} = AccessToken.from_map(wire)
      assert :ok = AccessToken.validate(token)
      assert AccessToken.to_map(token) == wire
      assert Jason.decode!(Jason.encode!(token)) == wire
    end
  end

  test "requires value, management URI and access without defaults or coercion" do
    for {wire_field, field} <- [{"value", :value}, {"manage", :manage}, {"access", :access}],
        data <- [
          Map.delete(@token, wire_field),
          Map.put(@token, wire_field, nil),
          Map.put(@token, wire_field, 1)
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               AccessToken.from_map(data)
    end

    assert {:ok, %AccessToken{access: []}} = AccessToken.from_map(%{@token | "access" => []})
  end

  test "preserves opaque token strings without applying request-header validation" do
    for value <- ["", "opaque token value", "Café 🌍", "token.with-symbols+/="] do
      wire = %{@token | "value" => value}
      assert {:ok, token} = AccessToken.from_map(wire)
      assert AccessToken.to_map(token) == wire
    end

    for value <- [false, [], %{}, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :value}]}} =
               AccessToken.from_map(%{@token | "value" => value})
    end
  end

  test "checks management URI format and preserves tenant, development and other absolute URI data" do
    for manage <- [
          "https://Auth.Example.COM:8443/tenant/token/id?part=1#state",
          "http://localhost:3006/tenant/token/manage-id",
          "urn:example:management"
        ] do
      wire = %{@token | "manage" => manage}
      assert {:ok, token} = AccessToken.from_map(wire)
      assert AccessToken.to_map(token) == wire
    end

    for manage <- [
          "",
          "/token/manage-id",
          "$auth.example.com/manage",
          "https://",
          "https://auth.example.com/%xx",
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: :manage}]}} =
               AccessToken.from_map(%{@token | "manage" => manage})
    end
  end

  test "distinguishes omitted expiry from null and preserves every schema-valid integer" do
    assert {:ok, %AccessToken{expires_in: nil} = token} = AccessToken.from_map(@token)
    assert AccessToken.to_map(token) == @token

    for expires <- [-1, 0, 3600, 18_446_744_073_709_551_615] do
      wire = Map.put(@token, "expires_in", expires)
      assert {:ok, token} = AccessToken.from_map(wire)
      assert token.expires_in == expires
      assert Jason.decode!(Jason.encode!(token)) == wire
    end

    for expires <- [nil, 1.5, "3600", false, []] do
      assert {:error, %Error{validation_errors: [%{field: :expires_in}]}} =
               AccessToken.from_map(Map.put(@token, "expires_in", expires))
    end
  end

  test "validates access-array limits, typed entries and nested safe card paths" do
    for access <- [List.duplicate(hd(@access), 4), @access ++ @access] do
      assert {:error, %Error{validation_errors: [%{field: :access}]}} =
               AccessToken.from_map(%{@token | "access" => access})
    end

    invalid = %{
      "type" => "outgoing-payment",
      "actions" => ["create"],
      "identifier" => "https://wallet.example.com/alice",
      "cardAuthorization" => %{"tlvData" => ["private-card"], "requestId" => "test-id"}
    }

    assert {:error,
            %Error{validation_errors: [%{field: "access[0].card_authorization.tlv_data"}]} = error} =
             AccessToken.from_map(%{@token | "access" => [invalid]})

    refute inspect(Map.from_struct(error)) =~ "private-card"
  end

  test "rejects non-objects, extra fields and camel-case expiry aliases safely" do
    for value <- [nil, [], true, 1, "private-token-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :access_token}]} = error} =
               AccessToken.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-token-input"
    end

    for extra <- [
          %{"custom" => "private-extra"},
          %{"expiresIn" => 3600},
          %{value: "private-extra"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :access_token}]} = error} =
               AccessToken.from_map(Map.merge(@token, extra))

      refute inspect(Map.from_struct(error)) =~ "private-extra"
    end
  end

  test "revalidates modified typed token fields and access entries" do
    {:ok, token} = AccessToken.from_map(@token)
    assert [%AccessQuote{}] = token.access

    for {changed, field} <- [
          {%{token | value: ["private-value"]}, :value},
          {%{token | manage: "relative"}, :manage},
          {%{token | expires_in: 1.0}, :expires_in},
          {%{token | access: @access}, "access[0]"},
          {%{token | access: [%{hd(token.access) | actions: ["complete"]}]}, "access[0].actions"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               AccessToken.validate(changed)

      refute inspect(Map.from_struct(error)) =~ "private-value"
    end

    assert :ok = AccessToken.validate(%{token | expires_in: nil})
  end

  test "inspection hides token, management URL and card data while explicit exports retain them" do
    outgoing = %{
      "type" => "outgoing-payment",
      "actions" => ["create"],
      "identifier" => "https://wallet.example.com/alice",
      "cardAuthorization" => %{"tlvData" => "private-card", "requestId" => "private-request-id"}
    }

    wire = %{
      @token
      | "value" => "private-resource-token",
        "manage" => "https://private-auth.example.com/tenant/token/id",
        "access" => [outgoing]
    }

    {:ok, token} = AccessToken.from_map(wire)
    assert [%AccessOutgoing{}] = token.access
    refute inspect(token) =~ "private-"
    assert AccessToken.to_map(token) == wire
    assert Jason.decode!(Jason.encode!(token)) == wire
  end
end
