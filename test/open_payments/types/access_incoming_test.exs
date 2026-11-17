defmodule OpenPayments.Types.AccessIncomingTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.AccessIncoming

  @actions ~w(create complete read read-all list list-all)
  @access %{"type" => "incoming-payment", "actions" => ["create", "read"]}

  test "matches the pinned incoming branch and closed access-item union" do
    {:ok, schema} = Specification.fetch_schema(:auth, "access-incoming")
    assert schema["required"] == ~w(type actions)
    assert schema["properties"]["type"]["enum"] == ["incoming-payment"]
    assert schema["properties"]["actions"]["items"]["enum"] == @actions
    assert schema["properties"]["actions"]["uniqueItems"] == true
    refute Map.has_key?(schema["properties"]["actions"], "minItems")
    assert schema["properties"]["identifier"]["format"] == "uri"

    {:ok, union} = Specification.fetch_schema(:auth, "access-item")
    assert union["unevaluatedProperties"] == false
    assert %{"$ref" => "#/components/schemas/access-incoming"} in union["oneOf"]
  end

  test "round trips incoming permissions in the official grant request examples" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    entries =
      for {_name, example} <- examples,
          access <- get_in(example, ["value", "access_token", "access"]) || [],
          access["type"] == "incoming-payment",
          do: access

    assert entries != []

    for wire <- entries do
      assert {:ok, %AccessIncoming{} = access} = AccessIncoming.from_map(wire)
      assert :ok = AccessIncoming.validate(access)
      assert AccessIncoming.to_map(access) == wire
      assert Jason.decode!(Jason.encode!(access)) == wire
    end
  end

  test "requires the exact type and actions without applying defaults or coercion" do
    for {wire_field, field} <- [{"type", :type}, {"actions", :actions}],
        data <- [
          Map.delete(@access, wire_field),
          Map.put(@access, wire_field, nil),
          Map.put(@access, wire_field, 1)
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               AccessIncoming.from_map(data)
    end

    for type <- ["quote", "Incoming-Payment", "outgoing-payment", :incoming_payment] do
      assert {:error, %Error{validation_errors: [%{field: :type}]}} =
               AccessIncoming.from_map(Map.put(@access, "type", type))
    end
  end

  test "permits empty and all valid action combinations, preserves order and rejects duplicates" do
    for actions <- [[], @actions, Enum.reverse(@actions)] ++ Enum.map(@actions, &[&1]) do
      wire = %{@access | "actions" => actions}
      assert {:ok, access} = AccessIncoming.from_map(wire)
      assert AccessIncoming.to_map(access) == wire
    end

    for actions <- [
          nil,
          "create",
          %{},
          ["delete"],
          ["CREATE"],
          [:read],
          ["read", "read"],
          ["read", false]
        ] do
      assert {:error, %Error{validation_errors: [%{field: :actions}]}} =
               AccessIncoming.from_map(Map.put(@access, "actions", actions))
    end
  end

  test "distinguishes omitted identifier from null and preserves schema-valid URI data" do
    assert {:ok, %AccessIncoming{identifier: nil} = access} = AccessIncoming.from_map(@access)
    assert AccessIncoming.to_map(access) == @access

    for identifier <- [
          "https://Wallet.Example.COM:8443/tenant/opaque%2Fid?part=1#fragment",
          "http://localhost:3000/accounts/alice",
          "urn:example:resource"
        ] do
      wire = Map.put(@access, "identifier", identifier)
      assert {:ok, access} = AccessIncoming.from_map(wire)
      assert AccessIncoming.to_map(access) == wire
    end

    for identifier <- [nil, "", "/relative", "$wallet.example.com/alice", "https://", 1, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :identifier}]}} =
               AccessIncoming.from_map(Map.put(@access, "identifier", identifier))
    end
  end

  test "rejects non-objects and fields outside the access union contract" do
    for data <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :access_incoming}]} = error} =
               AccessIncoming.from_map(data)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for extra <- [
          %{"limits" => %{}},
          %{"cardAuthorization" => %{}},
          %{"custom" => "private-extra"},
          %{identifier: "private-extra"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :access_incoming}]} = error} =
               AccessIncoming.from_map(Map.merge(@access, extra))

      refute inspect(Map.from_struct(error)) =~ "private-extra"
    end
  end

  test "validates manual changes and omits identifiers from inspection and rejected values from errors" do
    {:ok, access} =
      AccessIncoming.from_map(
        Map.put(@access, "identifier", "https://private-resource.example.com/alice")
      )

    assert :ok = AccessIncoming.validate(%{access | identifier: nil})
    refute Map.has_key?(AccessIncoming.to_map(%{access | identifier: nil}), "identifier")
    refute inspect(access) =~ "private-resource"
    assert AccessIncoming.to_map(access)["identifier"] == access.identifier

    assert {:error, %Error{validation_errors: issues} = error} =
             AccessIncoming.validate(%{
               access
               | type: "quote",
                 actions: ["private-action"],
                 identifier: "private-identifier"
             })

    assert Enum.map(issues, & &1.field) == [:type, :actions, :identifier]
    refute inspect(Map.from_struct(error)) =~ "private-"
  end
end
