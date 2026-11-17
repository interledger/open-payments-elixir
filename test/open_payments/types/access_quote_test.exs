defmodule OpenPayments.Types.AccessQuoteTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.AccessQuote

  @actions ~w(create read read-all)
  @access %{"type" => "quote", "actions" => ["create", "read"]}

  test "matches the pinned quote branch and enclosing union restrictions" do
    {:ok, schema} = Specification.fetch_schema(:auth, "access-quote")
    assert schema["required"] == ~w(type actions)
    assert Enum.sort(Map.keys(schema["properties"])) == ~w(actions type)
    assert schema["properties"]["type"]["enum"] == ["quote"]
    assert schema["properties"]["actions"]["items"]["enum"] == @actions
    assert schema["properties"]["actions"]["uniqueItems"] == true
    refute Map.has_key?(schema["properties"]["actions"], "minItems")

    {:ok, union} = Specification.fetch_schema(:auth, "access-item")
    assert union["unevaluatedProperties"] == false
    assert %{"$ref" => "#/components/schemas/access-quote"} in union["oneOf"]
  end

  test "round trips empty and supported action arrays without sorting them" do
    for actions <- [[], @actions, Enum.reverse(@actions)] ++ Enum.map(@actions, &[&1]) do
      wire = %{@access | "actions" => actions}
      assert {:ok, %AccessQuote{} = access} = AccessQuote.from_map(wire)
      assert :ok = AccessQuote.validate(access)
      assert access.actions == actions
      assert AccessQuote.to_map(access) == wire
      assert Jason.decode!(Jason.encode!(access)) == wire
    end
  end

  test "requires exact type and actions fields without defaults or coercion" do
    for {wire_field, field} <- [{"type", :type}, {"actions", :actions}],
        data <- [
          Map.delete(@access, wire_field),
          Map.put(@access, wire_field, nil),
          Map.put(@access, wire_field, 1)
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} = AccessQuote.from_map(data)
    end

    for type <- ["incoming-payment", "outgoing-payment", "QUOTE", :quote] do
      assert {:error, %Error{validation_errors: [%{field: :type}]}} =
               AccessQuote.from_map(Map.put(@access, "type", type))
    end
  end

  test "rejects other resource actions, duplicates and malformed action arrays" do
    for actions <- [
          nil,
          "read",
          %{},
          ["complete"],
          ["list"],
          ["list-all"],
          [:create],
          ["READ"],
          ["read", "read"],
          ["read", nil],
          [<<255>>]
        ] do
      assert {:error, %Error{validation_errors: [%{field: :actions}]}} =
               AccessQuote.from_map(Map.put(@access, "actions", actions))
    end
  end

  test "rejects non-objects and extra union fields without retaining rejected values" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :access_quote}]} = error} =
               AccessQuote.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for extra <- [
          %{"identifier" => "https://wallet.example.com/alice"},
          %{"limits" => %{}},
          %{"cardAuthorization" => %{}},
          %{"custom" => "private-extra"},
          %{custom: true}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :access_quote}]} = error} =
               AccessQuote.from_map(Map.merge(@access, extra))

      refute inspect(Map.from_struct(error)) =~ "private-extra"
    end
  end

  test "revalidates modified structs and reports safe field-level errors" do
    {:ok, access} = AccessQuote.from_map(@access)

    assert {:error, %Error{kind: :validation, validation_errors: issues} = error} =
             AccessQuote.validate(%{access | type: "private-type", actions: ["private-action"]})

    assert Enum.map(issues, & &1.field) == [:type, :actions]
    refute inspect(Map.from_struct(error)) =~ "private-"
  end
end
