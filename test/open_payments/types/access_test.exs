defmodule OpenPayments.Types.AccessTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Access, AccessIncoming, AccessOutgoing, AccessQuote}

  @incoming %{"type" => "incoming-payment", "actions" => ["create", "read"]}
  @outgoing %{
    "type" => "outgoing-payment",
    "actions" => ["read"],
    "identifier" => "https://wallet.example.com/alice"
  }
  @quote %{"type" => "quote", "actions" => ["create"]}

  test "matches pinned array cardinality, uniqueness and the three-way closed union" do
    {:ok, schema} = Specification.fetch_schema(:auth, "access")
    assert schema["type"] == "array"
    assert schema["maxItems"] == 3
    assert schema["uniqueItems"] == true
    refute Map.has_key?(schema, "minItems")
    assert schema["items"] == %{"$ref" => "#/components/schemas/access-item"}
    {:ok, item} = Specification.fetch_schema(:auth, "access-item")
    assert item["unevaluatedProperties"] == false

    assert item["oneOf"] ==
             Enum.map(
               ~w(access-incoming access-outgoing access-quote),
               &%{"$ref" => "#/components/schemas/#{&1}"}
             )
  end

  test "round trips complete access arrays from the official grant examples" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    arrays =
      for {_name, example} <- examples,
          access = get_in(example, ["value", "access_token", "access"]),
          not is_nil(access),
          do: access

    assert arrays != []

    for wire <- arrays do
      assert {:ok, access} = Access.from_list(wire)
      assert :ok = Access.validate(access)
      assert Access.to_list(access) == wire
      assert Jason.decode!(Jason.encode!(access)) == wire
    end
  end

  test "accepts zero to three ordered typed entries and rejects non-arrays and oversized arrays" do
    for wire <- [[], [@quote], [@outgoing, @quote], [@quote, @incoming, @outgoing]] do
      assert {:ok, access} = Access.from_list(wire)
      assert Access.to_list(access) == wire
      assert :ok = Access.validate(access)
    end

    assert {:ok, [%AccessQuote{}, %AccessIncoming{}, %AccessOutgoing{}]} =
             Access.from_list([@quote, @incoming, @outgoing])

    for value <- [nil, %{}, "private-array", false, List.duplicate(@quote, 4)] do
      assert {:error, %Error{validation_errors: [%{field: :access}]} = error} =
               Access.from_list(value)

      refute inspect(Map.from_struct(error)) =~ "private-array"
    end

    {:ok, [quote]} = Access.from_list([@quote])

    assert {:error, %Error{validation_errors: [%{field: :access}]}} =
             Access.validate(List.duplicate(quote, 4))

    assert {:error, %Error{validation_errors: [%{field: :access}]}} = Access.validate(nil)
  end

  test "preserves distinct entries of the same type without merging actions or identifiers" do
    wire = [
      @incoming,
      Map.put(@incoming, "identifier", "https://wallet.example.com/alice"),
      Map.put(@incoming, "actions", ["read", "create"])
    ]

    assert {:ok, [%AccessIncoming{}, %AccessIncoming{}, %AccessIncoming{}] = access} =
             Access.from_list(wire)

    assert Access.to_list(access) == wire
    assert Jason.decode!(Jason.encode!(access)) == wire
  end

  test "rejects duplicate complete objects independent of object-key order" do
    reordered = Jason.decode!(~s({"actions":["create","read"],"type":"incoming-payment"}))

    assert {:error, %Error{validation_errors: [%{field: :access}]}} =
             Access.from_list([@incoming, reordered])

    {:ok, access} = Access.from_list([@incoming])

    assert {:error, %Error{validation_errors: [%{field: :access}]}} =
             Access.validate(access ++ access)
  end

  test "uses JSON numeric equality inside extension data when detecting duplicates" do
    first = Map.put(@outgoing, "limits", %{"custom" => %{"nested" => [1, %{"value" => 2}]}})
    second = Map.put(@outgoing, "limits", %{"custom" => %{"nested" => [1.0, %{"value" => 2.0}]}})

    assert {:error, %Error{validation_errors: [%{field: :access}]}} =
             Access.from_list([first, second])

    distinct = Map.put(@outgoing, "limits", %{"custom" => %{"nested" => [true, %{"value" => 2}]}})
    assert {:ok, _} = Access.from_list([first, distinct])
  end

  test "indexes unsupported, missing-type and malformed entries without retaining values" do
    for {entry, field} <- [
          {%{}, "access[1].type"},
          {%{"type" => "private-unknown-type"}, "access[1].type"},
          {nil, "access[1]"},
          {"private-entry", "access[1]"},
          {%URI{}, "access[1]"},
          {Map.put(@quote, "identifier", "private-extra"), "access[1]"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               Access.from_list([@incoming, entry])

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "collects safe indexed errors across entries and nested card payloads" do
    wire = [
      Map.put(@incoming, "actions", ["private-action"]),
      Map.put(@outgoing, "cardAuthorization", %{
        "tlvData" => "private-card-data",
        "requestId" => "test-id",
        "pwk" => %{"key" => ["private-key"], "kvc" => "test-kvc", "iv" => "test-iv"}
      })
    ]

    assert {:error, %Error{validation_errors: issues} = error} = Access.from_list(wire)

    assert Enum.map(issues, & &1.field) == [
             "access[0].actions",
             "access[1].card_authorization.pwk.key"
           ]

    refute inspect(Map.from_struct(error)) =~ "private-"
  end

  test "revalidates typed entries and rejects wire maps in manually modified typed lists" do
    {:ok, [incoming, outgoing, quote]} = Access.from_list([@incoming, @outgoing, @quote])

    assert {:error, %Error{validation_errors: [%{field: "access[0]"}]}} =
             Access.validate([@incoming])

    assert {:error, %Error{validation_errors: [%{field: "access[0].type"}]}} =
             Access.validate([%{incoming | type: "quote"}])

    assert {:error, %Error{validation_errors: [%{field: "access[0].identifier"}]}} =
             Access.validate([%{outgoing | identifier: nil}])

    assert {:error, %Error{validation_errors: [%{field: "access[0].actions"}]}} =
             Access.validate([%{quote | actions: ["complete"]}])
  end

  test "typed-list inspection hides nested sensitive data while explicit encoding preserves it" do
    wire = [
      Map.put(@outgoing, "cardAuthorization", %{
        "tlvData" => "private-card-data",
        "requestId" => "private-request-id"
      })
    ]

    assert {:ok, access} = Access.from_list(wire)
    refute inspect(access) =~ "private-"
    assert Access.to_list(access) == wire
    assert Jason.decode!(Jason.encode!(access)) == wire
  end
end
