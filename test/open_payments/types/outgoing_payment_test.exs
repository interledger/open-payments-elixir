defmodule OpenPayments.Types.OutgoingPaymentTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, OutgoingPayment}

  @debit %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @sent %{"value" => "1205", "assetCode" => "USD", "assetScale" => 2}
  @wire %{
    "id" => "https://resource.example.com/outgoing-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "debitAmount" => @debit,
    "receiveAmount" => @receive,
    "sentAmount" => @sent,
    "createdAt" => "2026-11-18T09:20:50Z"
  }

  test "matches pinned required fields, strict root and optional failed default without inserting it" do
    {:ok, schema} = Specification.fetch_schema(:resource, "outgoing-payment")
    assert schema["type"] == "object" and schema["additionalProperties"] == false

    assert Enum.sort(schema["required"]) ==
             ~w(createdAt debitAmount id receiveAmount receiver sentAmount walletAddress)

    assert Enum.sort(Map.keys(schema["properties"])) ==
             ~w(createdAt debitAmount failed id metadata quoteId receiveAmount receiver sentAmount walletAddress)

    for name <- ~w(id walletAddress quoteId),
        do: assert(schema["properties"][name]["format"] == "uri")

    assert schema["properties"]["createdAt"]["format"] == "date-time"
    assert schema["properties"]["failed"]["type"] == "boolean"
    assert schema["properties"]["failed"]["default"] == false
    assert schema["properties"]["metadata"]["type"] == "object"
    assert schema["properties"]["metadata"]["additionalProperties"] == true

    for name <- ~w(debitAmount receiveAmount sentAmount),
        do: assert(schema["properties"][name]["$ref"] == "#/components/schemas/amount")

    assert schema["properties"]["receiver"]["$ref"] == "#/components/schemas/receiver"
  end

  test "round trips every official GET and list item example unchanged" do
    paths = Specification.document(:resource)["paths"]

    get =
      paths["/outgoing-payments/{id}"]["get"]["responses"]["200"]["content"]["application/json"]

    list = paths["/outgoing-payments"]["get"]["responses"]["200"]["content"]["application/json"]
    assert get["schema"] == %{"$ref" => "#/components/schemas/outgoing-payment"}
    assert list["schema"]["properties"]["result"]["items"] == get["schema"]
    assert map_size(get["examples"]) > 0 and map_size(list["examples"]) > 0

    examples =
      Enum.map(get["examples"], fn {_name, %{"value" => wire}} -> wire end) ++
        Enum.flat_map(list["examples"], fn {_name, %{"value" => page}} -> page["result"] end)

    for wire <- examples do
      assert {:ok,
              %OutgoingPayment{
                debit_amount: %Amount{},
                receive_amount: %Amount{},
                sent_amount: %Amount{}
              } = payment} = OutgoingPayment.from_map(wire)

      assert :ok = OutgoingPayment.validate(payment)
      assert OutgoingPayment.to_map(payment) == wire
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "records the invalid standalone example without repairing its missing amount or receiver" do
    {:ok, schema} = Specification.fetch_schema(:resource, "outgoing-payment")
    [valid, invalid] = schema["examples"]
    assert {:ok, payment} = OutgoingPayment.from_map(valid)
    assert OutgoingPayment.to_map(payment) == valid
    refute Map.has_key?(invalid, "receiveAmount")

    assert {:error, %Error{validation_errors: [%{field: :receive_amount}]}} =
             OutgoingPayment.from_map(invalid)

    assert {:error, %Error{validation_errors: [%{field: :receiver}]}} =
             OutgoingPayment.from_map(Map.put(invalid, "receiveAmount", @receive))
  end

  test "requires every declared required field and rejects explicit null without defaults" do
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
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               OutgoingPayment.from_map(wire)
    end
  end

  test "preserves optional quote, false or true failed, and empty or nested metadata independently" do
    for failed <- [:omitted, false, true],
        quote <- [:omitted, "urn:example:quote:private-reference"],
        metadata <- [:omitted, %{}, %{"private-data" => [nil, false, 2, %{"☕" => "value"}]}] do
      wire =
        Enum.reduce(
          [{"failed", failed}, {"quoteId", quote}, {"metadata", metadata}],
          @wire,
          fn
            {_name, :omitted}, wire -> wire
            {name, value}, wire -> Map.put(wire, name, value)
          end
        )

      assert {:ok, payment} = OutgoingPayment.from_map(wire)
      assert payment.failed == if(failed == :omitted, do: nil, else: failed)
      assert :ok = OutgoingPayment.validate(payment)
      assert OutgoingPayment.to_map(payment) == wire
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "rejects explicit optional nulls and wrong optional types" do
    for {name, field, values} <- [
          {"failed", :failed, [nil, "false", 0, 1, [], %{}]},
          {"quoteId", :quote_id, [nil, "", "private-relative", false, 1, [], %{}, <<255>>]},
          {"metadata", :metadata,
           [
             nil,
             false,
             "private-string",
             [],
             %{private_key: "private-value"},
             %{"private" => self()},
             %{"private" => <<255>>},
             %URI{}
           ]}
        ],
        value <- values do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               OutgoingPayment.from_map(Map.put(@wire, name, value))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves URI data spelling without network-target restrictions or pointer resolution" do
    wire =
      Map.merge(@wire, %{
        "id" => "urn:example:payment",
        "walletAddress" => "https://Wallet.Example.COM:8443/alice%2Fid?part=1#state",
        "quoteId" => "ftp://quotes.example.com:2121/quote%2Fid?part=1#state",
        "receiver" => "http://localhost:3000/tenant/incoming-payments/payment%2Fid?part=1#state"
      })

    assert {:ok, payment} = OutgoingPayment.from_map(wire)
    assert :ok = OutgoingPayment.validate(payment)
    assert OutgoingPayment.to_map(payment) == wire

    for {name, field} <- [{"id", :id}, {"walletAddress", :wallet_address}, {"quoteId", :quote_id}],
        value <- [
          "$wallet.example.com/alice",
          "/private-relative",
          "https://",
          "https://x/%no",
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               OutgoingPayment.from_map(Map.put(@wire, name, value))
    end
  end

  test "enforces the shared incoming-payment receiver pattern without UUID assumptions" do
    for receiver <- [
          "https://receiver.example.com/tenant/incoming-payments/opaque-id",
          "http://localhost:3000/incoming-payments/a%2Fb"
        ] do
      assert {:ok, _payment} = OutgoingPayment.from_map(%{@wire | "receiver" => receiver})
    end

    for receiver <- [
          "urn:example:payment",
          "$receiver.example.com/alice",
          "https://receiver.example.com/quotes/quote-1",
          "https://receiver.example.com/incoming-payments/",
          "https://receiver.example.com/incoming-payments/a%xx",
          false,
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: :receiver}]}} =
               OutgoingPayment.from_map(%{@wire | "receiver" => receiver})
    end
  end

  test "preserves valid RFC 3339 timestamps and rejects malformed creation data" do
    for created <- [
          "2020-01-01T00:00:00Z",
          "2024-02-29t09:20:50.123456789z",
          "1996-12-19T16:39:57-08:00",
          "1990-12-31T23:59:60Z",
          "2026-11-18T09:20:50-00:00"
        ] do
      wire = %{@wire | "createdAt" => created}
      assert {:ok, payment} = OutgoingPayment.from_map(wire)
      assert OutgoingPayment.to_map(payment) == wire
    end

    for created <- [
          "2026-02-29T00:00:00Z",
          "2026-11-18",
          "2026-11-18T24:00:00Z",
          false,
          1,
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: :created_at}]}} =
               OutgoingPayment.from_map(%{@wire | "createdAt" => created})
    end
  end

  test "keeps all three uint64 decimal spellings and permitted nested amount extensions" do
    for name <- ~w(debitAmount receiveAmount sentAmount),
        value <- ["0", "0000", "18446744073709551615"] do
      amount =
        Map.merge(@debit, %{"value" => value, "private-extension" => %{"☕" => [nil, true]}})

      wire = Map.put(@wire, name, amount)
      assert {:ok, payment} = OutgoingPayment.from_map(wire)
      assert :ok = OutgoingPayment.validate(payment)
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "prefixes amount validation failures for every amount without leaking values or names" do
    for {name, parent} <- [
          {"debitAmount", "debit_amount"},
          {"receiveAmount", "receive_amount"},
          {"sentAmount", "sent_amount"}
        ],
        {amount, suffix} <- [
          {%{@debit | "value" => "private-amount"}, "value"},
          {%{@debit | "value" => "18446744073709551616"}, "value"},
          {%{@debit | "value" => 12}, "value"},
          {%{@debit | "assetScale" => 256}, "asset_scale"},
          {%{@debit | "assetCode" => <<255>>}, "asset_code"},
          {Map.put(@debit, "private-extension", self()), "extensions"}
        ] do
      field = parent <> "." <> suffix

      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               OutgoingPayment.from_map(Map.put(@wire, name, amount))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "rejects undeclared legacy, spent-amount, alias and extra fields and malformed roots" do
    for name <- [
          "updatedAt",
          "expiresAt",
          "method",
          "grantSpentDebitAmount",
          "grantSpentReceiveAmount",
          "extensions",
          "private-field",
          "wallet_address",
          "quote_id",
          "sent_amount",
          :failed
        ] do
      assert {:error, %Error{validation_errors: [%{field: :outgoing_payment}]} = error} =
               OutgoingPayment.from_map(Map.put(@wire, name, "private-value"))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    {:ok, payment} = OutgoingPayment.from_map(@wire)

    for root <- [nil, false, 1, "private-root", [], %URI{}, payment] do
      assert {:error, %Error{validation_errors: [%{field: :outgoing_payment}]} = error} =
               OutgoingPayment.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-root"
    end
  end

  test "leaves asset, value-order and failed consistency checks to the HTTP operations" do
    for wire <- [
          Map.put(@wire, "sentAmount", %{@sent | "assetCode" => "GBP", "assetScale" => 0}),
          Map.put(@wire, "sentAmount", %{@sent | "value" => "18446744073709551615"}),
          Map.merge(@wire, %{"sentAmount" => @debit, "failed" => true}),
          Map.merge(@wire, %{"debitAmount" => %{@debit | "value" => "0"}, "failed" => false})
        ] do
      assert {:ok, payment} = OutgoingPayment.from_map(wire)
      assert :ok = OutgoingPayment.validate(payment)
      assert OutgoingPayment.to_map(payment) == wire
    end
  end

  test "fully revalidates modified structs and typed amounts while nil optional fields are omitted" do
    {:ok, payment} = OutgoingPayment.from_map(@wire)

    for {invalid, field} <- [
          {%{payment | id: "private-relative"}, :id},
          {%{payment | wallet_address: nil}, :wallet_address},
          {%{payment | receiver: "private-relative"}, :receiver},
          {%{payment | created_at: "private-date"}, :created_at},
          {%{payment | quote_id: "private-relative"}, :quote_id},
          {%{payment | failed: "private-failed"}, :failed},
          {%{payment | metadata: %{private_key: "private-value"}}, :metadata},
          {%{payment | receive_amount: @receive}, :receive_amount},
          {%{payment | debit_amount: nil}, :debit_amount},
          {%{payment | sent_amount: nil}, :sent_amount},
          {%{payment | receive_amount: %{payment.receive_amount | asset_scale: 256}},
           "receive_amount.asset_scale"},
          {%{payment | debit_amount: %{payment.debit_amount | value: "private-amount"}},
           "debit_amount.value"},
          {%{payment | sent_amount: %{payment.sent_amount | asset_code: false}},
           "sent_amount.asset_code"}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               OutgoingPayment.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    assert :ok = OutgoingPayment.validate(%{payment | quote_id: nil, failed: nil, metadata: nil})
  end

  test "inspection hides wallet, receiver, quote, amounts and metadata while explicit exports include them" do
    wire =
      Map.merge(@wire, %{
        "walletAddress" => "https://wallet.example.com/private-wallet",
        "receiver" => "https://receiver.example.com/incoming-payments/private-receiver",
        "quoteId" => "urn:example:private-quote",
        "failed" => false,
        "metadata" => %{"private-metadata" => "secret"}
      })

    {:ok, payment} = OutgoingPayment.from_map(wire)
    refute inspect(payment) =~ "private-"
    refute inspect(payment) =~ "2500"
    assert inspect(payment) =~ payment.id
    assert inspect(payment) =~ "failed: false"
    assert OutgoingPayment.to_map(payment) == wire
    assert Jason.decode!(Jason.encode!(payment)) == wire
    assert OutgoingPayment.to_map(%{payment | failed: "unchecked"})["failed"] == "unchecked"
  end
end
