defmodule OpenPayments.Types.CreateQuoteTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, CreateQuote}

  @base %{
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "method" => "ilp"
  }
  @amount %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}

  test "matches all pinned closed oneOf branches and their exact required fields" do
    {:ok, union} = Specification.fetch_schema(:resource, "create-quote-request")

    names =
      ~w(create-quote-request-by-receiver create-quote-request-with-receive-amount create-quote-request-with-debit-amount)

    assert union["oneOf"] == Enum.map(names, &%{"$ref" => "#/components/schemas/" <> &1})

    for {name, amount} <- Enum.zip(names, [nil, "receiveAmount", "debitAmount"]) do
      {:ok, schema} = Specification.fetch_schema(:resource, name)
      fields = ~w(walletAddress receiver method) ++ if(is_nil(amount), do: [], else: [amount])
      assert Enum.sort(schema["required"]) == Enum.sort(fields)
      assert Enum.sort(Map.keys(schema["properties"])) == Enum.sort(fields)
      assert schema["additionalProperties"] == false
      assert schema["properties"]["walletAddress"]["$ref"] == "#/components/schemas/walletAddress"
      assert schema["properties"]["receiver"]["$ref"] == "#/components/schemas/receiver"
      assert schema["properties"]["method"]["$ref"] == "#/components/schemas/payment-method"
      if amount, do: assert(schema["properties"][amount]["$ref"] == "#/components/schemas/amount")
    end

    {:ok, method} = Specification.fetch_schema(:resource, "payment-method")
    assert method["enum"] == ["ilp"]
  end

  test "round trips every official receiver-inferred, fixed-debit and fixed-receive example" do
    body = Specification.document(:resource)["paths"]["/quotes"]["post"]["requestBody"]
    assert body["required"] == true
    content = body["content"]["application/json"]
    assert content["schema"] == %{"$ref" => "#/components/schemas/create-quote-request"}
    assert map_size(content["examples"]) == 3

    variants =
      for {_name, %{"value" => wire}} <- content["examples"] do
        assert {:ok, %CreateQuote{} = request} = CreateQuote.from_map(wire)
        assert :ok = CreateQuote.validate(request)
        assert CreateQuote.to_map(request) == wire
        assert Jason.decode!(Jason.encode!(request)) == wire
        {is_struct(request.debit_amount, Amount), is_struct(request.receive_amount, Amount)}
      end

    assert Enum.sort(variants) == [{false, false}, {false, true}, {true, false}]
  end

  test "supports typed amount variants and omission without inferring or defaulting amounts" do
    {:ok, amount} = Amount.from_map(@amount)

    request = %CreateQuote{
      wallet_address: @base["walletAddress"],
      receiver: @base["receiver"],
      method: "ilp"
    }

    assert :ok = CreateQuote.validate(request)
    assert CreateQuote.to_map(request) == @base

    for {typed, wire} <- [
          {%{request | debit_amount: amount}, Map.put(@base, "debitAmount", @amount)},
          {%{request | receive_amount: amount}, Map.put(@base, "receiveAmount", @amount)}
        ] do
      assert :ok = CreateQuote.validate(typed)
      assert Jason.decode!(Jason.encode!(typed)) == wire
    end

    assert {:ok, decoded} = CreateQuote.from_map(@base)
    assert decoded.debit_amount == nil and decoded.receive_amount == nil
    assert CreateQuote.to_map(decoded) == @base
  end

  test "requires wallet, receiver and explicit method without supplying defaults" do
    for {name, field} <- [
          {"walletAddress", :wallet_address},
          {"receiver", :receiver},
          {"method", :method}
        ],
        wire <- [Map.delete(@base, name), Map.put(@base, name, nil)] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               CreateQuote.from_map(wire)
    end
  end

  test "validates wallet URI and incoming-payment receiver data while preserving spelling" do
    wire =
      Map.merge(@base, %{
        "walletAddress" => "urn:example:wallet",
        "receiver" => "http://localhost:3000/tenant/incoming-payments/payment%2Fid?part=1#state"
      })

    assert {:ok, request} = CreateQuote.from_map(wire)
    assert CreateQuote.to_map(request) == wire

    for {name, field, value} <- [
          {"walletAddress", :wallet_address, "$wallet.example.com/alice"},
          {"walletAddress", :wallet_address, "/alice"},
          {"walletAddress", :wallet_address, "https://wallet.example.com/%xx"},
          {"receiver", :receiver, "https://receiver.example.com/wallet"},
          {"receiver", :receiver, "https://receiver.example.com/incoming-payments/"},
          {"receiver", :receiver, "HTTPS://receiver.example.com/incoming-payments/id"},
          {"receiver", :receiver, "urn:example:payment"},
          {"receiver", :receiver, "private-receiver"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CreateQuote.from_map(Map.put(@base, name, value))

      refute inspect(Map.from_struct(error)) =~ "private-receiver"
    end
  end

  test "accepts only the pinned method string without atom or case coercion" do
    for method <- ["ILP", "stream", "", :ilp, false, 1, [], <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :method}]}} =
               CreateQuote.from_map(%{@base | "method" => method})
    end
  end

  test "rejects explicit null amounts and enforces branch exclusivity by field presence" do
    for {name, field} <- [{"debitAmount", :debit_amount}, {"receiveAmount", :receive_amount}] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               CreateQuote.from_map(Map.put(@base, name, nil))
    end

    for debit <- [nil, @amount], receive <- [nil, @amount] do
      wire = Map.merge(@base, %{"debitAmount" => debit, "receiveAmount" => receive})

      assert {:error, %Error{kind: :validation, validation_errors: [%{field: :create_quote}]}} =
               CreateQuote.from_map(wire)
    end
  end

  test "validates amount bounds for either variant and retains permitted nested JSON fields" do
    for name <- ~w(debitAmount receiveAmount), value <- ["0", "0001", "18446744073709551615"] do
      amount = Map.put(%{@amount | "value" => value}, "custom", %{"nested" => [true, nil]})
      wire = Map.put(@base, name, amount)
      assert {:ok, request} = CreateQuote.from_map(wire)
      assert :ok = CreateQuote.validate(request)
      assert Jason.decode!(Jason.encode!(request)) == wire
    end

    for {name, parent} <- [{"debitAmount", :debit_amount}, {"receiveAmount", :receive_amount}],
        {amount, suffix} <- [
          {"private-amount", nil},
          {%{@amount | "value" => "18446744073709551616"}, "value"},
          {%{@amount | "value" => "private-value"}, "value"},
          {%{@amount | "assetScale" => 256}, "asset_scale"}
        ] do
      field = if is_nil(suffix), do: parent, else: "#{parent}.#{suffix}"

      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CreateQuote.from_map(Map.put(@base, name, amount))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "rejects extra, response-only, metadata and alias fields and invalid roots safely" do
    for name <- [
          "id",
          "createdAt",
          "expiresAt",
          "sentAmount",
          "metadata",
          "extensions",
          "private-field",
          "wallet_address",
          "debit_amount",
          "receive_amount",
          :method
        ] do
      assert {:error, %Error{validation_errors: [%{field: :create_quote}]} = error} =
               CreateQuote.from_map(Map.put(@base, name, "private-value"))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    {:ok, typed} = CreateQuote.from_map(@base)

    for root <- [nil, false, 1, "private-root", [], %URI{}, typed] do
      assert {:error, %Error{validation_errors: [%{field: :create_quote}]} = error} =
               CreateQuote.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-root"
    end
  end

  test "keeps receiver inference, asset compatibility, positivity and payment calculations outside the codec" do
    for wire <- [
          @base,
          Map.put(@base, "debitAmount", %{
            @amount
            | "value" => "0",
              "assetCode" => "",
              "assetScale" => 0
          }),
          Map.put(@base, "receiveAmount", %{
            @amount
            | "value" => "0001",
              "assetCode" => "ANY",
              "assetScale" => 255
          })
        ] do
      assert {:ok, request} = CreateQuote.from_map(wire)
      assert :ok = CreateQuote.validate(request)
      assert CreateQuote.to_map(request) == wire
    end
  end

  test "revalidates modified typed fields, amount variant and nested values without retaining data" do
    {:ok, request} = CreateQuote.from_map(Map.put(@base, "debitAmount", @amount))

    for {invalid, field} <- [
          {%{request | wallet_address: "private-relative"}, :wallet_address},
          {%{request | receiver: "private-relative"}, :receiver},
          {%{request | method: :ilp}, :method},
          {%{request | receive_amount: request.debit_amount}, :create_quote},
          {%{request | debit_amount: @amount}, :debit_amount},
          {%{request | debit_amount: nil, receive_amount: @amount}, :receive_amount},
          {%{request | debit_amount: %{request.debit_amount | value: "private-amount"}},
           "debit_amount.value"},
          {%{
             request
             | debit_amount: nil,
               receive_amount: %{request.debit_amount | asset_scale: 256}
           }, "receive_amount.asset_scale"}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               CreateQuote.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    assert :ok = CreateQuote.validate(%{request | debit_amount: nil, receive_amount: nil})
  end

  test "inspection omits wallet, receiver and amount while explicit exports include protocol data without validation" do
    wire =
      Map.merge(@base, %{
        "walletAddress" => "https://wallet.example.com/private-wallet",
        "receiver" => "https://receiver.example.com/incoming-payments/private-receiver",
        "receiveAmount" => @amount
      })

    {:ok, request} = CreateQuote.from_map(wire)
    refute inspect(request) =~ "private-"
    refute inspect(request) =~ "2500"
    assert inspect(request) =~ "method: \"ilp\""
    assert CreateQuote.to_map(request) == wire
    assert Jason.decode!(Jason.encode!(request)) == wire
    invalid = %{request | debit_amount: request.receive_amount}
    assert {:error, _} = CreateQuote.validate(invalid)
    assert Map.has_key?(CreateQuote.to_map(invalid), "debitAmount")
    assert Jason.decode!(Jason.encode!(invalid))["receiveAmount"] == @amount
  end
end
