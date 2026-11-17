defmodule OpenPayments.Types.AccessOutgoingTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{AccessOutgoing, CardAuthorization, OutgoingLimits}

  @actions ~w(create read read-all list list-all)
  @amount %{"value" => "500", "assetCode" => "USD", "assetScale" => 2}
  @card %{"tlvData" => "private-card-data", "requestId" => "test-request-id"}
  @access %{
    "type" => "outgoing-payment",
    "actions" => ["create", "read"],
    "identifier" => "https://wallet.example.com/alice"
  }

  test "matches the pinned outgoing branch and closed union" do
    {:ok, schema} = Specification.fetch_schema(:auth, "access-outgoing")
    assert schema["required"] == ~w(type actions identifier)
    assert schema["properties"]["type"]["enum"] == ["outgoing-payment"]
    assert schema["properties"]["actions"]["items"]["enum"] == @actions
    assert schema["properties"]["actions"]["uniqueItems"] == true
    refute Map.has_key?(schema["properties"]["actions"], "minItems")
    assert schema["properties"]["identifier"]["format"] == "uri"
    assert schema["properties"]["limits"] == %{"$ref" => "#/components/schemas/limits-outgoing"}

    assert schema["properties"]["cardAuthorization"] == %{
             "$ref" => "#/components/schemas/card-authorization"
           }

    {:ok, union} = Specification.fetch_schema(:auth, "access-item")
    assert union["unevaluatedProperties"] == false
  end

  test "decodes and round trips outgoing entries in official grant examples" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    entries =
      for {_name, example} <- examples,
          entry <- get_in(example, ["value", "access_token", "access"]) || [],
          entry["type"] == "outgoing-payment",
          do: entry

    assert entries != []

    for wire <- entries do
      assert {:ok, %AccessOutgoing{} = access} = AccessOutgoing.from_map(wire)
      if Map.has_key?(wire, "limits"), do: assert(%OutgoingLimits{} = access.limits)

      if Map.has_key?(wire, "cardAuthorization"),
        do: assert(%CardAuthorization{} = access.card_authorization)

      assert :ok = AccessOutgoing.validate(access)
      assert AccessOutgoing.to_map(access) == wire
      assert Jason.decode!(Jason.encode!(access)) == wire
    end
  end

  test "requires exact type, actions and identifier without defaulting or coercion" do
    for {wire_field, field} <- [
          {"type", :type},
          {"actions", :actions},
          {"identifier", :identifier}
        ],
        data <- [
          Map.delete(@access, wire_field),
          Map.put(@access, wire_field, nil),
          Map.put(@access, wire_field, 1)
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               AccessOutgoing.from_map(data)
    end

    for type <- ["incoming-payment", "quote", "Outgoing-Payment", :outgoing_payment] do
      assert {:error, %Error{validation_errors: [%{field: :type}]}} =
               AccessOutgoing.from_map(Map.put(@access, "type", type))
    end
  end

  test "preserves valid action order and emptiness while rejecting unsupported or duplicate actions" do
    for actions <- [[], @actions, Enum.reverse(@actions)] ++ Enum.map(@actions, &[&1]) do
      wire = %{@access | "actions" => actions}
      assert {:ok, access} = AccessOutgoing.from_map(wire)
      assert AccessOutgoing.to_map(access) == wire
    end

    for actions <- [
          "create",
          %{},
          ["complete"],
          ["delete"],
          [:read],
          ["read", "read"],
          ["read", nil]
        ] do
      assert {:error, %Error{validation_errors: [%{field: :actions}]}} =
               AccessOutgoing.from_map(Map.put(@access, "actions", actions))
    end
  end

  test "preserves identifier URI data without applying receiver or request-target rules" do
    for identifier <- [
          "https://Wallet.Example.COM:8443/tenant/resource?x=1#state",
          "http://localhost:3000/accounts/alice",
          "urn:example:resource"
        ] do
      wire = Map.put(@access, "identifier", identifier)
      assert {:ok, access} = AccessOutgoing.from_map(wire)
      assert AccessOutgoing.to_map(access) == wire
    end

    for identifier <- ["", "/relative", "$wallet.example.com/alice", "https://", <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :identifier}]}} =
               AccessOutgoing.from_map(Map.put(@access, "identifier", identifier))
    end
  end

  test "distinguishes omitted optional objects, empty limits and explicit nulls" do
    {:ok, access} = AccessOutgoing.from_map(@access)
    assert access.limits == nil
    assert access.card_authorization == nil
    assert AccessOutgoing.to_map(access) == @access

    assert {:ok, %AccessOutgoing{limits: %OutgoingLimits{}}} =
             AccessOutgoing.from_map(Map.put(@access, "limits", %{}))

    for {wire_field, field} <- [{"limits", :limits}, {"cardAuthorization", :card_authorization}],
        value <- [nil, [], false] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               AccessOutgoing.from_map(Map.put(@access, wire_field, value))
    end
  end

  test "prefixes nested limit and card errors and preserves safe diagnostics" do
    for {fields, field} <- [
          {%{"limits" => %{"debitAmount" => %{@amount | "value" => "private-bad-amount"}}},
           "limits.debit_amount.value"},
          {%{"limits" => %{"debitAmount" => @amount, "receiveAmount" => @amount}}, :limits},
          {%{"cardAuthorization" => Map.put(@card, "pinBlock", "private-pin")},
           "card_authorization.pwk"},
          {%{"cardAuthorization" => Map.put(@card, "extra", "private-extra")},
           :card_authorization},
          {%{
             "cardAuthorization" =>
               Map.put(@card, "pwk", %{
                 "key" => ["private-key"],
                 "kvc" => "test-kvc",
                 "iv" => "test-iv"
               })
           }, "card_authorization.pwk.key"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               AccessOutgoing.from_map(Map.merge(@access, fields))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates modified nested structs and permits omitting optional objects" do
    wire =
      Map.merge(@access, %{"limits" => %{"debitAmount" => @amount}, "cardAuthorization" => @card})

    {:ok, access} = AccessOutgoing.from_map(wire)

    for {changed, field} <- [
          {%{access | limits: %{}}, :limits},
          {%{access | card_authorization: @card}, :card_authorization},
          {%{access | limits: %{access.limits | interval: false}}, "limits.interval"},
          {%{access | card_authorization: %{access.card_authorization | tlv_data: nil}},
           "card_authorization.tlv_data"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               AccessOutgoing.validate(changed)
    end

    assert :ok = AccessOutgoing.validate(%{access | limits: nil, card_authorization: nil})
    assert AccessOutgoing.to_map(%{access | limits: nil, card_authorization: nil}) == @access
  end

  test "rejects non-objects and extra fields and hides identifier/limit/card data in inspection" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :access_outgoing}]} = error} =
               AccessOutgoing.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for extra <- [
          %{"custom" => "private-extra"},
          %{"card_authorization" => @card},
          %{limits: %{}}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :access_outgoing}]} = error} =
               AccessOutgoing.from_map(Map.merge(@access, extra))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    wire =
      Map.merge(@access, %{
        "identifier" => "https://private-wallet.example.com/alice",
        "limits" => %{"custom" => "private-limit"},
        "cardAuthorization" => @card
      })

    {:ok, access} = AccessOutgoing.from_map(wire)
    refute inspect(access) =~ "private-"
    assert AccessOutgoing.to_map(access) == wire
  end
end
