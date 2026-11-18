defmodule OpenPayments.Types.GrantContinuationRequestTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.GrantContinuationRequest

  @request %{"interact_ref" => "test-interaction-reference"}

  test "matches the pinned optional string reference and optional HTTP body contract" do
    {:ok, schema} = Specification.fetch_schema(:auth, "continuation-request")
    assert schema["type"] == "object"
    assert Map.get(schema, "required", []) == []
    assert schema["properties"]["interact_ref"]["type"] == "string"

    for constraint <- ["format", "pattern", "minLength"] do
      refute Map.has_key?(schema["properties"]["interact_ref"], constraint)
    end

    assert Map.get(schema, "additionalProperties", true) == true

    body = Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["requestBody"]
    assert Map.get(body, "required", false) == false

    assert body["content"]["application/json"]["schema"]["$ref"] ==
             "#/components/schemas/continuation-request"
  end

  test "round trips every official continuation request example" do
    examples =
      Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    assert map_size(examples) > 0

    for {_name, %{"value" => wire}} <- examples do
      assert {:ok, %GrantContinuationRequest{} = request} =
               GrantContinuationRequest.from_map(wire)

      assert :ok = GrantContinuationRequest.validate(request)
      assert GrantContinuationRequest.to_map(request) == wire
      assert Jason.decode!(Jason.encode!(request)) == wire
    end
  end

  test "distinguishes an empty JSON payload from null or absent body input" do
    assert {:ok, %GrantContinuationRequest{interact_ref: nil} = request} =
             GrantContinuationRequest.from_map(%{})

    assert :ok = GrantContinuationRequest.validate(request)
    assert GrantContinuationRequest.to_map(request) == %{}
    assert Jason.encode!(request) == "{}"
    assert GrantContinuationRequest.to_map(%GrantContinuationRequest{}) == %{}

    assert {:error, %Error{validation_errors: [%{field: :grant_continuation_request}]}} =
             GrantContinuationRequest.from_map(nil)

    assert {:error, %Error{validation_errors: [%{field: :interact_ref}]}} =
             GrantContinuationRequest.from_map(%{"interact_ref" => nil})
  end

  test "preserves opaque reference strings and rejects wrong types without coercion" do
    for reference <- ["", "opaque reference/value", "Café 🌍"] do
      wire = %{"interact_ref" => reference}
      assert {:ok, request} = GrantContinuationRequest.from_map(wire)
      assert Jason.decode!(Jason.encode!(request)) == wire
    end

    for reference <- [1, false, ["private-reference"], %{}, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :interact_ref}]} = error} =
               GrantContinuationRequest.from_map(%{"interact_ref" => reference})

      refute inspect(Map.from_struct(error)) =~ "private-reference"
    end
  end

  test "retains JSON extension data and rejects malformed extension values" do
    for base <- [%{}, @request] do
      wire = Map.put(base, "custom", %{"steps" => [nil, true, 123]})
      assert {:ok, request} = GrantContinuationRequest.from_map(wire)
      assert request.extensions == Map.take(wire, ["custom"])
      assert :ok = GrantContinuationRequest.validate(request)
      assert Jason.decode!(Jason.encode!(request)) == wire
    end

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               GrantContinuationRequest.from_map(Map.merge(@request, extra))
    end
  end

  test "uses the exact underscore wire name without interpreting camel-case extensions as aliases" do
    wire = %{"interactRef" => "extension-value"}
    assert {:ok, request} = GrantContinuationRequest.from_map(wire)
    assert request.interact_ref == nil
    assert request.extensions == wire
    assert GrantContinuationRequest.to_map(request) == wire

    wire = Map.merge(wire, @request)
    assert {:ok, request} = GrantContinuationRequest.from_map(wire)
    assert request.interact_ref == @request["interact_ref"]
    assert Jason.decode!(Jason.encode!(request)) == wire
  end

  test "revalidates manual changes and prevents reserved field overrides on export" do
    {:ok, request} = GrantContinuationRequest.from_map(@request)

    assert {:error, %Error{validation_errors: [%{field: :interact_ref}]}} =
             GrantContinuationRequest.validate(%{request | interact_ref: false})

    assert :ok = GrantContinuationRequest.validate(%{request | interact_ref: nil})

    for extensions <- [%{"interact_ref" => "override"}, %{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               GrantContinuationRequest.validate(%{request | extensions: extensions})
    end

    assert GrantContinuationRequest.to_map(%{
             request
             | extensions: %{"interact_ref" => "override"}
           }) == @request

    assert GrantContinuationRequest.to_map(%{
             request
             | interact_ref: nil,
               extensions: %{"interact_ref" => "override"}
           }) == %{}
  end

  test "rejects non-objects and hides references and extensions in inspection and errors" do
    for value <- [[], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :grant_continuation_request}]} = error} =
               GrantContinuationRequest.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    wire = %{"interact_ref" => "private-reference", "custom" => "private-extension"}
    {:ok, request} = GrantContinuationRequest.from_map(wire)
    refute inspect(request) =~ "private-"
    assert GrantContinuationRequest.to_map(request) == wire
    assert Jason.decode!(Jason.encode!(request)) == wire
  end
end
