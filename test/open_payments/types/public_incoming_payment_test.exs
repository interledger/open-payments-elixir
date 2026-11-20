defmodule OpenPayments.Types.PublicIncomingPaymentTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, ILPPaymentMethod, PublicIncomingPayment}

  @amount %{"value" => "250", "assetCode" => "USD", "assetScale" => 2}
  @method %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-secret"}
  @payment %{
    "id" => "https://wallet.example.com/tenant/incoming-payments/payment-1",
    "completed" => false,
    "receivedAmount" => @amount,
    "createdAt" => "2026-11-17T09:20:50.52Z",
    "authServer" => "https://auth.wallet.example.com/tenant",
    "methods" => [@method]
  }

  test "matches the pinned public schema composition and field requirements" do
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment-without-access-token")

    assert hd(schema["allOf"]) == %{
             "$ref" => "#/components/schemas/incoming-payment-base-with-methods"
           }

    public_fields = Enum.at(schema["allOf"], 1)
    assert public_fields["required"] == ["authServer"]
    assert public_fields["properties"]["authServer"]["format"] == "uri"

    {:ok, base} = Specification.fetch_schema(:resource, "incoming-payment-base")
    assert base["required"] == ~w(id completed receivedAmount createdAt)
    assert base["properties"]["createdAt"]["format"] == "date-time"
    assert base["properties"]["expiresAt"]["format"] == "date-time"
    assert base["properties"]["completed"]["default"] == false

    {:ok, base_methods} =
      Specification.fetch_schema(:resource, "incoming-payment-base-with-methods")

    method_fields = Enum.at(base_methods["allOf"], 1)
    assert method_fields["required"] == ["methods"]
    assert method_fields["properties"]["methods"]["uniqueItems"] == true
    assert method_fields["properties"]["methods"]["minItems"] == 0
  end

  test "decodes and round trips the official public incoming-payment examples" do
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment-without-access-token")

    for wire <- schema["examples"] do
      assert {:ok, %PublicIncomingPayment{} = payment} = PublicIncomingPayment.from_map(wire)
      assert %Amount{} = payment.received_amount
      assert %Amount{} = payment.incoming_amount
      assert [%ILPPaymentMethod{}] = payment.methods
      assert payment.created_at == wire["createdAt"]
      assert payment.extensions == %{}
      assert :ok = PublicIncomingPayment.validate(payment)
      assert PublicIncomingPayment.to_map(payment) == wire
      assert Jason.decode!(Jason.encode!(payment)) == wire
    end
  end

  test "round trips minimal public responses without inventing payment details" do
    for wire <- [
          %{"authServer" => @payment["authServer"]},
          %{"authServer" => @payment["authServer"], "receivedAmount" => @amount},
          %{
            "authServer" => @payment["authServer"],
            "receivedAmount" => @amount,
            "custom" => %{"private" => "extension-sentinel"}
          }
        ] do
      assert {:ok, payment} = PublicIncomingPayment.from_map(wire)
      assert payment.id == nil
      assert payment.completed == nil
      assert payment.created_at == nil
      assert payment.methods == nil
      assert payment.incoming_amount == nil
      assert payment.expires_at == nil
      assert :ok = PublicIncomingPayment.validate(payment)
      assert PublicIncomingPayment.to_map(payment) == wire
      assert Jason.decode!(Jason.encode!(payment)) == wire
      refute inspect(payment) =~ "extension-sentinel"
    end
  end

  test "validates minimal authorization and optional received amount" do
    assert :ok =
             PublicIncomingPayment.validate(%PublicIncomingPayment{
               auth_server: @payment["authServer"]
             })

    for data <- [%{}, %{"authServer" => nil}, %{"authServer" => "relative/path"}] do
      assert {:error, %Error{validation_errors: [%{field: :auth_server}]}} =
               PublicIncomingPayment.from_map(data)
    end

    for received <- [nil, false, [], %{"value" => "private-invalid"}] do
      assert {:error, %Error{} = error} =
               PublicIncomingPayment.from_map(%{
                 "authServer" => @payment["authServer"],
                 "receivedAmount" => received
               })

      refute inspect(error) =~ "private-invalid"
    end

    assert {:error, %Error{validation_errors: [%{field: :received_amount}]}} =
             PublicIncomingPayment.validate(%PublicIncomingPayment{
               auth_server: @payment["authServer"],
               received_amount: @amount
             })

    assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
             PublicIncomingPayment.validate(%PublicIncomingPayment{
               auth_server: @payment["authServer"],
               extensions: %{"methods" => []}
             })
  end

  test "partial detailed responses cannot fall back to the minimal shape" do
    for {field, value} <- [
          {"id", @payment["id"]},
          {"completed", false},
          {"createdAt", @payment["createdAt"]},
          {"methods", []},
          {"incomingAmount", @amount},
          {"expiresAt", "2026-11-20T12:00:00Z"}
        ],
        value <- [value, nil] do
      assert {:error, %Error{kind: :validation}} =
               PublicIncomingPayment.from_map(%{
                 "authServer" => @payment["authServer"],
                 "receivedAmount" => @amount,
                 field => value
               })
    end
  end

  test "requires base fields, auth server and methods without applying schema defaults" do
    for {wire_field, field} <- [
          {"id", :id},
          {"completed", :completed},
          {"receivedAmount", :received_amount},
          {"createdAt", :created_at},
          {"methods", :methods},
          {"authServer", :auth_server}
        ],
        data <- [Map.delete(@payment, wire_field), Map.put(@payment, wire_field, nil)] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               PublicIncomingPayment.from_map(data)
    end
  end

  test "distinguishes absent optional fields from explicit JSON nulls" do
    assert {:ok, payment} = PublicIncomingPayment.from_map(@payment)
    assert payment.incoming_amount == nil
    assert payment.expires_at == nil
    assert PublicIncomingPayment.to_map(payment) == @payment

    for {wire_field, field} <- [{"incomingAmount", :incoming_amount}, {"expiresAt", :expires_at}] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               PublicIncomingPayment.from_map(Map.put(@payment, wire_field, nil))
    end
  end

  test "rejects incorrect boolean and URI values while preserving valid absolute URIs" do
    for {wire_field, field, values} <- [
          {"completed", :completed, [0, "false", [], %{}]},
          {"id", :id, ["", "relative/path", "$wallet.example.com", "https://", 1]},
          {"authServer", :auth_server, ["", "auth.example.com", "https://", false]}
        ],
        value <- values do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               PublicIncomingPayment.from_map(Map.put(@payment, wire_field, value))
    end

    data =
      Map.merge(@payment, %{
        "id" => "http://localhost:3000/tenant/payments/x?query=1#fragment",
        "authServer" => "http://localhost:3006/tenant"
      })

    assert {:ok, payment} = PublicIncomingPayment.from_map(data)
    assert PublicIncomingPayment.to_map(payment) == data
  end

  test "validates nested amounts with field paths and preserves additional amount fields" do
    for field <- ["receivedAmount", "incomingAmount"] do
      data = Map.put(@payment, field, %{@amount | "value" => "18446744073709551616"})

      expected =
        if field == "receivedAmount", do: "received_amount.value", else: "incoming_amount.value"

      assert {:error, %Error{validation_errors: [%{field: ^expected}]}} =
               PublicIncomingPayment.from_map(data)
    end

    data =
      @payment
      |> Map.put("receivedAmount", Map.put(@amount, "custom", [true, nil]))
      |> Map.put("incomingAmount", %{
        @amount
        | "assetCode" => "EUR",
          "assetScale" => 3,
          "value" => "0001"
      })

    assert {:ok, payment} = PublicIncomingPayment.from_map(data)
    assert payment.incoming_amount.value == "0001"
    assert PublicIncomingPayment.to_map(payment) == data
  end

  test "requires unique method objects but permits empty arrays and distinct secrets" do
    for methods <- [[], [@method, Map.put(@method, "sharedSecret", "second-secret")]] do
      data = Map.put(@payment, "methods", methods)
      assert {:ok, payment} = PublicIncomingPayment.from_map(data)
      assert PublicIncomingPayment.to_map(payment) == data
    end

    for methods <- [nil, %{}, "ilp", [@method, @method]] do
      assert {:error, %Error{validation_errors: [%{field: :methods}]}} =
               PublicIncomingPayment.from_map(Map.put(@payment, "methods", methods))
    end
  end

  test "indexes invalid method fields and excludes rejected values from diagnostics" do
    for {method, field} <- [
          {nil, "methods[1]"},
          {Map.put(@method, "type", "card"), "methods[1].type"},
          {Map.put(@method, "sharedSecret", "private-secret="), "methods[1].shared_secret"},
          {Map.put(@method, "extra", "private-extra"), "methods[1]"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               PublicIncomingPayment.from_map(Map.put(@payment, "methods", [@method, method]))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "retains timestamp spelling, offsets, precision and RFC 3339 examples" do
    for timestamp <- [
          "1985-04-12T23:20:50.52Z",
          "1996-12-19T16:39:57-08:00",
          "1990-12-31T23:59:60Z",
          "1990-12-31T15:59:60-08:00",
          "1991-01-01T00:59:60+01:00",
          "1937-01-01T12:00:27.87+00:20",
          "2024-02-29t09:20:50.123456789z",
          "2026-11-17T09:20:50-00:00",
          "2026-11-17T09:20:50+23:59"
        ] do
      data = Map.merge(@payment, %{"createdAt" => timestamp, "expiresAt" => timestamp})
      assert {:ok, payment} = PublicIncomingPayment.from_map(data)
      assert payment.created_at == timestamp
      assert payment.expires_at == timestamp
      assert PublicIncomingPayment.to_map(payment) == data
    end
  end

  test "rejects invalid dates, times, offsets and incomplete timestamps" do
    for timestamp <- [
          nil,
          1,
          <<255>>,
          "2026-11-17",
          "2026-11-17T09:20:50",
          "2026-11-17 09:20:50Z",
          "2026-11-17T09:20:50,1Z",
          "2026-11-17T09:20:50.Z",
          "2026-11-17T09:20:50Z\n",
          "2026-02-29T09:20:50Z",
          "1900-02-29T09:20:50Z",
          "2026-04-31T09:20:50Z",
          "2026-13-01T09:20:50Z",
          "2026-11-17T24:00:00Z",
          "2026-11-17T09:60:50Z",
          "2026-11-17T09:20:61Z",
          "2026-11-17T09:20:60Z",
          "2026-11-17T23:59:60+01:00",
          "1990-12-30T23:59:60Z",
          "1990-12-31T00:59:60+01:00",
          "2026-11-17T09:20:50+24:00",
          "2026-11-17T09:20:50+00:60"
        ],
        {wire_field, field} <- [{"createdAt", :created_at}, {"expiresAt", :expires_at}] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               PublicIncomingPayment.from_map(Map.put(@payment, wire_field, timestamp))
    end
  end

  test "preserves permitted extension JSON and omits methods and extensions from inspection" do
    data =
      Map.merge(@payment, %{
        "custom" => %{"private-extension" => [nil, true, 123, "secret"]},
        "walletAddress" => "https://wallet.example.com/alice",
        "metadata" => %{"private-metadata" => "value"}
      })

    assert {:ok, payment} = PublicIncomingPayment.from_map(data)
    assert payment.extensions == Map.take(data, ~w(custom walletAddress metadata))
    assert PublicIncomingPayment.to_map(payment) == data
    refute inspect(payment) =~ "test-secret"
    refute inspect(payment) =~ "private-"
    assert Jason.decode!(Jason.encode!(payment)) == data
  end

  test "validates manually modified nested structs, unique methods and extension rules" do
    assert {:ok, payment} = PublicIncomingPayment.from_map(@payment)

    for {changes, field} <- [
          {%{received_amount: @amount}, :received_amount},
          {%{received_amount: %{payment.received_amount | asset_scale: 256}},
           "received_amount.asset_scale"},
          {%{incoming_amount: %{@amount | "value" => "1"}}, :incoming_amount},
          {%{incoming_amount: %{payment.received_amount | value: "-1"}}, "incoming_amount.value"},
          {%{methods: [@method]}, "methods[0]"},
          {%{methods: [%{hd(payment.methods) | shared_secret: "secret="}]},
           "methods[0].shared_secret"},
          {%{methods: payment.methods ++ payment.methods}, :methods},
          {%{extensions: %{"createdAt" => "bad"}}, :extensions},
          {%{extensions: %{custom: true}}, :extensions},
          {%{extensions: %{"custom" => self()}}, :extensions}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               PublicIncomingPayment.validate(struct!(payment, changes))
    end

    assert {:ok, with_optionals} =
             PublicIncomingPayment.from_map(
               Map.merge(@payment, %{
                 "incomingAmount" => @amount,
                 "expiresAt" => "2020-01-01T00:00:00Z"
               })
             )

    assert :ok = PublicIncomingPayment.validate(with_optionals)

    assert :ok =
             PublicIncomingPayment.validate(%{payment | expires_at: nil, incoming_amount: nil})

    refute PublicIncomingPayment.to_map(%{payment | extensions: %{"completed" => "bad"}})[
             "completed"
           ]
  end

  test "rejects non-objects and non-JSON extensions without exposing input values" do
    for data <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :public_incoming_payment}]} = error} =
               PublicIncomingPayment.from_map(data)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
             PublicIncomingPayment.from_map(Map.put(@payment, :custom, true))
  end
end
