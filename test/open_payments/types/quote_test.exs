defmodule OpenPayments.Types.QuoteTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, Quote}

  @debit %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @wire %{
    "id" => "https://resource.example.com/quotes/quote-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "debitAmount" => @debit,
    "receiveAmount" => @receive,
    "method" => "ilp",
    "createdAt" => "2026-11-18T09:20:50Z"
  }

  test "matches the pinned strict quote fields, required amounts and distinct timestamp declarations" do
    {:ok, schema} = Specification.fetch_schema(:resource, "quote")
    assert schema["type"] == "object" and schema["additionalProperties"] == false

    assert Enum.sort(schema["required"]) ==
             ~w(createdAt debitAmount id method receiveAmount receiver walletAddress)

    assert Enum.sort(Map.keys(schema["properties"])) ==
             ~w(createdAt debitAmount expiresAt id method receiveAmount receiver walletAddress)

    assert schema["properties"]["createdAt"]["format"] == "date-time"
    assert schema["properties"]["expiresAt"]["type"] == "string"
    refute Map.has_key?(schema["properties"]["expiresAt"], "format")
    assert schema["properties"]["expiresAt"]["readOnly"] == true
    for name <- ~w(id walletAddress), do: assert(schema["properties"][name]["format"] == "uri")

    for name <- ~w(debitAmount receiveAmount),
        do: assert(schema["properties"][name]["$ref"] == "#/components/schemas/amount")

    assert schema["properties"]["receiver"]["$ref"] == "#/components/schemas/receiver"
    {:ok, receiver} = Specification.fetch_schema(:resource, "receiver")

    assert receiver["format"] == "uri" and
             receiver["pattern"] == "^(https|http)://(.+)/incoming-payments/(.+)$"

    {:ok, method} = Specification.fetch_schema(:resource, "payment-method")
    assert method["enum"] == ["ilp"]
  end

  test "round trips every official GET and create response example without repair" do
    document = Specification.document(:resource)

    for {path, method, status} <- [{"/quotes/{id}", "get", "200"}, {"/quotes", "post", "201"}] do
      content =
        document["paths"][path][method]["responses"][status]["content"]["application/json"]

      assert content["schema"] == %{"$ref" => "#/components/schemas/quote"}
      assert map_size(content["examples"]) > 0

      for {_name, %{"value" => wire}} <- content["examples"] do
        assert {:ok, %Quote{debit_amount: %Amount{}, receive_amount: %Amount{}} = quote} =
                 Quote.from_map(wire)

        assert :ok = Quote.validate(quote)
        assert Quote.to_map(quote) == wire
        assert Jason.decode!(Jason.encode!(quote)) == wire
      end
    end
  end

  test "explicitly rejects inconsistent standalone examples instead of dropping sentAmount or defaulting receiveAmount" do
    {:ok, schema} = Specification.fetch_schema(:resource, "quote")
    assert length(schema["examples"]) == 2

    for wire <- schema["examples"] do
      assert Map.has_key?(wire, "sentAmount")
      assert {:error, %Error{kind: :validation}} = Quote.from_map(wire)
    end

    [complete, incomplete] = schema["examples"]
    assert {:error, %Error{validation_errors: [%{field: :quote}]}} = Quote.from_map(complete)
    refute Map.has_key?(incomplete, "receiveAmount")

    assert {:error, %Error{validation_errors: [%{field: :receive_amount}]}} =
             Quote.from_map(incomplete)
  end

  test "requires every declared response field without defaults and rejects explicit null" do
    for {name, field} <- [
          {"id", :id},
          {"walletAddress", :wallet_address},
          {"receiver", :receiver},
          {"debitAmount", :debit_amount},
          {"receiveAmount", :receive_amount},
          {"method", :method},
          {"createdAt", :created_at}
        ],
        wire <- [Map.delete(@wire, name), Map.put(@wire, name, nil)] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               Quote.from_map(wire)
    end

    assert {:ok, quote} = Quote.from_map(@wire)
    assert quote.expires_at == nil
    assert Quote.to_map(quote) == @wire
  end

  test "preserves optional expiry as schema string data without imposing a timestamp format or clock" do
    for expiry <- [
          "",
          "private-expiry",
          "not-a-date",
          "2020-01-01T00:00:00Z",
          "2026-02-29T25:00:00Z",
          "☕\n"
        ] do
      wire = Map.put(@wire, "expiresAt", expiry)
      assert {:ok, quote} = Quote.from_map(wire)
      assert quote.expires_at == expiry
      assert :ok = Quote.validate(quote)
      assert Jason.decode!(Jason.encode!(quote)) == wire
    end

    for expiry <- [nil, false, 1, [], %{}, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :expires_at}]}} =
               Quote.from_map(Map.put(@wire, "expiresAt", expiry))
    end
  end

  test "validates RFC 3339 creation timestamps while preserving case, offsets and precision" do
    for created <- [
          "2020-01-01T00:00:00Z",
          "2024-02-29t09:20:50.123456789z",
          "1996-12-19T16:39:57-08:00",
          "1990-12-31T23:59:60Z",
          "2026-11-18T09:20:50-00:00"
        ] do
      wire = %{@wire | "createdAt" => created}
      assert {:ok, quote} = Quote.from_map(wire)
      assert Quote.to_map(quote) == wire
    end

    for created <- [
          "2026-02-29T00:00:00Z",
          "2026-11-18",
          "2026-11-18T24:00:00Z",
          "2026-11-18T09:20:50Z\n",
          false,
          1,
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: :created_at}]}} =
               Quote.from_map(%{@wire | "createdAt" => created})
    end
  end

  test "applies URI data formats and receiver pattern without discovery, HTTP-client policy or pointer conversion" do
    wire =
      Map.merge(@wire, %{
        "id" => "urn:example:quote",
        "walletAddress" => "https://Wallet.Example.COM:8443/alice%2Fid?part=1#state",
        "receiver" => "http://localhost:3000/tenant/incoming-payments/payment%2Fid?part=1#state"
      })

    assert {:ok, quote} = Quote.from_map(wire)
    assert Quote.to_map(quote) == wire

    for {name, field, value} <- [
          {"id", :id, "/quotes/id"},
          {"walletAddress", :wallet_address, "$wallet.example.com/alice"},
          {"walletAddress", :wallet_address, "https://wallet.example.com/%xx"},
          {"receiver", :receiver, "https://receiver.example.com/wallet"},
          {"receiver", :receiver, "https://receiver.example.com/incoming-payments/"},
          {"receiver", :receiver, "HTTPS://receiver.example.com/incoming-payments/id"},
          {"receiver", :receiver, "urn:example:incoming-payment"},
          {"receiver", :receiver, "private-receiver"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               Quote.from_map(Map.put(@wire, name, value))

      refute inspect(Map.from_struct(error)) =~ "private-receiver"
    end
  end

  test "decodes and validates both amounts with prefixed errors and preserved nested extensions" do
    for value <- ["0", "0001", "18446744073709551615"] do
      wire =
        Map.merge(@wire, %{
          "debitAmount" => Map.put(%{@debit | "value" => value}, "custom", [true, nil]),
          "receiveAmount" => %{@receive | "value" => value}
        })

      assert {:ok, quote} = Quote.from_map(wire)
      assert quote.debit_amount.value == value and quote.receive_amount.value == value
      assert quote.debit_amount.extensions == %{"custom" => [true, nil]}
      assert :ok = Quote.validate(quote)
      assert Jason.decode!(Jason.encode!(quote)) == wire
    end

    for {name, parent} <- [{"debitAmount", "debit_amount"}, {"receiveAmount", "receive_amount"}],
        {amount, suffix} <- [
          {%{@debit | "value" => "private-amount"}, "value"},
          {%{@debit | "value" => "18446744073709551616"}, "value"},
          {%{@debit | "assetScale" => 256}, "asset_scale"}
        ] do
      field = parent <> "." <> suffix

      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               Quote.from_map(Map.put(@wire, name, amount))

      refute inspect(Map.from_struct(error)) =~ "private-amount"
    end
  end

  test "supports only the pinned ilp method without coercing atoms or choosing a default" do
    for method <- ["ILP", "stream", "", :ilp, false, 1, []] do
      assert {:error, %Error{validation_errors: [%{field: :method}]}} =
               Quote.from_map(%{@wire | "method" => method})
    end
  end

  test "rejects unknown/legacy/root alias fields and malformed roots without exposing names or values" do
    for name <- [
          "sentAmount",
          "metadata",
          "extensions",
          "private-field",
          "wallet_address",
          "debit_amount",
          "receive_amount",
          "created_at",
          "expires_at",
          :expiresAt
        ] do
      assert {:error, %Error{validation_errors: [%{field: :quote}]} = error} =
               Quote.from_map(Map.put(@wire, name, "private-value"))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    {:ok, quote} = Quote.from_map(@wire)

    for root <- [nil, false, 1, "private-root", [], %URI{}, quote] do
      assert {:error, %Error{validation_errors: [%{field: :quote}]} = error} =
               Quote.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-root"
    end
  end

  test "does not infer exchange-rate, amount-order, positivity, asset matching or time consistency rules" do
    wire =
      Map.merge(@wire, %{
        "debitAmount" => %{@debit | "value" => "0", "assetCode" => "", "assetScale" => 0},
        "receiveAmount" => %{@receive | "value" => "999999", "assetScale" => 255},
        "expiresAt" => "2020-01-01T00:00:00Z"
      })

    assert {:ok, quote} = Quote.from_map(wire)
    assert :ok = Quote.validate(quote)
    assert Quote.to_map(quote) == wire
  end

  test "revalidates manually modified fields and typed nested amounts with safe paths" do
    {:ok, quote} = Quote.from_map(@wire)

    for {invalid, field} <- [
          {%{quote | id: "private-relative"}, :id},
          {%{quote | wallet_address: nil}, :wallet_address},
          {%{quote | receiver: "private-relative"}, :receiver},
          {%{quote | method: :ilp}, :method},
          {%{quote | created_at: "private-date"}, :created_at},
          {%{quote | expires_at: false}, :expires_at},
          {%{quote | debit_amount: @debit}, :debit_amount},
          {%{quote | receive_amount: nil}, :receive_amount},
          {%{quote | receive_amount: %{quote.receive_amount | asset_scale: 256}},
           "receive_amount.asset_scale"},
          {%{quote | debit_amount: %{quote.debit_amount | value: "private-amount"}},
           "debit_amount.value"}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               Quote.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    assert :ok = Quote.validate(%{quote | expires_at: nil})
    assert :ok = Quote.validate(%{quote | expires_at: "not-a-date"})
  end

  test "inspection hides wallet/receiver/amount/expiry while explicit exports use protocol names without validation" do
    wire =
      Map.merge(@wire, %{
        "walletAddress" => "https://wallet.example.com/private-wallet",
        "receiver" => "https://receiver.example.com/incoming-payments/private-receiver",
        "expiresAt" => "private-expiry"
      })

    {:ok, quote} = Quote.from_map(wire)
    refute inspect(quote) =~ "private-"
    refute inspect(quote) =~ "2500"
    assert inspect(quote) =~ quote.id
    assert Quote.to_map(quote) == wire
    assert Jason.decode!(Jason.encode!(quote)) == wire
    invalid = %{quote | method: "private-method"}
    assert {:error, _} = Quote.validate(invalid)
    assert Quote.to_map(invalid)["method"] == "private-method"
    assert Jason.decode!(Jason.encode!(invalid))["method"] == "private-method"
  end
end
