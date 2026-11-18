defmodule OpenPayments.Types.CreateIncomingPaymentTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, CreateIncomingPayment}

  @amount %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @minimal %{"walletAddress" => "https://wallet.example.com/alice"}

  test "matches the pinned strict request schema and required wallet URI reference" do
    {:ok, schema} = Specification.fetch_schema(:resource, "create-incoming-payment-request")
    assert schema["required"] == ["walletAddress"]
    assert schema["additionalProperties"] == false

    assert Map.keys(schema["properties"]) |> Enum.sort() ==
             ~w(expiresAt incomingAmount metadata walletAddress)

    assert schema["properties"]["walletAddress"]["$ref"] == "#/components/schemas/walletAddress"
    assert schema["properties"]["incomingAmount"]["$ref"] == "#/components/schemas/amount"
    assert schema["properties"]["expiresAt"]["format"] == "date-time"
    assert schema["properties"]["expiresAt"]["writeOnly"] == true
    assert schema["properties"]["metadata"]["type"] == "object"
    assert schema["properties"]["metadata"]["additionalProperties"] == true
    {:ok, wallet} = Specification.fetch_schema(:resource, "walletAddress")
    assert wallet["format"] == "uri"
  end

  test "round trips every official incoming-payment create request example with a typed amount" do
    body = Specification.document(:resource)["paths"]["/incoming-payments"]["post"]["requestBody"]
    assert body["required"] == true

    assert body["content"]["application/json"]["schema"]["$ref"] ==
             "#/components/schemas/create-incoming-payment-request"

    examples = body["content"]["application/json"]["examples"]
    assert map_size(examples) > 0

    for {_name, %{"value" => wire}} <- examples do
      assert {:ok, %CreateIncomingPayment{incoming_amount: %Amount{}} = request} =
               CreateIncomingPayment.from_map(wire)

      assert :ok = CreateIncomingPayment.validate(request)
      assert CreateIncomingPayment.to_map(request) == wire
      assert Jason.decode!(Jason.encode!(request)) == wire
    end
  end

  test "accepts only the required wallet field and omits absent optional values" do
    assert {:ok, request} = CreateIncomingPayment.from_map(@minimal)

    assert request.incoming_amount == nil and request.expires_at == nil and
             request.metadata == nil

    assert :ok = CreateIncomingPayment.validate(request)
    assert CreateIncomingPayment.to_map(request) == @minimal

    assert Jason.decode!(
             Jason.encode!(%CreateIncomingPayment{wallet_address: @minimal["walletAddress"]})
           ) == @minimal
  end

  test "requires a schema-valid wallet URI without payment-pointer conversion or network URL policy" do
    for wire <- [
          %{},
          %{"walletAddress" => nil},
          %{"walletAddress" => ""},
          %{"walletAddress" => false},
          %{"walletAddress" => "/alice"},
          %{"walletAddress" => "$wallet.example.com/alice"},
          %{"walletAddress" => "https://wallet.example.com/%xx"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :wallet_address}]}} =
               CreateIncomingPayment.from_map(wire)
    end

    for wallet <- [
          "https://Wallet.Example.COM:8443/alice%2Fid?part=1#state",
          "http://localhost:3000/alice",
          "urn:example:wallet"
        ] do
      wire = %{"walletAddress" => wallet}
      assert {:ok, request} = CreateIncomingPayment.from_map(wire)
      assert CreateIncomingPayment.to_map(request) == wire
    end
  end

  test "rejects explicit nulls for all optional fields" do
    for {wire_field, field} <- [
          {"incomingAmount", :incoming_amount},
          {"expiresAt", :expires_at},
          {"metadata", :metadata}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               CreateIncomingPayment.from_map(Map.put(@minimal, wire_field, nil))
    end
  end

  test "validates nested amount bounds and preserves zero, decimal spelling and permitted amount extensions" do
    for value <- ["0", "0001", "18446744073709551615"] do
      wire =
        Map.put(
          @minimal,
          "incomingAmount",
          Map.put(%{@amount | "value" => value}, "custom", [nil, true])
        )

      assert {:ok, request} = CreateIncomingPayment.from_map(wire)
      assert request.incoming_amount.value == value
      assert Jason.decode!(Jason.encode!(request)) == wire
    end

    for {amount, field} <- [
          {%{@amount | "value" => "18446744073709551616"}, "incoming_amount.value"},
          {%{@amount | "assetScale" => 256}, "incoming_amount.asset_scale"},
          {"private-amount", :incoming_amount}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CreateIncomingPayment.from_map(Map.put(@minimal, "incomingAmount", amount))

      refute inspect(Map.from_struct(error)) =~ "private-amount"
    end
  end

  test "validates RFC 3339 expiry while preserving past dates, offsets and fractional precision" do
    for timestamp <- [
          "2020-01-01T00:00:00Z",
          "1996-12-19T16:39:57-08:00",
          "1990-12-31T23:59:60Z",
          "2024-02-29t09:20:50.123456789z",
          "2026-11-18T09:20:50-00:00"
        ] do
      wire = Map.put(@minimal, "expiresAt", timestamp)
      assert {:ok, request} = CreateIncomingPayment.from_map(wire)
      assert CreateIncomingPayment.to_map(request) == wire
    end

    for timestamp <- [
          false,
          1,
          "2026-11-18",
          "2026-02-29T00:00:00Z",
          "2026-11-18T24:00:00Z",
          "2026-11-18T09:20:50Z\n",
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: :expires_at}]}} =
               CreateIncomingPayment.from_map(Map.put(@minimal, "expiresAt", timestamp))
    end
  end

  test "permits empty and nested JSON metadata without reserving request field names inside metadata" do
    for metadata <- [
          %{},
          %{
            "walletAddress" => "metadata-only",
            "id" => "metadata-id",
            "values" => [nil, true, 1, %{"externalRef" => "invoice-1"}]
          }
        ] do
      wire = Map.put(@minimal, "metadata", metadata)
      assert {:ok, request} = CreateIncomingPayment.from_map(wire)
      assert request.metadata == metadata
      assert Jason.decode!(Jason.encode!(request)) == wire
    end

    for metadata <- [
          [],
          "private-note",
          1,
          false,
          %URI{},
          %{custom: true},
          %{"custom" => self()},
          %{"custom" => <<255>>}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :metadata}]} = error} =
               CreateIncomingPayment.from_map(Map.put(@minimal, "metadata", metadata))

      refute inspect(Map.from_struct(error)) =~ "private-note"
    end
  end

  test "rejects extra, response-only and alias fields rather than retaining or silently dropping them" do
    for field <-
          ~w(id completed receivedAmount createdAt methods authServer incoming_amount wallet_address expires_at extensions custom) do
      assert {:error, %Error{validation_errors: [%{field: :create_incoming_payment}]}} =
               CreateIncomingPayment.from_map(Map.put(@minimal, field, "private-extra"))
    end

    assert {:error, %Error{validation_errors: [%{field: :create_incoming_payment}]}} =
             CreateIncomingPayment.from_map(Map.put(@minimal, :custom, true))
  end

  test "revalidates manually changed structs and nested typed amounts while nil optionals mean omission" do
    {:ok, request} =
      CreateIncomingPayment.from_map(
        Map.merge(@minimal, %{
          "incomingAmount" => @amount,
          "expiresAt" => "2026-11-18T09:20:50Z",
          "metadata" => %{}
        })
      )

    for {changed, field} <- [
          {%{request | wallet_address: "relative"}, :wallet_address},
          {%{request | incoming_amount: @amount}, :incoming_amount},
          {%{request | incoming_amount: %{request.incoming_amount | value: "-1"}},
           "incoming_amount.value"},
          {%{request | expires_at: false}, :expires_at},
          {%{request | metadata: []}, :metadata},
          {%{request | metadata: %{custom: true}}, :metadata},
          {%{request | metadata: %{"custom" => self()}}, :metadata}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               CreateIncomingPayment.validate(changed)
    end

    changed = %{request | incoming_amount: nil, expires_at: nil, metadata: nil}
    assert :ok = CreateIncomingPayment.validate(changed)
    assert CreateIncomingPayment.to_map(changed) == @minimal

    assert CreateIncomingPayment.to_map(%{changed | wallet_address: "relative"}) == %{
             "walletAddress" => "relative"
           }
  end

  test "rejects non-objects and retains no rejected values or unknown field names in errors" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :create_incoming_payment}]} = error} =
               CreateIncomingPayment.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    assert {:error, error} =
             CreateIncomingPayment.from_map(
               Map.put(@minimal, "private-field-name", "private-value")
             )

    refute inspect(Map.from_struct(error)) =~ "private-"
  end

  test "hides wallet, amount and metadata in inspection while explicit exports preserve protocol fields" do
    wire = %{
      "walletAddress" => "https://wallet.example.com/private-wallet",
      "incomingAmount" => Map.put(@amount, "custom", "private-amount-extra"),
      "metadata" => %{"description" => "private-note"},
      "expiresAt" => "2026-11-18T09:20:50Z"
    }

    {:ok, request} = CreateIncomingPayment.from_map(wire)
    refute inspect(request) =~ "private-"
    assert CreateIncomingPayment.to_map(request) == wire
    assert Jason.decode!(Jason.encode!(request)) == wire
  end
end
