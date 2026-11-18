defmodule OpenPayments.Types.OutgoingPaymentWithSpentAmountsTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, OutgoingPayment, OutgoingPaymentWithSpentAmounts}

  @amount %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @wire %{
    "id" => "https://resource.example.com/outgoing-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "debitAmount" => @amount,
    "receiveAmount" => %{@amount | "value" => "2198", "assetCode" => "EUR"},
    "sentAmount" => %{@amount | "value" => "0"},
    "createdAt" => "2026-11-18T09:20:50Z"
  }

  test "matches the pinned creation response with shared details, two optional amounts and open root" do
    {:ok, schema} = Specification.fetch_schema(:resource, "outgoing-payment-with-spent-amounts")
    {:ok, base} = Specification.fetch_schema(:resource, "outgoing-payment")
    assert schema["type"] == "object"
    refute Map.has_key?(schema, "additionalProperties")
    assert base["additionalProperties"] == false
    assert schema["required"] == base["required"]

    assert Map.drop(schema["properties"], ~w(grantSpentDebitAmount grantSpentReceiveAmount)) ==
             base["properties"]

    for name <- ~w(grantSpentDebitAmount grantSpentReceiveAmount) do
      assert schema["properties"][name]["$ref"] == "#/components/schemas/amount"
      refute name in schema["required"]
    end

    content =
      Specification.document(:resource)["paths"]["/outgoing-payments"]["post"]["responses"]["201"][
        "content"
      ]["application/json"]

    assert content["schema"] == %{
             "$ref" => "#/components/schemas/outgoing-payment-with-spent-amounts"
           }
  end

  test "round trips all standalone and HTTP201 examples with flat typed spent amounts" do
    {:ok, schema} = Specification.fetch_schema(:resource, "outgoing-payment-with-spent-amounts")

    examples =
      Specification.document(:resource)["paths"]["/outgoing-payments"]["post"]["responses"]["201"][
        "content"
      ]["application/json"]["examples"]

    assert length(schema["examples"]) == 2 and map_size(examples) > 0

    for wire <-
          schema["examples"] ++ Enum.map(examples, fn {_name, example} -> example["value"] end) do
      assert {:ok, %OutgoingPaymentWithSpentAmounts{} = payment} =
               OutgoingPaymentWithSpentAmounts.from_map(wire)

      for {name, field} <- [
            {"grantSpentDebitAmount", :grant_spent_debit_amount},
            {"grantSpentReceiveAmount", :grant_spent_receive_amount}
          ] do
        if Map.has_key?(wire, name), do: assert(%Amount{} = Map.fetch!(payment, field))
      end

      assert :ok = OutgoingPaymentWithSpentAmounts.validate(payment)
      assert OutgoingPaymentWithSpentAmounts.to_map(payment) == wire
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "allows neither, either or both spent amounts independently without defaults" do
    for debit <- [:omitted, @amount], receive <- [:omitted, @amount] do
      wire =
        Enum.reduce(
          [{"grantSpentDebitAmount", debit}, {"grantSpentReceiveAmount", receive}],
          @wire,
          fn
            {_name, :omitted}, wire -> wire
            {name, amount}, wire -> Map.put(wire, name, amount)
          end
        )

      assert {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(wire)
      assert payment.failed == nil
      assert payment.quote_id == nil
      assert payment.metadata == nil
      assert payment.extensions == %{}
      assert is_nil(payment.grant_spent_debit_amount) == (debit == :omitted)
      assert is_nil(payment.grant_spent_receive_amount) == (receive == :omitted)
      assert :ok = OutgoingPaymentWithSpentAmounts.validate(payment)
      assert OutgoingPaymentWithSpentAmounts.to_map(payment) == wire
    end
  end

  test "rejects null or malformed spent amounts despite the separate grant endpoint's nullable fields" do
    for {name, field} <- [
          {"grantSpentDebitAmount", :grant_spent_debit_amount},
          {"grantSpentReceiveAmount", :grant_spent_receive_amount}
        ],
        value <- [nil, false, "private-amount", 1, [], %URI{}] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               OutgoingPaymentWithSpentAmounts.from_map(Map.put(@wire, name, value))

      assert error.description == "Invalid Open Payments outgoing payment with spent amounts"
      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "retains uint64 decimal spelling and JSON extensions inside each spent amount" do
    for name <- ~w(grantSpentDebitAmount grantSpentReceiveAmount),
        value <- ["0", "0000", "18446744073709551615"] do
      amount = Map.merge(@amount, %{"value" => value, "private-extra" => [nil, %{"☕" => true}]})
      wire = Map.put(@wire, name, amount)
      assert {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(wire)
      assert :ok = OutgoingPaymentWithSpentAmounts.validate(payment)
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "prefixes nested amount errors for both spent fields without exposing values or names" do
    for {name, parent} <- [
          {"grantSpentDebitAmount", "grant_spent_debit_amount"},
          {"grantSpentReceiveAmount", "grant_spent_receive_amount"}
        ],
        {amount, suffix} <- [
          {%{@amount | "value" => "private-value"}, "value"},
          {%{@amount | "value" => "18446744073709551616"}, "value"},
          {%{@amount | "assetCode" => false}, "asset_code"},
          {%{@amount | "assetScale" => 256}, "asset_scale"},
          {Map.put(@amount, "private-extra", self()), "extensions"}
        ] do
      field = parent <> "." <> suffix

      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               OutgoingPaymentWithSpentAmounts.from_map(Map.put(@wire, name, amount))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "requires every base field and shares optional-null, URI, timestamp and nested validation" do
    for {name, field} <- [
          {"id", :id},
          {"walletAddress", :wallet_address},
          {"receiver", :receiver},
          {"debitAmount", :debit_amount},
          {"receiveAmount", :receive_amount},
          {"sentAmount", :sent_amount},
          {"createdAt", :created_at}
        ],
        wire <- [Map.delete(@wire, name), Map.put(@wire, name, nil)] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               OutgoingPaymentWithSpentAmounts.from_map(wire)
    end

    for {wire, field} <- [
          {Map.put(@wire, "quoteId", nil), :quote_id},
          {Map.put(@wire, "failed", nil), :failed},
          {Map.put(@wire, "metadata", nil), :metadata},
          {Map.put(@wire, "metadata", []), :metadata},
          {Map.put(@wire, "id", "private-relative"), :id},
          {Map.put(@wire, "receiver", "urn:example:payment"), :receiver},
          {Map.put(@wire, "createdAt", "2026-02-29T00:00:00Z"), :created_at},
          {put_in(@wire, ["sentAmount", "assetScale"], 256), "sent_amount.asset_scale"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               OutgoingPaymentWithSpentAmounts.from_map(wire)
    end
  end

  test "preserves optional details, JSON metadata and spelling through the shared detail codec" do
    wire =
      Map.merge(@wire, %{
        "id" => "urn:example:payment",
        "walletAddress" => "https://Wallet.Example.COM:8443/alice%2Fid?part=1#state",
        "receiver" => "http://localhost:3000/tenant/incoming-payments/a%2Fb?part=1#state",
        "quoteId" => "urn:example:quote",
        "failed" => false,
        "createdAt" => "2024-02-29t09:20:50.123456789z",
        "metadata" => %{}
      })

    for metadata <- [%{}, %{"private" => [nil, false, %{"☕" => "value"}]}],
        failed <- [false, true] do
      wire = Map.merge(wire, %{"metadata" => metadata, "failed" => failed})
      assert {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(wire)
      assert :ok = OutgoingPaymentWithSpentAmounts.validate(payment)
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "preserves permitted unknown JSON fields while strict read/list data rejects them" do
    extras = %{"updatedAt" => "uninterpreted", "private-extension" => [nil, true, %{"☕" => 1}]}
    wire = Map.merge(@wire, extras)
    assert {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(wire)
    assert payment.extensions == extras
    assert :ok = OutgoingPaymentWithSpentAmounts.validate(payment)
    assert OutgoingPaymentWithSpentAmounts.to_map(payment) == wire
    assert Jason.decode!(Jason.encode!(payment)) == wire

    assert {:error, %Error{validation_errors: [%{field: :outgoing_payment}]}} =
             OutgoingPayment.from_map(wire)

    for extras <- [%{private_key: true}, %{"private-key" => self()}, %{"private-key" => <<255>>}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]} = error} =
               OutgoingPaymentWithSpentAmounts.from_map(Map.merge(@wire, extras))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates shared details and both modified typed spent amounts" do
    wire =
      Map.merge(@wire, %{"grantSpentDebitAmount" => @amount, "grantSpentReceiveAmount" => @amount})

    {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(wire)

    for {invalid, field} <- [
          {%{payment | id: "private-relative"}, :id},
          {%{payment | failed: "private-failed"}, :failed},
          {%{payment | receive_amount: nil}, :receive_amount},
          {%{payment | debit_amount: %{payment.debit_amount | value: "private-value"}},
           "debit_amount.value"},
          {%{payment | sent_amount: @amount}, :sent_amount},
          {%{payment | grant_spent_debit_amount: @amount}, :grant_spent_debit_amount},
          {%{payment | grant_spent_receive_amount: false}, :grant_spent_receive_amount},
          {%{
             payment
             | grant_spent_debit_amount: %{payment.grant_spent_debit_amount | asset_scale: 256}
           }, "grant_spent_debit_amount.asset_scale"},
          {%{
             payment
             | grant_spent_receive_amount: %{
                 payment.grant_spent_receive_amount
                 | value: "private-value"
               }
           }, "grant_spent_receive_amount.value"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               OutgoingPaymentWithSpentAmounts.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    assert :ok =
             OutgoingPaymentWithSpentAmounts.validate(%{
               payment
               | grant_spent_debit_amount: nil,
                 grant_spent_receive_amount: nil
             })
  end

  test "protects every reserved wire field against manually inserted extension overrides" do
    {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(@wire)
    {:ok, schema} = Specification.fetch_schema(:resource, "outgoing-payment-with-spent-amounts")

    for name <- Map.keys(schema["properties"]) do
      invalid = %{payment | extensions: %{name => "private-override"}}

      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               OutgoingPaymentWithSpentAmounts.validate(invalid)

      assert OutgoingPaymentWithSpentAmounts.to_map(invalid) == @wire
    end

    for extensions <- [nil, [], false, %{private_key: "private-value"}, %{"private" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               OutgoingPaymentWithSpentAmounts.validate(%{payment | extensions: extensions})
    end
  end

  test "does not infer grant limits, asset matching or payment amount/failure consistency" do
    wire =
      Map.merge(@wire, %{
        "debitAmount" => %{@amount | "value" => "0"},
        "sentAmount" => %{@amount | "value" => "18446744073709551615", "assetCode" => "GBP"},
        "failed" => true,
        "grantSpentDebitAmount" => %{
          @amount
          | "value" => "0000",
            "assetCode" => "JPY",
            "assetScale" => 0
        },
        "grantSpentReceiveAmount" => %{
          @amount
          | "value" => "18446744073709551615",
            "assetScale" => 255
        }
      })

    assert {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(wire)
    assert :ok = OutgoingPaymentWithSpentAmounts.validate(payment)
    assert OutgoingPaymentWithSpentAmounts.to_map(payment) == wire
  end

  test "rejects malformed roots and hides sensitive data in errors and inspection" do
    wire =
      Map.merge(@wire, %{
        "walletAddress" => "urn:example:private-wallet",
        "receiver" => "https://receiver.example.com/incoming-payments/private-receiver",
        "quoteId" => "urn:example:private-quote",
        "metadata" => %{"private-metadata" => "secret"},
        "grantSpentDebitAmount" => Map.put(@amount, "private-debit", "secret"),
        "grantSpentReceiveAmount" => Map.put(@amount, "private-receive", "secret"),
        "private-extra" => "secret"
      })

    {:ok, payment} = OutgoingPaymentWithSpentAmounts.from_map(wire)
    refute inspect(payment) =~ "private-"
    refute inspect(payment) =~ "2500"
    refute inspect(payment) =~ "secret"
    assert inspect(payment) =~ payment.id
    assert OutgoingPaymentWithSpentAmounts.to_map(payment) == wire
    assert Jason.decode!(Jason.encode!(payment)) == wire

    for root <- [nil, false, 1, "private-root", [], %URI{}, payment] do
      assert {:error,
              %Error{validation_errors: [%{field: :outgoing_payment_with_spent_amounts}]} = error} =
               OutgoingPaymentWithSpentAmounts.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end
end
