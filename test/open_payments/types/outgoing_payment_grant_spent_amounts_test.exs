defmodule OpenPayments.Types.OutgoingPaymentGrantSpentAmountsTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, OutgoingPaymentGrantSpentAmounts}

  @amount %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @wire %{"spentReceiveAmount" => @amount, "spentDebitAmount" => @amount}
  @empty %{"spentReceiveAmount" => nil, "spentDebitAmount" => nil}

  test "matches the pinned inline required nullable fields and permitted wrapper extensions" do
    schema = content()["schema"]
    assert schema["type"] == "object"
    assert Enum.sort(schema["required"]) == ~w(spentDebitAmount spentReceiveAmount)
    assert Enum.sort(Map.keys(schema["properties"])) == ~w(spentDebitAmount spentReceiveAmount)
    refute Map.has_key?(schema, "additionalProperties")

    for name <- ~w(spentReceiveAmount spentDebitAmount) do
      assert schema["properties"][name]["anyOf"] == [
               %{"$ref" => "#/components/schemas/amount"},
               %{"type" => "null"}
             ]
    end
  end

  test "round trips both official amount and null examples unchanged" do
    assert map_size(content()["examples"]) == 2

    for {_name, %{"value" => wire}} <- content()["examples"] do
      assert {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(wire)
      assert :ok = OutgoingPaymentGrantSpentAmounts.validate(response)
      assert OutgoingPaymentGrantSpentAmounts.to_map(response) == wire
      assert Jason.decode!(Jason.encode!(response)) == wire
    end
  end

  test "supports every independent amount-or-null combination and always exports both fields" do
    {:ok, amount} = Amount.from_map(@amount)

    for receive <- [nil, amount], debit <- [nil, amount] do
      response = %OutgoingPaymentGrantSpentAmounts{
        spent_receive_amount: receive,
        spent_debit_amount: debit
      }

      wire = %{
        "spentReceiveAmount" => if(is_nil(receive), do: nil, else: @amount),
        "spentDebitAmount" => if(is_nil(debit), do: nil, else: @amount)
      }

      assert :ok = OutgoingPaymentGrantSpentAmounts.validate(response)
      assert OutgoingPaymentGrantSpentAmounts.to_map(response) == wire
      assert Jason.decode!(Jason.encode!(response)) == wire
      assert {:ok, ^response} = OutgoingPaymentGrantSpentAmounts.from_map(wire)
    end
  end

  test "requires both map fields even when the other is null and never substitutes aliases or creation fields" do
    for {name, field} <- [
          {"spentReceiveAmount", :spent_receive_amount},
          {"spentDebitAmount", :spent_debit_amount}
        ],
        wire <- [@wire, @empty] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               OutgoingPaymentGrantSpentAmounts.from_map(Map.delete(wire, name))
    end

    for wire <- [
          %{},
          %{"grantSpentReceiveAmount" => @amount, "grantSpentDebitAmount" => @amount},
          %{"spent_receive_amount" => @amount, "spent_debit_amount" => @amount},
          %{spentReceiveAmount: @amount, spentDebitAmount: @amount}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :spent_receive_amount}]}} =
               OutgoingPaymentGrantSpentAmounts.from_map(wire)
    end
  end

  test "preserves null versus zero and unrelated assets without inferring grant state or budget rules" do
    zero = %{@amount | "value" => "0"}

    for wire <- [
          @empty,
          %{"spentReceiveAmount" => zero, "spentDebitAmount" => nil},
          %{"spentReceiveAmount" => nil, "spentDebitAmount" => zero},
          %{
            "spentReceiveAmount" => %{
              @amount
              | "value" => "18446744073709551615",
                "assetCode" => "JPY",
                "assetScale" => 0
            },
            "spentDebitAmount" => %{
              @amount
              | "value" => "0000",
                "assetCode" => "EUR",
                "assetScale" => 255
            }
          }
        ] do
      assert {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(wire)
      assert :ok = OutgoingPaymentGrantSpentAmounts.validate(response)
      assert OutgoingPaymentGrantSpentAmounts.to_map(response) == wire
    end
  end

  test "preserves uint64 decimal spelling and permitted nested amount extensions in both fields" do
    for name <- ~w(spentReceiveAmount spentDebitAmount),
        value <- ["0", "0000", "18446744073709551615"] do
      amount = Map.merge(@amount, %{"value" => value, "private-extra" => [nil, %{"☕" => true}]})
      wire = Map.put(@wire, name, amount)
      assert {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(wire)
      assert :ok = OutgoingPaymentGrantSpentAmounts.validate(response)
      assert Jason.decode!(Jason.encode!(response)) == wire
    end
  end

  test "prefixes malformed amount and nested errors without exposing rejected values or names" do
    for {name, parent} <- [
          {"spentReceiveAmount", :spent_receive_amount},
          {"spentDebitAmount", :spent_debit_amount}
        ],
        {value, suffix} <- [
          {false, nil},
          {1, nil},
          {"private-amount", nil},
          {[], nil},
          {%URI{}, nil},
          {%{@amount | "value" => "private-value"}, "value"},
          {%{@amount | "value" => "18446744073709551616"}, "value"},
          {%{@amount | "value" => 12}, "value"},
          {%{@amount | "assetCode" => <<255>>}, "asset_code"},
          {%{@amount | "assetScale" => 256}, "asset_scale"},
          {Map.put(@amount, "private-extra", self()), "extensions"}
        ] do
      field = if is_nil(suffix), do: parent, else: "#{parent}.#{suffix}"

      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               OutgoingPaymentGrantSpentAmounts.from_map(Map.put(@wire, name, value))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves allowed root JSON data without interpreting nested or creation-response names" do
    extras = %{
      "grantSpentDebitAmount" => "uninterpreted",
      "spent_receive_amount" => "uninterpreted",
      "private-extra" => %{"spentDebitAmount" => [nil, false, 1]}
    }

    wire = Map.merge(@empty, extras)
    assert {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(wire)
    assert response.extensions == extras
    assert :ok = OutgoingPaymentGrantSpentAmounts.validate(response)
    assert OutgoingPaymentGrantSpentAmounts.to_map(response) == wire
    assert Jason.decode!(Jason.encode!(response)) == wire

    for extra <- [%{private_key: true}, %{"private-key" => self()}, %{"private-key" => <<255>>}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]} = error} =
               OutgoingPaymentGrantSpentAmounts.from_map(Map.merge(@empty, extra))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates manually changed typed amounts and extension data with safe paths" do
    {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(@wire)

    for {invalid, field} <- [
          {%{response | spent_receive_amount: @amount}, :spent_receive_amount},
          {%{response | spent_debit_amount: false}, :spent_debit_amount},
          {%{
             response
             | spent_receive_amount: %{response.spent_receive_amount | value: "private-value"}
           }, "spent_receive_amount.value"},
          {%{response | spent_debit_amount: %{response.spent_debit_amount | asset_scale: 256}},
           "spent_debit_amount.asset_scale"},
          {%{response | extensions: nil}, :extensions},
          {%{response | extensions: []}, :extensions},
          {%{response | extensions: %{private_key: true}}, :extensions},
          {%{response | extensions: %{"private-key" => self()}}, :extensions}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               OutgoingPaymentGrantSpentAmounts.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    invalid = %{response | spent_receive_amount: false, spent_debit_amount: false}

    assert {:error, %Error{validation_errors: errors}} =
             OutgoingPaymentGrantSpentAmounts.validate(invalid)

    assert Enum.map(errors, & &1.field) == [:spent_receive_amount, :spent_debit_amount]
  end

  test "protects both reserved fields on explicit export without dropping required nulls or validating amounts" do
    {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(@empty)

    for name <- ~w(spentReceiveAmount spentDebitAmount) do
      invalid = %{response | extensions: %{name => "private-shadow"}}

      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               OutgoingPaymentGrantSpentAmounts.validate(invalid)

      assert OutgoingPaymentGrantSpentAmounts.to_map(invalid) == @empty
      assert Jason.decode!(Jason.encode!(invalid)) == @empty
    end

    {:ok, with_amounts} = OutgoingPaymentGrantSpentAmounts.from_map(@wire)

    unchecked = %{
      with_amounts
      | spent_debit_amount: %{with_amounts.spent_debit_amount | value: "unchecked"}
    }

    assert OutgoingPaymentGrantSpentAmounts.to_map(unchecked)["spentDebitAmount"]["value"] ==
             "unchecked"
  end

  test "rejects malformed roots and other structs without retaining rejected data" do
    {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(@empty)

    for root <- [nil, false, 1, "private-root", [], %URI{}, response] do
      assert {:error,
              %Error{validation_errors: [%{field: :outgoing_payment_grant_spent_amounts}]} = error} =
               OutgoingPaymentGrantSpentAmounts.from_map(root)

      assert error.description == "Invalid Open Payments outgoing-payment grant spent amounts"
      refute inspect(Map.from_struct(error)) =~ "private-root"
    end
  end

  test "inspection hides both amounts and extension payloads while explicit exports retain them" do
    wire = Map.put(@wire, "private-extension", %{"secret" => "private-value"})
    {:ok, response} = OutgoingPaymentGrantSpentAmounts.from_map(wire)
    refute inspect(response) =~ "2500"
    refute inspect(response) =~ "USD"
    refute inspect(response) =~ "private-"
    assert OutgoingPaymentGrantSpentAmounts.to_map(response) == wire
    assert Jason.decode!(Jason.encode!(response)) == wire
  end

  defp content do
    Specification.document(:resource)["paths"]["/outgoing-payment-grant"]["get"]["responses"][
      "200"
    ]["content"]["application/json"]
  end
end
