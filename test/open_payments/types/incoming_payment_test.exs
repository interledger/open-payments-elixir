defmodule OpenPayments.Types.IncomingPaymentTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, IncomingPayment}

  @amount %{"value" => "250", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => "https://wallet.example.com/tenant/incoming-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "completed" => false,
    "receivedAmount" => @amount,
    "createdAt" => "2026-11-18T09:20:50.52Z"
  }

  test "matches the pinned detailed response composition, required fields and optional metadata" do
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment")

    assert schema["allOf"] == [
             %{"$ref" => "#/components/schemas/incoming-payment-base-with-details"}
           ]

    {:ok, details} = Specification.fetch_schema(:resource, "incoming-payment-base-with-details")
    assert hd(details["allOf"])["$ref"] == "#/components/schemas/incoming-payment-base"
    fields = Enum.at(details["allOf"], 1)
    assert fields["required"] == ["walletAddress"]
    assert fields["properties"]["walletAddress"]["format"] == "uri"
    assert fields["properties"]["metadata"]["type"] == "object"
    assert fields["properties"]["metadata"]["additionalProperties"] == true
    assert Map.get(fields, "additionalProperties", true) == true
    {:ok, base} = Specification.fetch_schema(:resource, "incoming-payment-base")
    assert base["required"] == ~w(id completed receivedAmount createdAt)
    assert base["properties"]["completed"]["default"] == false

    for field <- ~w(createdAt expiresAt),
        do: assert(base["properties"][field]["format"] == "date-time")
  end

  test "round trips valid standalone and all list/completion examples with typed amounts" do
    document = Specification.document(:resource)
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment")
    standalone = Enum.filter(schema["examples"], &Map.has_key?(&1, "completed"))

    complete =
      document["paths"]["/incoming-payments/{id}/complete"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    pages =
      document["paths"]["/incoming-payments"]["get"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    completion_items = for {_name, %{"value" => wire}} <- complete, do: wire
    list_items = for {_name, %{"value" => page}} <- pages, item <- page["result"], do: item
    assert standalone != [] and completion_items != [] and list_items != []

    for wire <- standalone ++ completion_items ++ list_items do
      assert {:ok, %IncomingPayment{received_amount: %Amount{}} = payment} =
               IncomingPayment.from_map(wire)

      assert :ok = IncomingPayment.validate(payment)
      assert IncomingPayment.to_map(payment) == wire
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "rejects the inconsistent bundled example missing completed instead of applying the default" do
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment")
    missing = Enum.reject(schema["examples"], &Map.has_key?(&1, "completed"))
    assert length(missing) == 1

    for wire <- missing do
      assert {:error, %Error{validation_errors: [%{field: :completed}]}} =
               IncomingPayment.from_map(wire)
    end
  end

  test "requires base details and rejects explicit nulls without coercion" do
    for {wire_field, field} <- [
          {"id", :id},
          {"walletAddress", :wallet_address},
          {"completed", :completed},
          {"receivedAmount", :received_amount},
          {"createdAt", :created_at}
        ],
        wire <- [Map.delete(@payment, wire_field), Map.put(@payment, wire_field, nil)] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               IncomingPayment.from_map(wire)
    end
  end

  test "distinguishes omitted optional data from explicit null and retains empty metadata" do
    assert {:ok, payment} = IncomingPayment.from_map(@payment)

    assert payment.incoming_amount == nil and payment.expires_at == nil and
             payment.metadata == nil

    assert IncomingPayment.to_map(payment) == @payment

    for {wire_field, field} <- [
          {"incomingAmount", :incoming_amount},
          {"expiresAt", :expires_at},
          {"metadata", :metadata}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPayment.from_map(Map.put(@payment, wire_field, nil))
    end

    wire = Map.put(@payment, "metadata", %{})
    assert {:ok, payment} = IncomingPayment.from_map(wire)
    assert payment.metadata == %{}
    assert IncomingPayment.to_map(payment) == wire
  end

  test "validates boolean and URI formats while preserving response URI data policies" do
    for {wire_field, field, values} <- [
          {"completed", :completed, [0, "false", []]},
          {"id", :id, ["", "/relative", "$wallet.example.com", "https://", 1]},
          {"walletAddress", :wallet_address,
           ["", "/relative", "$wallet.example.com", "https://wallet.example.com/%xx", false]}
        ],
        value <- values do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPayment.from_map(Map.put(@payment, wire_field, value))
    end

    wire =
      Map.merge(@payment, %{
        "id" => "http://localhost:3000/tenant/opaque?part=1#state",
        "walletAddress" => "https://Wallet.Example.COM:8443/alice%2Fid?part=1#state"
      })

    assert {:ok, payment} = IncomingPayment.from_map(wire)
    assert IncomingPayment.to_map(payment) == wire
  end

  test "retains RFC 3339 spelling and precision without chronological or current-time comparisons" do
    for timestamp <- [
          "1985-04-12T23:20:50.52Z",
          "1996-12-19T16:39:57-08:00",
          "1990-12-31T23:59:60Z",
          "2024-02-29t09:20:50.123456789z",
          "2026-11-18T09:20:50-00:00"
        ] do
      wire = Map.merge(@payment, %{"createdAt" => timestamp, "expiresAt" => timestamp})
      assert {:ok, payment} = IncomingPayment.from_map(wire)
      assert IncomingPayment.to_map(payment) == wire
    end

    for timestamp <- [
          "2026-11-18",
          "2026-02-29T09:20:50Z",
          "2026-11-18T24:00:00Z",
          "2026-11-18T09:20:50",
          "2026-11-18T09:20:50Z\n",
          <<255>>
        ],
        {wire_field, field} <- [{"createdAt", :created_at}, {"expiresAt", :expires_at}] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPayment.from_map(Map.put(@payment, wire_field, timestamp))
    end

    wire = Map.put(@payment, "expiresAt", "2020-01-01T00:00:00Z")
    assert {:ok, payment} = IncomingPayment.from_map(wire)
    assert IncomingPayment.to_map(payment) == wire
  end

  test "validates nested amount bounds and preserves spelling/extensions without comparing assets" do
    for {wire_field, field} <- [
          {"receivedAmount", "received_amount.value"},
          {"incomingAmount", "incoming_amount.value"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPayment.from_map(
                 Map.put(@payment, wire_field, %{@amount | "value" => "18446744073709551616"})
               )
    end

    wire =
      @payment
      |> Map.put("receivedAmount", Map.put(@amount, "custom", [nil, true]))
      |> Map.put("incomingAmount", %{
        @amount
        | "value" => "0001",
          "assetCode" => "EUR",
          "assetScale" => 3
      })

    assert {:ok, payment} = IncomingPayment.from_map(wire)
    assert payment.incoming_amount.value == "0001"
    assert IncomingPayment.to_map(payment) == wire
  end

  test "preserves arbitrary JSON object metadata but rejects scalars, arrays, structs and non-JSON data" do
    metadata = %{
      "id" => "metadata-id",
      "walletAddress" => "metadata-only",
      "values" => [nil, true, 123, %{"description" => "private-note"}]
    }

    wire = Map.put(@payment, "metadata", metadata)
    assert {:ok, payment} = IncomingPayment.from_map(wire)
    assert payment.metadata == metadata
    assert Jason.decode!(Jason.encode!(payment)) == wire

    for metadata <- [[], "private-note", 1, false, %URI{}, %{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :metadata}]} = error} =
               IncomingPayment.from_map(Map.put(@payment, "metadata", metadata))

      refute inspect(Map.from_struct(error)) =~ "private-note"
    end
  end

  test "preserves standalone schema extensions including uninterpreted methods and rejects bad JSON" do
    wire =
      Map.merge(@payment, %{
        "custom" => %{"values" => [nil, true]},
        "methods" => [%{"custom-method" => "private-extension"}],
        "authServer" => "https://auth.example.com"
      })

    assert {:ok, payment} = IncomingPayment.from_map(wire)
    assert payment.extensions == Map.take(wire, ~w(custom methods authServer))
    assert Jason.decode!(Jason.encode!(payment)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               IncomingPayment.from_map(Map.merge(@payment, extra))
    end
  end

  test "revalidates manually changed typed amounts, fields and JSON objects" do
    {:ok, payment} =
      IncomingPayment.from_map(
        Map.merge(@payment, %{
          "incomingAmount" => @amount,
          "expiresAt" => "2026-11-18T09:20:50Z",
          "metadata" => %{}
        })
      )

    for {changed, field} <- [
          {%{payment | id: "relative"}, :id},
          {%{payment | wallet_address: "relative"}, :wallet_address},
          {%{payment | completed: nil}, :completed},
          {%{payment | created_at: nil}, :created_at},
          {%{payment | expires_at: false}, :expires_at},
          {%{payment | metadata: []}, :metadata},
          {%{payment | received_amount: @amount}, :received_amount},
          {%{payment | received_amount: %{payment.received_amount | asset_scale: 256}},
           "received_amount.asset_scale"},
          {%{payment | incoming_amount: @amount}, :incoming_amount},
          {%{payment | incoming_amount: %{payment.incoming_amount | value: "-1"}},
           "incoming_amount.value"},
          {%{payment | extensions: %{"id" => "override"}}, :extensions}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPayment.validate(changed)
    end

    assert :ok =
             IncomingPayment.validate(%{
               payment
               | incoming_amount: nil,
                 expires_at: nil,
                 metadata: nil
             })
  end

  test "protects reserved protocol fields on export and treats snake-case wire names as extensions" do
    {:ok, payment} = IncomingPayment.from_map(@payment)

    overrides =
      Map.new(
        ~w(id completed receivedAmount createdAt walletAddress incomingAmount expiresAt metadata),
        &{&1, "override"}
      )

    assert IncomingPayment.to_map(%{payment | extensions: overrides}) == @payment

    wire =
      Map.merge(@payment, %{
        "wallet_address" => "extension-wallet",
        "incoming_amount" => "extension-amount"
      })

    assert {:ok, payment} = IncomingPayment.from_map(wire)
    assert payment.wallet_address == @payment["walletAddress"]
    assert payment.incoming_amount == nil
    assert IncomingPayment.to_map(payment) == wire
  end

  test "rejects non-objects and errors expose only safe field names" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :incoming_payment}]} = error} =
               IncomingPayment.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    assert {:error, %Error{validation_errors: [%{field: "received_amount.value"}]} = error} =
             IncomingPayment.from_map(
               put_in(@payment, ["receivedAmount", "value"], "private-value")
             )

    refute inspect(Map.from_struct(error)) =~ "private-value"
  end

  test "hides metadata and extension payloads in inspection while explicit exports retain them" do
    wire =
      @payment
      |> Map.put("metadata", %{"description" => "private-note"})
      |> Map.put("methods", [%{"sharedSecret" => "private-method-secret"}])
      |> Map.put("receivedAmount", Map.put(@amount, "custom", "private-amount-extra"))

    {:ok, payment} = IncomingPayment.from_map(wire)
    refute inspect(payment) =~ "private-"
    assert IncomingPayment.to_map(payment) == wire
    assert Jason.decode!(Jason.encode!(payment)) == wire
  end
end
