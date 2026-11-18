defmodule OpenPayments.Types.IncomingPaymentWithMethodsTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, ILPPaymentMethod, IncomingPayment, IncomingPaymentWithMethods}

  @amount %{"value" => "250", "assetCode" => "USD", "assetScale" => 2}
  @method %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-secret"}
  @payment %{
    "id" => "https://wallet.example.com/tenant/incoming-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "completed" => false,
    "receivedAmount" => @amount,
    "createdAt" => "2026-11-18T09:20:50.52Z",
    "methods" => [@method]
  }

  test "matches pinned detail/method composition, required array and ILP union" do
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment-with-access-token")

    assert schema["allOf"] == [
             %{"$ref" => "#/components/schemas/incoming-payment-base-with-methods"},
             %{"$ref" => "#/components/schemas/incoming-payment-base-with-details"}
           ]

    {:ok, with_methods} =
      Specification.fetch_schema(:resource, "incoming-payment-base-with-methods")

    fields = Enum.at(with_methods["allOf"], 1)
    assert fields["required"] == ["methods"]
    assert fields["properties"]["methods"]["uniqueItems"] == true
    assert fields["properties"]["methods"]["minItems"] == 0

    assert fields["properties"]["methods"]["items"]["anyOf"] == [
             %{"$ref" => "#/components/schemas/ilp-payment-method"}
           ]
  end

  test "round trips standalone, create and authenticated-read examples with flat typed fields" do
    document = Specification.document(:resource)
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment-with-access-token")

    created =
      document["paths"]["/incoming-payments"]["post"]["responses"]["201"]["content"][
        "application/json"
      ]["examples"]

    reads =
      document["paths"]["/incoming-payments/{id}"]["get"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    create_items = for {_name, %{"value" => wire}} <- created, do: wire

    read_items =
      for {_name, %{"value" => wire}} <- reads, Map.has_key?(wire, "walletAddress"), do: wire

    assert create_items != [] and read_items != []

    for wire <- schema["examples"] ++ create_items ++ read_items do
      assert {:ok,
              %IncomingPaymentWithMethods{
                received_amount: %Amount{},
                methods: [%ILPPaymentMethod{}]
              } = payment} = IncomingPaymentWithMethods.from_map(wire)

      assert payment.wallet_address == wire["walletAddress"]
      assert :ok = IncomingPaymentWithMethods.validate(payment)
      assert IncomingPaymentWithMethods.to_map(payment) == wire
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "requires methods alongside all required detailed fields without filling defaults" do
    for {wire_field, field} <- [
          {"methods", :methods},
          {"id", :id},
          {"walletAddress", :wallet_address},
          {"completed", :completed},
          {"receivedAmount", :received_amount},
          {"createdAt", :created_at}
        ],
        wire <- [Map.delete(@payment, wire_field), Map.put(@payment, wire_field, nil)] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPaymentWithMethods.from_map(wire)
    end

    assert {:ok, _} = IncomingPayment.from_map(Map.delete(@payment, "methods"))
  end

  test "permits empty arrays and distinct complete methods while preserving order" do
    methods = [@method, Map.put(@method, "sharedSecret", "second-secret")]

    for values <- [[], methods, Enum.reverse(methods)] do
      wire = Map.put(@payment, "methods", values)
      assert {:ok, payment} = IncomingPaymentWithMethods.from_map(wire)
      assert IncomingPaymentWithMethods.to_map(payment) == wire
      assert :ok = IncomingPaymentWithMethods.validate(payment)
    end

    for values <- [false, "ilp", %{}, [@method, @method]] do
      assert {:error, %Error{validation_errors: [%{field: :methods}]}} =
               IncomingPaymentWithMethods.from_map(Map.put(@payment, "methods", values))
    end
  end

  test "indexes malformed method fields and omits rejected values from errors" do
    for {value, field} <- [
          {nil, "methods[1]"},
          {Map.put(@method, "type", "card"), "methods[1].type"},
          {Map.put(@method, "sharedSecret", "private-secret="), "methods[1].shared_secret"},
          {Map.put(@method, "custom", "private-extra"), "methods[1]"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               IncomingPaymentWithMethods.from_map(Map.put(@payment, "methods", [@method, value]))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "composes detail validation for amounts, metadata, timestamps and optional nulls" do
    for {wire, field} <- [
          {Map.put(@payment, "incomingAmount", nil), :incoming_amount},
          {Map.put(@payment, "expiresAt", nil), :expires_at},
          {Map.put(@payment, "metadata", nil), :metadata},
          {Map.put(@payment, "metadata", []), :metadata},
          {Map.put(@payment, "createdAt", "2026-02-29T00:00:00Z"), :created_at},
          {put_in(@payment, ["receivedAmount", "value"], "18446744073709551616"),
           "received_amount.value"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPaymentWithMethods.from_map(wire)
    end
  end

  test "retains optional details and metadata without comparing assets, amount values or time" do
    wire =
      Map.merge(@payment, %{
        "incomingAmount" => %{
          @amount
          | "value" => "0001",
            "assetCode" => "EUR",
            "assetScale" => 3
        },
        "expiresAt" => "2020-01-01T00:00:00Z",
        "createdAt" => "2026-11-18t09:20:50.123456789z",
        "metadata" => %{"private-note" => [nil, true, %{"externalRef" => "invoice-1"}]}
      })

    assert {:ok, payment} = IncomingPaymentWithMethods.from_map(wire)
    assert payment.incoming_amount.value == "0001"
    assert IncomingPaymentWithMethods.to_map(payment) == wire
    assert :ok = IncomingPaymentWithMethods.validate(payment)

    assert :ok =
             IncomingPaymentWithMethods.validate(%{
               payment
               | incoming_amount: nil,
                 expires_at: nil,
                 metadata: nil
             })
  end

  test "preserves permitted extensions and response URI spelling without requiring authServer" do
    wire =
      Map.merge(@payment, %{
        "authServer" => "https://auth.example.com/tenant",
        "custom" => [nil, true],
        "id" => "http://localhost:3000/opaque?part=1#state",
        "walletAddress" => "https://Wallet.Example.COM:8443/alice%2Fid?part=1#state"
      })

    assert {:ok, payment} = IncomingPaymentWithMethods.from_map(wire)
    assert payment.extensions == Map.take(wire, ~w(authServer custom))
    assert Jason.decode!(Jason.encode!(payment)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               IncomingPaymentWithMethods.from_map(Map.merge(@payment, extra))
    end
  end

  test "revalidates typed methods, complete wire-object uniqueness and shared details after manual edits" do
    {:ok, payment} = IncomingPaymentWithMethods.from_map(@payment)
    method = hd(payment.methods)

    for {changed, field} <- [
          {%{payment | methods: nil}, :methods},
          {%{payment | methods: [@method]}, "methods[0]"},
          {%{payment | methods: [%{method | shared_secret: "private-secret="}]},
           "methods[0].shared_secret"},
          {%{payment | methods: [method, method]}, :methods},
          {%{payment | methods: [method, Map.put(method, :custom, true)]}, :methods},
          {%{payment | received_amount: @amount}, :received_amount},
          {%{payment | received_amount: %{payment.received_amount | value: "-1"}},
           "received_amount.value"},
          {%{payment | wallet_address: "relative"}, :wallet_address},
          {%{payment | metadata: []}, :metadata},
          {%{payment | extensions: %{"methods" => []}}, :extensions},
          {%{payment | extensions: %{"completed" => true}}, :extensions},
          {%{payment | extensions: %{custom: true}}, :extensions}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPaymentWithMethods.validate(changed)
    end
  end

  test "protects reserved protocol fields on export, including methods and absent optionals" do
    {:ok, payment} = IncomingPaymentWithMethods.from_map(@payment)

    overrides =
      Map.new(
        ~w(id completed receivedAmount createdAt walletAddress methods incomingAmount expiresAt metadata),
        &{&1, "override"}
      )

    assert IncomingPaymentWithMethods.to_map(%{payment | extensions: overrides}) == @payment
  end

  test "rejects non-objects with a safe type-specific root error" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error,
              %Error{validation_errors: [%{field: :incoming_payment_with_methods}]} = error} =
               IncomingPaymentWithMethods.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end
  end

  test "hides method secrets, metadata and extensions while explicit map/JSON exports include them" do
    wire =
      Map.merge(@payment, %{
        "metadata" => %{"description" => "private-note"},
        "custom" => "private-extension"
      })

    {:ok, payment} = IncomingPaymentWithMethods.from_map(wire)
    refute inspect(payment) =~ "test-secret"
    refute inspect(payment) =~ "private-"
    assert IncomingPaymentWithMethods.to_map(payment) == wire
    assert Jason.decode!(Jason.encode!(payment)) == wire
  end
end
