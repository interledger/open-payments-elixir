defmodule OpenPayments.Types.ContinuationTokenTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.ContinuationToken

  @token %{"value" => "test-continuation-token"}

  test "matches the pinned continuation credential schema and permitted extension fields" do
    {:ok, continuation} = Specification.fetch_schema(:auth, "continue")
    schema = continuation["properties"]["access_token"]
    assert schema["type"] == "object"
    assert schema["required"] == ["value"]
    assert schema["properties"]["value"]["type"] == "string"
    refute Map.has_key?(schema["properties"]["value"], "pattern")
    refute Map.has_key?(schema["properties"]["value"], "minLength")
    assert Map.get(schema, "additionalProperties", true) == true
  end

  test "round trips continuation credentials from official grant and continuation examples" do
    document = Specification.document(:auth)

    tokens =
      for path <- ["/", "/continue/{id}"],
          {_name, example} <-
            document["paths"][path]["post"]["responses"]["200"]["content"]["application/json"][
              "examples"
            ],
          token = get_in(example, ["value", "continue", "access_token"]),
          not is_nil(token),
          do: token

    assert tokens != []

    for wire <- tokens do
      assert {:ok, %ContinuationToken{} = token} = ContinuationToken.from_map(wire)
      assert :ok = ContinuationToken.validate(token)
      assert ContinuationToken.to_map(token) == wire
      assert Jason.decode!(Jason.encode!(token)) == wire
    end
  end

  test "requires a string value without imposing request-header alphabet constraints" do
    for data <- [
          %{},
          %{"value" => nil},
          %{"value" => 1},
          %{"value" => ["private-token"]},
          %{"value" => <<255>>}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :value}]} = error} =
               ContinuationToken.from_map(data)

      refute inspect(Map.from_struct(error)) =~ "private-token"
    end

    for value <- ["", "opaque token/value", "Café 🌍"] do
      assert {:ok, token} = ContinuationToken.from_map(%{"value" => value})
      assert ContinuationToken.to_map(token) == %{"value" => value}
    end
  end

  test "preserves JSON extensions and rejects malformed extension data during decoding" do
    wire = Map.put(@token, "custom", %{"values" => [nil, true, 123]})
    assert {:ok, token} = ContinuationToken.from_map(wire)
    assert token.extensions == Map.take(wire, ["custom"])
    assert Jason.decode!(Jason.encode!(token)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               ContinuationToken.from_map(Map.merge(@token, extra))
    end
  end

  test "revalidates manually modified values and prevents reserved-field export overrides" do
    {:ok, token} = ContinuationToken.from_map(@token)

    assert {:error, %Error{validation_errors: [%{field: :value}]}} =
             ContinuationToken.validate(%{token | value: nil})

    for extensions <- [%{"value" => "override"}, %{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               ContinuationToken.validate(%{token | extensions: extensions})
    end

    assert ContinuationToken.to_map(%{token | extensions: %{"value" => "override"}}) == @token
  end

  test "rejects non-objects and hides credential and extension values in inspection and errors" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :continuation_token}]} = error} =
               ContinuationToken.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    wire = %{"value" => "private-continuation-token", "custom" => "private-extension"}
    {:ok, token} = ContinuationToken.from_map(wire)
    refute inspect(token) =~ "private-"
    assert ContinuationToken.to_map(token) == wire
  end
end
