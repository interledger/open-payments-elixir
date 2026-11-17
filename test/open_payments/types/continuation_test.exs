defmodule OpenPayments.Types.ContinuationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{AccessToken, Continuation, ContinuationToken}

  @continuation %{
    "access_token" => %{"value" => "test-continuation-token"},
    "uri" => "https://auth.example.com/tenant/continue/opaque-id"
  }

  test "matches the pinned continuation fields and unconstrained wait integer" do
    {:ok, schema} = Specification.fetch_schema(:auth, "continue")
    assert schema["required"] == ~w(access_token uri)
    assert schema["properties"]["uri"]["format"] == "uri"
    assert schema["properties"]["wait"]["type"] == "integer"
    refute Map.has_key?(schema["properties"]["wait"], "minimum")
    refute Map.has_key?(schema["properties"]["wait"], "maximum")
    assert Map.get(schema, "additionalProperties", true) == true
  end

  test "round trips all official grant/continuation response continuation data" do
    document = Specification.document(:auth)

    continuations =
      for path <- ["/", "/continue/{id}"],
          {_name, example} <-
            document["paths"][path]["post"]["responses"]["200"]["content"]["application/json"][
              "examples"
            ],
          continuation = example["value"]["continue"],
          not is_nil(continuation),
          do: continuation

    assert continuations != []

    for wire <- continuations do
      assert {:ok, %Continuation{access_token: %ContinuationToken{}} = continuation} =
               Continuation.from_map(wire)

      assert :ok = Continuation.validate(continuation)
      assert Continuation.to_map(continuation) == wire
      assert Jason.decode!(Jason.encode!(continuation)) == wire
    end
  end

  test "requires a credential object and URI and prefixes malformed credential fields" do
    for {wire, field} <- [
          {Map.delete(@continuation, "access_token"), :access_token},
          {Map.put(@continuation, "access_token", nil), :access_token},
          {Map.put(@continuation, "access_token", "private-token"), :access_token},
          {Map.put(@continuation, "access_token", %{}), "access_token.value"},
          {Map.put(@continuation, "access_token", %{"value" => ["private-token"]}),
           "access_token.value"},
          {Map.delete(@continuation, "uri"), :uri},
          {Map.put(@continuation, "uri", nil), :uri}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               Continuation.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-token"
    end
  end

  test "preserves opaque continuation URI data without inferring a provider path" do
    for uri <- [
          "https://Auth.Example.COM:8443/tenant/opaque%2Fpath?part=1#state",
          "http://localhost:3006/tenant/continue/id",
          "urn:example:continuation"
        ] do
      wire = %{@continuation | "uri" => uri}
      assert {:ok, continuation} = Continuation.from_map(wire)
      assert Continuation.to_map(continuation) == wire
    end

    for uri <- [
          "",
          "/continue/id",
          "$auth.example.com/id",
          "https://",
          "https://auth.example.com/%xx",
          1
        ] do
      assert {:error, %Error{validation_errors: [%{field: :uri}]}} =
               Continuation.from_map(%{@continuation | "uri" => uri})
    end
  end

  test "distinguishes omitted wait from null and preserves schema-valid wait integers" do
    assert {:ok, %Continuation{wait: nil} = continuation} = Continuation.from_map(@continuation)
    assert Continuation.to_map(continuation) == @continuation

    for wait <- [-1, 0, 30, 18_446_744_073_709_551_615] do
      wire = Map.put(@continuation, "wait", wait)
      assert {:ok, continuation} = Continuation.from_map(wire)
      assert Jason.decode!(Jason.encode!(continuation)) == wire
    end

    for wait <- [nil, "30", 1.5, false, []] do
      assert {:error, %Error{validation_errors: [%{field: :wait}]}} =
               Continuation.from_map(Map.put(@continuation, "wait", wait))
    end
  end

  test "retains JSON extensions at both levels and validates malformed extension values" do
    wire =
      Map.merge(@continuation, %{
        "custom" => [true, nil],
        "access_token" => %{
          "value" => "test-continuation-token",
          "custom-token" => %{"value" => 1}
        }
      })

    assert {:ok, continuation} = Continuation.from_map(wire)
    assert continuation.extensions == %{"custom" => [true, nil]}
    assert continuation.access_token.extensions == %{"custom-token" => %{"value" => 1}}
    assert Jason.decode!(Jason.encode!(continuation)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               Continuation.from_map(Map.merge(@continuation, extra))
    end

    assert {:error, %Error{validation_errors: [%{field: "access_token.extensions"}]}} =
             Continuation.from_map(
               Map.put(@continuation, "access_token", %{"value" => "test-token", custom: true})
             )
  end

  test "revalidates typed credentials and rejects substituting a resource-access token struct" do
    {:ok, continuation} = Continuation.from_map(@continuation)

    {:ok, resource_token} =
      AccessToken.from_map(%{
        "value" => "resource-token",
        "manage" => "https://auth.example.com/token/id",
        "access" => []
      })

    for {changed, field} <- [
          {%{continuation | access_token: resource_token}, :access_token},
          {%{continuation | access_token: %{"value" => "test-token"}}, :access_token},
          {%{continuation | access_token: %{continuation.access_token | value: nil}},
           "access_token.value"},
          {%{
             continuation
             | access_token: %{continuation.access_token | extensions: %{"value" => "override"}}
           }, "access_token.extensions"},
          {%{continuation | uri: "relative"}, :uri},
          {%{continuation | wait: 1.0}, :wait},
          {%{continuation | extensions: %{"uri" => "override"}}, :extensions}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Continuation.validate(changed)
    end

    assert :ok = Continuation.validate(%{continuation | wait: nil})

    assert Continuation.to_map(%{continuation | extensions: %{"uri" => "override", "wait" => 5}}) ==
             @continuation
  end

  test "rejects non-objects and hides continuation tokens, URLs and extensions in inspection" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :continuation}]} = error} =
               Continuation.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    wire = %{
      "access_token" => %{"value" => "private-continuation-token"},
      "uri" => "https://private-auth.example.com/opaque",
      "custom" => "private-extension",
      "wait" => 30
    }

    {:ok, continuation} = Continuation.from_map(wire)
    refute inspect(continuation) =~ "private-"
    assert continuation.wait == 30
    assert Continuation.to_map(continuation) == wire
  end
end
