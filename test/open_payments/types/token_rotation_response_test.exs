defmodule OpenPayments.Types.TokenRotationResponseTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{AccessToken, ContinuationToken, TokenRotationResponse}

  @token %{
    "value" => "test-new-token",
    "manage" => "https://auth.example.com/opaque/manage",
    "access" => []
  }
  @wire %{"access_token" => @token}

  test "matches the pinned rotation wrapper contract and permits root extensions" do
    schema =
      Specification.document(:auth)["paths"]["/token/{id}"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["schema"]

    assert schema["type"] == "object"
    assert schema["required"] == ["access_token"]
    assert schema["properties"]["access_token"]["$ref"] == "#/components/schemas/access_token"
    assert Map.get(schema, "additionalProperties", true) == true
  end

  test "round trips all official rotation examples with a typed issued token" do
    examples =
      Specification.document(:auth)["paths"]["/token/{id}"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    assert map_size(examples) > 0

    for {_name, %{"value" => wire}} <- examples do
      assert {:ok, %TokenRotationResponse{access_token: %AccessToken{}} = response} =
               TokenRotationResponse.from_map(wire)

      assert :ok = TokenRotationResponse.validate(response)
      assert TokenRotationResponse.to_map(response) == wire
      assert Jason.decode!(Jason.encode!(response)) == wire
    end
  end

  test "requires the issued token wrapper, rejects null and safely prefixes nested errors" do
    for {wire, field} <- [
          {%{}, :access_token},
          {%{"access_token" => nil}, :access_token},
          {%{"access_token" => "private-token"}, :access_token},
          {put_in(@wire, ["access_token", "value"], ["private-token"]), "access_token.value"},
          {put_in(@wire, ["access_token", "manage"], "relative"), "access_token.manage"},
          {put_in(@wire, ["access_token", "access"], [
             %{"type" => "quote", "actions" => ["invalid"]}
           ]), "access_token.access[0].actions"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               TokenRotationResponse.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-token"
    end
  end

  test "preserves JSON metadata and rejects malformed root extension data" do
    wire = Map.put(@wire, "custom", %{"values" => [nil, true, 123]})
    assert {:ok, response} = TokenRotationResponse.from_map(wire)
    assert response.extensions == Map.take(wire, ["custom"])
    assert Jason.decode!(Jason.encode!(response)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               TokenRotationResponse.from_map(Map.merge(@wire, extra))
    end
  end

  test "revalidates manual fields and credential roles while protecting reserved export fields" do
    {:ok, response} = TokenRotationResponse.from_map(@wire)

    {:ok, continuation_token} =
      ContinuationToken.from_map(%{"value" => "test-continuation-token"})

    for {changed, field} <- [
          {%{response | access_token: @token}, :access_token},
          {%{response | access_token: continuation_token}, :access_token},
          {%{response | access_token: %{response.access_token | value: nil}},
           "access_token.value"},
          {%{response | extensions: %{"access_token" => "override"}}, :extensions},
          {%{response | extensions: %{custom: true}}, :extensions}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               TokenRotationResponse.validate(changed)
    end

    assert TokenRotationResponse.to_map(%{response | extensions: %{"access_token" => "override"}}) ==
             @wire
  end

  test "rejects non-objects and hides token and extension values while explicit exports retain them" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :token_rotation_response}]} = error} =
               TokenRotationResponse.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    wire = Map.put(@wire, "custom", "private-extension")
    {:ok, response} = TokenRotationResponse.from_map(wire)
    refute inspect(response) =~ "test-new-token"
    refute inspect(response) =~ "private-extension"
    assert TokenRotationResponse.to_map(response) == wire
  end
end
