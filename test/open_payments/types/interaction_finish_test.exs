defmodule OpenPayments.Types.InteractionFinishTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.InteractionFinish

  @finish %{
    "method" => "redirect",
    "uri" => "https://client.example.com/callback",
    "nonce" => "test-client-nonce"
  }

  test "matches the pinned interaction finish schema" do
    {:ok, schema} = Specification.fetch_schema(:auth, "interact-request")
    finish = schema["properties"]["finish"]
    assert finish["type"] == "object"
    assert finish["required"] == ~w(method uri nonce)
    assert finish["properties"]["method"]["enum"] == ["redirect"]
    assert finish["properties"]["uri"]["format"] == "uri"
    assert finish["properties"]["nonce"]["type"] == "string"
    refute Map.has_key?(finish["properties"]["nonce"], "minLength")
    assert Map.get(finish, "additionalProperties", true) == true
  end

  test "round trips callback configurations from official grant examples" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    finishes =
      for {_name, example} <- examples,
          finish = get_in(example, ["value", "interact", "finish"]),
          not is_nil(finish),
          do: finish

    assert finishes != []

    for wire <- finishes do
      assert {:ok, %InteractionFinish{} = finish} = InteractionFinish.from_map(wire)
      assert :ok = InteractionFinish.validate(finish)
      assert InteractionFinish.to_map(finish) == wire
      assert Jason.decode!(Jason.encode!(finish)) == wire
    end
  end

  test "requires the redirect method, callback URI and string nonce without coercion" do
    for {wire_field, field} <- [{"method", :method}, {"uri", :uri}, {"nonce", :nonce}],
        data <- [
          Map.delete(@finish, wire_field),
          Map.put(@finish, wire_field, nil),
          Map.put(@finish, wire_field, 1),
          Map.put(@finish, wire_field, <<255>>)
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               InteractionFinish.from_map(data)
    end

    for method <- ["push", "Redirect", :redirect, ""] do
      assert {:error, %Error{validation_errors: [%{field: :method}]}} =
               InteractionFinish.from_map(Map.put(@finish, "method", method))
    end
  end

  test "preserves absolute callback URIs and schema-valid nonce strings" do
    for uri <- [
          "http://localhost:4000/callback",
          "https://Client.Example.COM:8443/return%2fpath?state=1#done",
          "example-app://callback"
        ],
        nonce <- ["", "client-nonce", "Café 🌍"] do
      wire = %{@finish | "uri" => uri, "nonce" => nonce}
      assert {:ok, finish} = InteractionFinish.from_map(wire)
      assert InteractionFinish.to_map(finish) == wire
    end

    for uri <- [
          "",
          "/callback",
          "$client.example.com",
          "https://",
          "https://client.example.com/%xx"
        ] do
      assert {:error, %Error{validation_errors: [%{field: :uri}]}} =
               InteractionFinish.from_map(Map.put(@finish, "uri", uri))
    end
  end

  test "preserves JSON extensions and validates manually modified structs" do
    wire = Map.put(@finish, "custom", %{"version" => 1, "values" => [nil, true]})
    assert {:ok, finish} = InteractionFinish.from_map(wire)
    assert finish.extensions == Map.take(wire, ["custom"])
    assert Jason.decode!(Jason.encode!(finish)) == wire

    for extensions <- [%{custom: true}, %{"nonce" => "override"}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               InteractionFinish.validate(%{finish | extensions: extensions})
    end

    assert {:error, %Error{validation_errors: issues}} =
             InteractionFinish.validate(%{finish | method: "push", uri: "relative", nonce: false})

    assert Enum.map(issues, & &1.field) == [:method, :uri, :nonce]

    assert InteractionFinish.to_map(%{finish | extensions: %{"nonce" => "override"}})["nonce"] ==
             @finish["nonce"]
  end

  test "rejects non-objects and keeps nonce and extension values out of inspection and errors" do
    for data <- [nil, [], true, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :interaction_finish}]} = error} =
               InteractionFinish.from_map(data)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    {:ok, finish} = InteractionFinish.from_map(Map.put(@finish, "custom", "private-extension"))
    refute inspect(finish) =~ "test-client-nonce"
    refute inspect(finish) =~ "private-extension"
    assert InteractionFinish.to_map(finish)["nonce"] == @finish["nonce"]

    assert {:error, error} = InteractionFinish.from_map(%{@finish | "nonce" => ["private-nonce"]})
    refute inspect(Map.from_struct(error)) =~ "private-nonce"
  end
end
