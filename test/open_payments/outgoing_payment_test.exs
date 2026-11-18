defmodule OpenPayments.OutgoingPaymentTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Key, OutgoingPayment, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, Amount, ContinuationToken}
  alias OpenPayments.Types.OutgoingPayment, as: PaymentData

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @url "https://resource.example.com/tenant/opaque?part=1"
  @debit %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @payment %{
    "id" => "https://resource.example.com/outgoing-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "debitAmount" => @debit,
    "receiveAmount" => @receive,
    "sentAmount" => %{"value" => "1205", "assetCode" => "USD", "assetScale" => 2},
    "failed" => false,
    "createdAt" => "2026-11-18T09:20:50Z"
  }

  test "matches the pinned payment GET and decodes every official read example" do
    operation = Enum.find(Specification.operations(), &(&1.id == "get-outgoing-payment"))
    assert operation.method == :get and operation.server == :resource
    assert operation.success_statuses == [200]

    content =
      Specification.document(:resource)["paths"]["/outgoing-payments/{id}"]["get"]["responses"][
        "200"
      ][
        "content"
      ]["application/json"]

    assert content["schema"] == %{"$ref" => "#/components/schemas/outgoing-payment"}
    assert map_size(content["examples"]) > 0
    read_client = client(adapter: TransportAdapter)
    url = "https://alias.example.com/opaque"

    for {_name, %{"value" => wire}} <- content["examples"] do
      respond(200, Jason.encode!(wire))

      assert {:ok,
              %PaymentData{
                debit_amount: %Amount{},
                receive_amount: %Amount{},
                sent_amount: %Amount{}
              } = payment} = OutgoingPayment.get(read_client, url, access_token: token())

      assert PaymentData.to_map(payment) == wire
    end
  end

  test "sends exact signed bodyless GETs with raw/typed tokens without appending paths or extra lookups" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@payment)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "payment-read-1"})
    target = "/tenant/opaque%2fresource/../payment?part=a%2Bb&part=2"
    original = client

    for supplied <- ["test-resource-token", token()] do
      assert {:ok, payment} = OutgoingPayment.get(client, base <> target, access_token: supplied)
      assert PaymentData.to_map(payment) == @payment
      assert_receive {:http_request, wire}
      assert wire.method == "GET" and wire.target == target and wire.body == ""
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["accept"] == "application/json"
      assert headers["accept-encoding"] == "identity"
      assert headers["x-request-id"] == "payment-read-1"
      refute Map.has_key?(headers, "content-digest")
      refute Map.has_key?(headers, "content-type")
      assert verify_wire(wire)
      refute verify_wire(%{wire | target: target <> "tampered"})
      refute verify_wire(%{wire | method: "POST"})

      refute verify_wire(%{
               wire
               | headers:
                   List.keyreplace(
                     wire.headers,
                     "authorization",
                     0,
                     {"authorization", "GNAP changed-token"}
                   )
             })

      refute_receive {:http_request, _}, 20
    end

    assert client == original
  end

  test "supports HTTPS ports and queries and retrieves fresh responses using per-call credentials" do
    client = client(adapter: TransportAdapter)
    url = "https://resource.example.com:8443/tenant/opaque?part=1&part=2"

    for {value, access} <- [{"100", "first-token"}, {"200", "second-token"}] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == url
        assert Req.Request.get_header(request, "authorization") == ["GNAP " <> access]

        wire = %{
          @payment
          | "debitAmount" => %{@debit | "value" => value},
            "sentAmount" => %{@debit | "value" => "0"}
        }

        {request, Req.Response.new(body: Jason.encode!(wire))}
      end)

      assert {:ok, payment} = OutgoingPayment.get(client, url, access_token: access)
      assert payment.debit_amount.value == value
    end
  end

  test "requires a valid authenticated client and one supported per-call token option" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :get_outgoing_payment}} =
               OutgoingPayment.get(invalid, @url, access_token: "test-token")
    end

    {:ok, continuation} = ContinuationToken.from_map(%{"value" => "private-token"})

    for opts <- [
          nil,
          %{},
          [:bad],
          [],
          [access_token: nil],
          [access_token: continuation],
          [access_token: %{"value" => "private-token"}],
          [access_token: "test", access_token: "other"],
          [access_token: "test", key: "private-key"],
          [access_token: "test", headers: %{}],
          [access_token: "test", pagination: %{}],
          [access_token: "test", json: %{}]
        ] do
      assert {:error, %Error{kind: :validation, operation: :get_outgoing_payment} = error} =
               OutgoingPayment.get(client, @url, opts)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates issued token fields and token68 before HTTP without leaking rejected values" do
    no_request()

    for {supplied, field} <- [
          {%{token() | value: nil}, "access_token.value"},
          {%{token() | manage: "private-relative"}, "access_token.manage"},
          {%{token() | access: nil}, "access_token.access"},
          {"private-token\r\n", :access_token}
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :get_outgoing_payment,
                validation_errors: [%{field: ^field}]
              } = error} =
               OutgoingPayment.get(client(adapter: TransportAdapter), @url,
                 access_token: supplied
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "rejects invalid full resource URLs before HTTP without inferring wallet or provider paths" do
    no_request()

    for url <- [
          nil,
          [],
          "",
          "/quotes/id",
          "$wallet.example.com/alice",
          "urn:example:payment",
          "http://localhost:3000/payment",
          "ftp://resource.example.com/id",
          "https://user@resource.example.com/id",
          @url <> "#fragment",
          "https://resource.example.com:65536/id"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :get_outgoing_payment,
                validation_errors: [%{field: :url}]
              }} =
               OutgoingPayment.get(client(adapter: TransportAdapter), url,
                 access_token: "test-token"
               )
    end
  end

  test "preserves cross-asset receive amounts, optional fields and unrelated identities without extra business rules" do
    client = client(adapter: TransportAdapter)
    supplied = %{token() | expires_in: -1}

    wires = [
      @payment,
      Map.delete(@payment, "failed"),
      Map.merge(@payment, %{
        "debitAmount" => %{@debit | "value" => "0000"},
        "sentAmount" => %{@debit | "value" => "0"},
        "quoteId" => "urn:example:private-payment",
        "metadata" => %{"private-metadata" => []},
        "walletAddress" => "https://other.example.com/private-wallet"
      })
    ]

    for wire <- wires do
      respond(200, Jason.encode!(wire), [{"content-type", "text/plain"}])
      assert {:ok, payment} = OutgoingPayment.get(client, @url, access_token: supplied)
      assert PaymentData.to_map(payment) == wire
      refute inspect(payment) =~ "private-"
    end
  end

  test "classifies malformed JSON, unsupported encoding and wrong success statuses safely" do
    for {status, body, headers, code} <- [
          {200, "private-invalid-json", [], "invalid_json"},
          {201, Jason.encode!(@payment), [], "unexpected_status"},
          {204, "", [], "unexpected_status"},
          {200, "null", [], "invalid_response"},
          {200, "{}", [], "invalid_response"},
          {200, Jason.encode!(@payment), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :get_outgoing_payment
              } = error} =
               OutgoingPayment.get(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "enforces strict payment fields and reports safe nested response paths with status 200" do
    for {wire, field} <- [
          {Map.delete(@payment, "receiveAmount"), :receive_amount},
          {Map.delete(@payment, "sentAmount"), :sent_amount},
          {Map.put(@payment, "updatedAt", "private-time"), :outgoing_payment},
          {Map.put(@payment, "grantSpentDebitAmount", @debit), :outgoing_payment},
          {Map.put(@payment, "quoteId", nil), :quote_id},
          {Map.put(@payment, "failed", nil), :failed},
          {Map.put(@payment, "metadata", []), :metadata},
          {%{@payment | "debitAmount" => %{@debit | "value" => "private-amount"}},
           "debit_amount.value"},
          {%{@payment | "receiveAmount" => %{@receive | "assetScale" => 256}},
           "receive_amount.asset_scale"},
          {%{@payment | "sentAmount" => %{@debit | "value" => "18446744073709551616"}},
           "sent_amount.value"},
          {%{@payment | "receiver" => "private-receiver"}, :receiver}
        ] do
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :get_outgoing_payment,
                validation_errors: [%{field: ^field}]
              } = error} =
               OutgoingPayment.get(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "accepts the valid standalone example and rejects the invalid one without repair" do
    {:ok, schema} = Specification.fetch_schema(:resource, "outgoing-payment")
    [valid, invalid] = schema["examples"]
    respond(200, Jason.encode!(valid))

    assert {:ok, payment} =
             OutgoingPayment.get(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    assert PaymentData.to_map(payment) == valid

    for wire <- [invalid, Map.put(invalid, "receiveAmount", @receive)] do
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :get_outgoing_payment
              }} =
               OutgoingPayment.get(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )
    end
  end

  test "applies Node asset checks after schema decoding while the standalone codec accepts the data" do
    for changed <- [%{@debit | "assetCode" => "CAD"}, %{@debit | "assetScale" => 3}] do
      wire = %{@payment | "sentAmount" => changed}
      assert {:ok, _payment} = PaymentData.from_map(wire)
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                code: "invalid_response",
                status: 200,
                operation: :get_outgoing_payment,
                validation_errors: [%{field: :sent_amount, message: message}]
              } = error} =
               OutgoingPayment.get(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      assert message =~ "same asset code and scale"
      assert error.description == "Invalid Open Payments outgoing-payment response"
      refute inspect(Map.from_struct(error)) =~ "CAD"
    end
  end

  test "compares debit and sent cap numerically without floating-point precision or lexicographic ordering" do
    for {debit, sent, accepted?} <- [
          {"10", "9", true},
          {"9", "10", false},
          {"0005", "0006", false},
          {"0006", "5", true},
          {"9007199254740992", "9007199254740993", false},
          {"18446744073709551614", "18446744073709551615", false},
          {"18446744073709551615", "18446744073709551614", true},
          {"18446744073709551615", "18446744073709551615", true},
          {"0", "0", true}
        ] do
      wire =
        Map.merge(@payment, %{
          "debitAmount" => %{@debit | "value" => debit},
          "sentAmount" => %{@debit | "value" => sent}
        })

      assert {:ok, _payment} = PaymentData.from_map(wire)
      respond(200, Jason.encode!(wire))

      result =
        OutgoingPayment.get(client(adapter: TransportAdapter), @url, access_token: "test-token")

      if accepted? do
        assert {:ok, payment} = result
        assert PaymentData.to_map(payment) == wire
      else
        assert {:error,
                %Error{
                  kind: :decoding,
                  code: "invalid_response",
                  status: 200,
                  operation: :get_outgoing_payment,
                  validation_errors: [
                    %{field: :sent_amount, message: "must not exceed debit_amount"}
                  ]
                }} = result
      end
    end
  end

  test "matches Node's failed rule using original amount strings and preserves optional failure state" do
    for {debit, sent, failed, accepted?} <- [
          {"5", "5", true, false},
          {"0", "0", true, false},
          {"18446744073709551615", "18446744073709551615", true, false},
          {"5", "5", false, true},
          {"5", "5", :omitted, true},
          {"5", "4", true, true},
          {"0005", "5", true, true},
          {"5", "0005", true, true},
          {"00", "0", true, true}
        ] do
      wire =
        Map.merge(@payment, %{
          "debitAmount" => %{@debit | "value" => debit},
          "sentAmount" => %{@debit | "value" => sent}
        })

      wire =
        if failed == :omitted,
          do: Map.delete(wire, "failed"),
          else: Map.put(wire, "failed", failed)

      assert {:ok, _payment} = PaymentData.from_map(wire)
      respond(200, Jason.encode!(wire))

      result =
        OutgoingPayment.get(client(adapter: TransportAdapter), @url, access_token: "test-token")

      if accepted? do
        assert {:ok, payment} = result
        assert PaymentData.to_map(payment) == wire
      else
        assert {:error,
                %Error{
                  kind: :decoding,
                  code: "invalid_response",
                  status: 200,
                  operation: :get_outgoing_payment,
                  validation_errors: [%{field: :failed}]
                }} = result
      end
    end
  end

  test "preserves HTTP errors without raw bodies or automatic grant/token refresh" do
    for status <- [401, 403, 404] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "denied",
                operation: :get_outgoing_payment
              }} =
               OutgoingPayment.get(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             OutgoingPayment.get(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not follow redirects or replay server/timeout/dropped-connection failures" do
    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/redirect" -> {302, [{"location", "/other"}], ""}
          "/unavailable" -> {503, [], "failed"}
          "/dropped" -> :close
        end
      end)

    for {path, kind, status} <- [
          {"/redirect", :http, 302},
          {"/unavailable", :http, 503},
          {"/dropped", :transport, nil}
        ] do
      assert {:error, %Error{kind: ^kind, status: ^status, operation: :get_outgoing_payment}} =
               OutgoingPayment.get(client(allow_http: true), base <> path,
                 access_token: "test-token"
               )

      assert_receive {:http_request, %{method: "GET", target: ^path}}
      refute_receive {:http_request, _}, 30
    end

    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), :attempt)
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :get_outgoing_payment}} =
             OutgoingPayment.get(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "isolates per-call credentials and URLs during concurrent reads with a shared client" do
    base =
      HTTPServer.start(fn request ->
        value = String.replace_prefix(Map.new(request.headers)["authorization"], "GNAP ", "")
        wire = %{@payment | "walletAddress" => "https://wallet.example.com/" <> value}
        {200, [], Jason.encode!(wire)}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"] do
        {value,
         Task.async(fn ->
           OutgoingPayment.get(client, base <> "/" <> value <> "?part=a%2Bb", access_token: value)
         end)}
      end

    for {value, task} <- tasks do
      assert {:ok, payment} = Task.await(task)
      assert payment.wallet_address == "https://wallet.example.com/" <> value
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}
      value = String.replace_prefix(Map.new(wire.headers)["authorization"], "GNAP ", "")
      assert wire.target == "/" <> value <> "?part=a%2Bb"
      assert verify_wire(wire)
    end
  end

  defp client(opts) do
    {:ok, key} = Key.from_seed(@seed, "example-key-1")

    {:ok, client} =
      Client.new_authenticated(
        Keyword.merge([wallet_address: "https://client.example.com/alice", key: key], opts)
      )

    client
  end

  defp token do
    {:ok, token} =
      AccessToken.from_map(%{
        "value" => "test-resource-token",
        "manage" => "https://auth.example.com/manage/id",
        "access" => []
      })

    token
  end

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Independently verify the actual GET target and authorization with the RFC public key.
  defp verify_wire(wire) do
    headers = Map.new(wire.headers)
    "sig1=" <> params = headers["signature-input"]

    assert String.starts_with?(
             params,
             ~s|("@method" "@target-uri" "authorization");keyid="example-key-1";created=|
           )

    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": http://#{headers["host"]}#{wire.target}),
          ~s("authorization": #{headers["authorization"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [@public, :ed25519])
  end
end
