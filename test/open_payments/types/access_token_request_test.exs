defmodule OpenPayments.Types.AccessTokenRequestTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{AccessQuote, AccessTokenRequest}

  @access [%{"type" => "quote", "actions" => ["create"]}]

  test "matches the access-token request object in both pinned grant variants" do
    for name <- ~w(grant-request-with-access-token grant-request-with-subject) do
      {:ok, grant} = Specification.fetch_schema(:auth, name)
      schema = grant["properties"]["access_token"]
      assert schema["type"] == "object"
      assert schema["required"] == ["access"]
      assert schema["properties"]["access"] == %{"$ref" => "#/components/schemas/access"}
      assert Map.get(schema, "additionalProperties", true) == true
    end
  end

  test "decodes typed access arrays and retains permitted extension data" do
    for access <- [[], @access] do
      wire = %{"access" => access, "custom" => %{"values" => [nil, true, 1]}}
      assert {:ok, %AccessTokenRequest{} = request} = AccessTokenRequest.from_map(wire)
      assert :ok = AccessTokenRequest.validate(request)
      assert AccessTokenRequest.to_map(request) == wire
      assert Jason.decode!(Jason.encode!(request)) == wire
    end
  end

  test "requires an access array and rejects non-objects with safe field paths" do
    for data <- [%{}, %{"access" => nil}, %{"access" => %{}}, %{"access" => [nil]}] do
      assert {:error, %Error{kind: :validation} = error} = AccessTokenRequest.from_map(data)
      assert Enum.all?(error.validation_errors, &(&1.field in [:access, "access[0]"]))
    end

    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :access_token_request}]} = error} =
               AccessTokenRequest.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end
  end

  test "revalidates typed arrays and extension fields without permitting reserved overrides" do
    {:ok, request} = AccessTokenRequest.from_map(%{"access" => @access})
    assert [%AccessQuote{}] = request.access

    assert {:error, %Error{validation_errors: [%{field: "access[0]"}]}} =
             AccessTokenRequest.validate(%{request | access: @access})

    assert {:error, %Error{validation_errors: [%{field: :access}]}} =
             AccessTokenRequest.validate(%{request | access: request.access ++ request.access})

    for extensions <- [%{"access" => []}, %{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               AccessTokenRequest.validate(%{request | extensions: extensions})
    end

    assert AccessTokenRequest.to_map(%{request | extensions: %{"access" => []}})["access"] ==
             @access

    for extensions <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               AccessTokenRequest.from_map(Map.merge(%{"access" => @access}, extensions))
    end
  end

  test "inspection hides card and extension values while explicit encoding retains the payload" do
    wire = %{
      "access" => [
        %{
          "type" => "outgoing-payment",
          "actions" => ["create"],
          "identifier" => "https://wallet.example.com/alice",
          "cardAuthorization" => %{
            "tlvData" => "private-card-data",
            "requestId" => "private-request-id"
          }
        }
      ],
      "custom" => "private-extension"
    }

    {:ok, request} = AccessTokenRequest.from_map(wire)
    refute inspect(request) =~ "private-"
    assert Jason.decode!(Jason.encode!(request)) == wire
  end
end
