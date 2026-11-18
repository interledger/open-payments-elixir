defmodule OpenPayments.Types.CreateOutgoingPaymentTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, CreateOutgoingPayment}

  @wallet "https://wallet.example.com/alice"
  @quote_id "https://resource.example.com/quotes/quote-1"
  @incoming_id "https://receiver.example.com/incoming-payments/payment-1"
  @amount %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @quote %{"walletAddress" => @wallet, "quoteId" => @quote_id}
  @incoming %{
    "walletAddress" => @wallet,
    "incomingPayment" => @incoming_id,
    "debitAmount" => @amount
  }

  test "matches both pinned closed oneOf branches and their exact required fields" do
    {:ok, union} = Specification.fetch_schema(:resource, "create-outgoing-payment-request")

    names =
      ~w(create-outgoing-payment-request-from-quote create-outgoing-payment-request-from-incoming-payment)

    assert union["oneOf"] == Enum.map(names, &%{"$ref" => "#/components/schemas/" <> &1})

    for {name, required} <-
          Enum.zip(names, [
            ~w(quoteId walletAddress),
            ~w(incomingPayment debitAmount walletAddress)
          ]) do
      {:ok, schema} = Specification.fetch_schema(:resource, name)
      assert Enum.sort(schema["required"]) == Enum.sort(required)
      assert Enum.sort(Map.keys(schema["properties"])) == Enum.sort(required ++ ["metadata"])
      assert schema["additionalProperties"] == false
      assert schema["properties"]["walletAddress"]["$ref"] == "#/components/schemas/walletAddress"
      assert schema["properties"]["metadata"]["type"] == "object"
      assert schema["properties"]["metadata"]["additionalProperties"] == true
    end

    {:ok, quote} = Specification.fetch_schema(:resource, hd(names))
    {:ok, incoming} = Specification.fetch_schema(:resource, List.last(names))
    assert quote["properties"]["quoteId"]["format"] == "uri"
    assert incoming["properties"]["incomingPayment"]["format"] == "uri"
    refute Map.has_key?(incoming["properties"]["incomingPayment"], "pattern")
    assert incoming["properties"]["debitAmount"]["$ref"] == "#/components/schemas/amount"
  end

  test "round trips both official quote and incoming-payment creation examples unchanged" do
    body = Specification.document(:resource)["paths"]["/outgoing-payments"]["post"]["requestBody"]
    assert body["required"] == true
    content = body["content"]["application/json"]

    assert content["schema"] == %{
             "$ref" => "#/components/schemas/create-outgoing-payment-request"
           }

    assert map_size(content["examples"]) == 2

    variants =
      for {_name, %{"value" => wire}} <- content["examples"] do
        assert {:ok, %CreateOutgoingPayment{} = request} = CreateOutgoingPayment.from_map(wire)
        assert :ok = CreateOutgoingPayment.validate(request)
        assert CreateOutgoingPayment.to_map(request) == wire
        assert Jason.decode!(Jason.encode!(request)) == wire
        {not is_nil(request.quote_id), is_struct(request.debit_amount, Amount)}
      end

    assert Enum.sort(variants) == [{false, true}, {true, false}]
  end

  test "supports both typed variants and omits inactive fields without adding defaults" do
    {:ok, amount} = Amount.from_map(@amount)

    for {request, wire} <- [
          {%CreateOutgoingPayment{wallet_address: @wallet, quote_id: @quote_id}, @quote},
          {%CreateOutgoingPayment{
             wallet_address: @wallet,
             incoming_payment: @incoming_id,
             debit_amount: amount
           }, @incoming}
        ] do
      assert request.metadata == nil
      assert :ok = CreateOutgoingPayment.validate(request)
      assert CreateOutgoingPayment.to_map(request) == wire
      assert Jason.decode!(Jason.encode!(request)) == wire
      assert {:ok, ^request} = CreateOutgoingPayment.from_map(wire)
    end
  end

  test "requires wallet URI in both variants without supplying defaults or accepting null" do
    for wire <- [@quote, @incoming],
        invalid <- [Map.delete(wire, "walletAddress"), Map.put(wire, "walletAddress", nil)] do
      assert {:error, %Error{validation_errors: [%{field: :wallet_address}]}} =
               CreateOutgoingPayment.from_map(invalid)
    end
  end

  test "enforces every branch presence combination and rejects mixed null fields before choosing a variant" do
    for quote? <- [false, true], incoming? <- [false, true], debit? <- [false, true] do
      wire =
        Enum.reduce(
          [
            {"quoteId", quote?, @quote_id},
            {"incomingPayment", incoming?, @incoming_id},
            {"debitAmount", debit?, @amount}
          ],
          %{"walletAddress" => @wallet},
          fn
            {name, true, value}, wire -> Map.put(wire, name, value)
            {_name, false, _value}, wire -> wire
          end
        )

      if {quote?, incoming?, debit?} in [{true, false, false}, {false, true, true}] do
        assert {:ok, _request} = CreateOutgoingPayment.from_map(wire)
      else
        assert {:error, %Error{validation_errors: [%{field: :create_outgoing_payment}]}} =
                 CreateOutgoingPayment.from_map(wire)
      end
    end

    for wire <- [
          Map.put(@quote, "incomingPayment", nil),
          Map.put(@quote, "debitAmount", nil),
          Map.put(@incoming, "quoteId", nil),
          %{
            "walletAddress" => @wallet,
            "quoteId" => nil,
            "incomingPayment" => nil,
            "debitAmount" => nil
          }
        ] do
      assert {:error, %Error{validation_errors: [%{field: :create_outgoing_payment}]}} =
               CreateOutgoingPayment.from_map(wire)
    end
  end

  test "rejects explicit null references, debit amounts and metadata rather than treating them as omitted" do
    for {wire, name, field} <- [
          {@quote, "quoteId", :quote_id},
          {@incoming, "incomingPayment", :incoming_payment},
          {@incoming, "debitAmount", :debit_amount},
          {@quote, "metadata", :metadata},
          {@incoming, "metadata", :metadata}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               CreateOutgoingPayment.from_map(Map.put(wire, name, nil))
    end
  end

  test "preserves absolute URI data spelling without receiver path or network-target policies" do
    for {wire, name} <- [{@quote, "quoteId"}, {@incoming, "incomingPayment"}],
        uri <- [
          "urn:example:reference",
          "https://Resource.Example.COM:8443/opaque%2Fid?part=1#state",
          "http://localhost:3000/tenant/opaque-resource",
          "ftp://resources.example.com:2121/reference",
          "HTTPS://resources.example.com/opaque"
        ] do
      wire = wire |> Map.put(name, uri) |> Map.put("walletAddress", "urn:example:wallet")
      assert {:ok, request} = CreateOutgoingPayment.from_map(wire)
      assert :ok = CreateOutgoingPayment.validate(request)
      assert CreateOutgoingPayment.to_map(request) == wire
    end
  end

  test "validates every URI field and rejects pointers, relative data and malformed escapes safely" do
    for {wire, name, field} <- [
          {@quote, "walletAddress", :wallet_address},
          {@incoming, "walletAddress", :wallet_address},
          {@quote, "quoteId", :quote_id},
          {@incoming, "incomingPayment", :incoming_payment}
        ],
        value <- [
          "",
          "$wallet.example.com/alice",
          "/private-relative",
          "https://",
          "https://x/%xx",
          false,
          1,
          [],
          %{},
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CreateOutgoingPayment.from_map(Map.put(wire, name, value))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves empty and nested JSON metadata in both forms while rejecting non-object or non-JSON values" do
    for wire <- [@quote, @incoming],
        metadata <- [%{}, %{"private-note" => [nil, true, 1, %{"☕" => "description"}]}] do
      wire = Map.put(wire, "metadata", metadata)
      assert {:ok, request} = CreateOutgoingPayment.from_map(wire)
      assert :ok = CreateOutgoingPayment.validate(request)
      assert Jason.decode!(Jason.encode!(request)) == wire
    end

    for wire <- [@quote, @incoming],
        metadata <- [
          [],
          false,
          "private-metadata",
          %{private_key: "private-value"},
          %{"private-key" => self()},
          %{"private-key" => <<255>>},
          %URI{}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :metadata}]} = error} =
               CreateOutgoingPayment.from_map(Map.put(wire, "metadata", metadata))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "retains uint64 decimal spellings and nested amount extensions without wallet lookups or asset rules" do
    for value <- ["0", "0000", "18446744073709551615"] do
      amount =
        Map.merge(@amount, %{
          "value" => value,
          "assetCode" => "",
          "assetScale" => 255,
          "private-extra" => [nil, %{"☕" => false}]
        })

      wire = Map.put(@incoming, "debitAmount", amount)
      assert {:ok, request} = CreateOutgoingPayment.from_map(wire)
      assert :ok = CreateOutgoingPayment.validate(request)
      assert Jason.decode!(Jason.encode!(request)) == wire
    end
  end

  test "prefixes safe amount errors for malformed values, bounds, assets and extension data" do
    for {amount, field} <- [
          {"private-amount", :debit_amount},
          {false, :debit_amount},
          {[], :debit_amount},
          {%{@amount | "value" => "private-value"}, "debit_amount.value"},
          {%{@amount | "value" => "18446744073709551616"}, "debit_amount.value"},
          {%{@amount | "value" => 12}, "debit_amount.value"},
          {%{@amount | "assetCode" => <<255>>}, "debit_amount.asset_code"},
          {%{@amount | "assetScale" => 256}, "debit_amount.asset_scale"},
          {Map.put(@amount, "private-extra", self()), "debit_amount.extensions"}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               CreateOutgoingPayment.from_map(Map.put(@incoming, "debitAmount", amount))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "rejects unknown, response-only and alias fields and malformed roots without leaking data" do
    for wire <- [@quote, @incoming],
        name <- [
          "id",
          "receiver",
          "receiveAmount",
          "sentAmount",
          "grantSpentDebitAmount",
          "failed",
          "createdAt",
          "extensions",
          "private-field",
          "wallet_address",
          "quote_id",
          "incoming_payment",
          "debit_amount",
          :metadata
        ] do
      assert {:error, %Error{validation_errors: [%{field: :create_outgoing_payment}]} = error} =
               CreateOutgoingPayment.from_map(Map.put(wire, name, "private-value"))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    {:ok, typed} = CreateOutgoingPayment.from_map(@quote)

    for root <- [nil, false, 1, "private-root", [], %URI{}, typed] do
      assert {:error, %Error{validation_errors: [%{field: :create_outgoing_payment}]} = error} =
               CreateOutgoingPayment.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates modified variants, references, metadata and nested typed debit amounts" do
    {:ok, quote} = CreateOutgoingPayment.from_map(@quote)
    {:ok, incoming} = CreateOutgoingPayment.from_map(@incoming)

    for {invalid, field} <- [
          {%{quote | quote_id: nil}, :create_outgoing_payment},
          {%{incoming | incoming_payment: nil}, :create_outgoing_payment},
          {%{incoming | debit_amount: nil}, :create_outgoing_payment},
          {%{incoming | quote_id: @quote_id}, :create_outgoing_payment},
          {%{quote | debit_amount: incoming.debit_amount}, :create_outgoing_payment},
          {%{quote | incoming_payment: @incoming_id}, :create_outgoing_payment},
          {%{quote | wallet_address: nil}, :wallet_address},
          {%{quote | quote_id: "private-relative"}, :quote_id},
          {%{incoming | incoming_payment: "private-relative"}, :incoming_payment},
          {%{quote | metadata: []}, :metadata},
          {%{incoming | debit_amount: @amount}, :debit_amount},
          {%{incoming | debit_amount: %{incoming.debit_amount | value: "private-value"}},
           "debit_amount.value"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CreateOutgoingPayment.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    assert :ok = CreateOutgoingPayment.validate(%{quote | metadata: nil})
    assert :ok = CreateOutgoingPayment.validate(%{incoming | quote_id: nil, metadata: nil})
  end

  test "inspection hides every payload field while explicit map and JSON exports include them without validation" do
    for wire <- [@quote, @incoming] do
      wire =
        wire
        |> Map.put("walletAddress", "urn:example:private-wallet")
        |> Map.put("metadata", %{"private-metadata" => "secret"})

      {:ok, request} = CreateOutgoingPayment.from_map(wire)
      refute inspect(request) =~ "private-"
      refute inspect(request) =~ @quote_id
      refute inspect(request) =~ @incoming_id
      refute inspect(request) =~ "2500"
      assert CreateOutgoingPayment.to_map(request) == wire
      assert Jason.decode!(Jason.encode!(request)) == wire

      assert CreateOutgoingPayment.to_map(%{request | wallet_address: "unchecked"})[
               "walletAddress"
             ] == "unchecked"
    end
  end
end
