defmodule OpenPayments.IncomingPaymentAuthenticatedTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, IncomingPayment, Key, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}

  alias OpenPayments.Types.{
    AccessToken,
    ContinuationToken,
    IncomingPaymentWithMethods,
    PublicIncomingPayment
  }

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @url "https://wallet.example.com/tenant/opaque?part=1"
  @amount %{"value" => "250", "assetCode" => "USD", "assetScale" => 2}
  @method %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-secret"}
  @payment %{
    "id" => "https://wallet.example.com/incoming-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "completed" => false,
    "receivedAmount" => @amount,
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T09:20:50Z",
    "methods" => [@method]
  }

  test "matches the pinned GET and selects the authenticated response branch" do
    operation = Enum.find(Specification.operations(), &(&1.id == "get-incoming-payment"))
    assert operation.method == :get and operation.server == :resource
    assert operation.success_statuses == [200]

    schema =
      Specification.document(:resource)["paths"]["/incoming-payments/{id}"]["get"]["responses"][
        "200"
      ]["content"]["application/json"]["schema"]

    assert %{"$ref" => "#/components/schemas/incoming-payment-with-access-token"} in schema[
             "anyOf"
           ]

    assert %{"$ref" => "#/components/schemas/incoming-payment-without-access-token"} in schema[
             "anyOf"
           ]
  end

  test "sends exact signed GETs with opaque-string or typed tokens and no body or inferred path" do
    wire_payment = Map.put(@payment, "custom", %{"values" => [true, nil]})
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(wire_payment)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "read-auth-1"})
    target = "/tenant/opaque%2fresource/../payment?part=a%2Bb&part=2"
    original = client

    for supplied <- ["test-resource-token", token()] do
      assert {:ok, %IncomingPaymentWithMethods{} = payment} =
               IncomingPayment.get(client, base <> target, access_token: supplied)

      assert IncomingPaymentWithMethods.to_map(payment) == wire_payment
      assert_receive {:http_request, wire}
      assert wire.method == "GET" and wire.target == target and wire.body == ""
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["accept"] == "application/json"
      assert headers["accept-encoding"] == "identity"
      assert headers["x-request-id"] == "read-auth-1"
      refute Map.has_key?(headers, "content-digest")
      refute Map.has_key?(headers, "content-type")
      assert verify_wire(wire)
      refute verify_wire(%{wire | target: target <> "tampered"})

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

      refute inspect(payment) =~ "test-secret"
    end

    assert client == original
  end

  test "decodes every official authenticated read example without enforcing URL/response identity equality" do
    examples =
      Specification.document(:resource)["paths"]["/incoming-payments/{id}"]["get"]["responses"][
        "200"
      ]["content"]["application/json"]["examples"]

    values =
      for {_name, %{"value" => wire}} <- examples, Map.has_key?(wire, "walletAddress"), do: wire

    assert values != []
    client = client(adapter: TransportAdapter)

    for wire <- values do
      respond(200, Jason.encode!(wire))

      assert {:ok, payment} =
               IncomingPayment.get(client, "https://alias.example.com/opaque",
                 access_token: token()
               )

      assert IncomingPaymentWithMethods.to_map(payment) == wire
    end
  end

  test "preserves HTTPS ports/queries and retrieves fresh state with per-call credentials" do
    client = client(adapter: TransportAdapter)
    url = "https://wallet.example.com:8443/tenant/opaque?part=1&part=2"

    for {completed, value} <- [{false, "first-token"}, {true, "second-token"}] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == url
        assert Req.Request.get_header(request, "authorization") == ["GNAP " <> value]
        send(self(), :read_once)
        {request, Req.Response.new(body: Jason.encode!(%{@payment | "completed" => completed}))}
      end)

      assert {:ok, payment} = IncomingPayment.get(client, url, access_token: value)
      assert payment.completed == completed
      assert_received :read_once
      refute_received :read_once
    end
  end

  test "enforces Node asset-code and scale consistency beyond the standalone response codec" do
    client = client(adapter: TransportAdapter)

    for incoming <- [%{@amount | "assetCode" => "EUR"}, %{@amount | "assetScale" => 3}] do
      wire = Map.put(@payment, "incomingAmount", incoming)
      assert {:ok, _} = IncomingPaymentWithMethods.from_map(wire)
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :get_incoming_payment,
                validation_errors: [%{field: :incoming_amount}]
              } = error} = IncomingPayment.get(client, @url, access_token: "test-token")

      refute inspect(Map.from_struct(error)) =~ "EUR"
    end
  end

  test "permits missing incoming amount and preserves values/expiry without imposing extra business comparisons" do
    client = client(adapter: TransportAdapter)
    supplied = %{token() | expires_in: -1}

    wires = [
      Map.delete(@payment, "incomingAmount"),
      Map.merge(@payment, %{
        "incomingAmount" => %{@amount | "value" => "0001"},
        "receivedAmount" => %{@amount | "value" => "1000"},
        "completed" => true,
        "expiresAt" => "2020-01-01T00:00:00Z"
      })
    ]

    for wire <- wires do
      respond(200, Jason.encode!(wire))
      assert {:ok, payment} = IncomingPayment.get(client, @url, access_token: supplied)
      assert IncomingPaymentWithMethods.to_map(payment) == wire
    end
  end

  test "rejects public-shaped success responses in authenticated reads without falling back" do
    public =
      @payment
      |> Map.delete("walletAddress")
      |> Map.put("authServer", "https://auth.example.com/tenant")

    assert {:ok, _} = PublicIncomingPayment.from_map(public)
    respond(200, Jason.encode!(public))

    assert {:error,
            %Error{
              kind: :decoding,
              code: "invalid_response",
              status: 200,
              validation_errors: [%{field: :wallet_address}]
            }} =
             IncomingPayment.get(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )
  end

  test "requires a valid authenticated client and a single supported per-call token option" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for bad <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :get_incoming_payment}} =
               IncomingPayment.get(bad, @url, access_token: "test-token")
    end

    {:ok, continuation} = ContinuationToken.from_map(%{"value" => "test-continuation-token"})

    for opts <- [
          nil,
          %{},
          [:bad],
          [],
          [access_token: nil],
          [access_token: false],
          [access_token: 1],
          [access_token: %{"value" => "private-input"}],
          [access_token: continuation],
          [access_token: "test-token", access_token: "other-token"],
          [access_token: "test-token", key: "private-key"],
          [accessToken: "private-input"],
          [access_token: "test-token", headers: %{}]
        ] do
      assert {:error, %Error{kind: :validation, operation: :get_incoming_payment} = error} =
               IncomingPayment.get(client, @url, opts)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates typed tokens and rejects malformed header values without exposing them" do
    no_request()
    client = client(adapter: TransportAdapter)
    original = token()

    for {supplied, field} <- [
          {%{original | value: nil}, "access_token.value"},
          {%{original | manage: "relative"}, "access_token.manage"},
          {%{original | access: nil}, "access_token.access"},
          {%{original | expires_in: "3600"}, "access_token.expires_in"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               IncomingPayment.get(client, @url, access_token: supplied)
    end

    for value <- ["", "private token", "private\r\ntoken", "private🌍token", <<255>>] do
      assert {:error,
              %Error{kind: :validation, validation_errors: [%{field: :access_token}]} = error} =
               IncomingPayment.get(client, @url, access_token: value)

      refute inspect(Map.from_struct(error)) =~ "private"
    end
  end

  test "rejects invalid full resource URLs before sending without guessing wallet paths" do
    no_request()
    client = client(adapter: TransportAdapter)

    for url <- [
          nil,
          [],
          "",
          "/incoming-payments/id",
          "$wallet.example.com/alice",
          "urn:example:payment",
          "http://localhost:3000/id",
          "ftp://wallet.example.com/id",
          "https://user@wallet.example.com/id",
          "https://wallet.example.com/id#fragment",
          "https://wallet.example.com:65536/id"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :get_incoming_payment,
                validation_errors: [%{field: :url}]
              }} = IncomingPayment.get(client, url, access_token: "test-token")
    end
  end

  test "classifies invalid JSON, success status, content encoding and nested response errors safely" do
    client = client(adapter: TransportAdapter)

    for {status, body, headers, code} <- [
          {200, "not-json", [], "invalid_json"},
          {204, "", [], "unexpected_status"},
          {201, Jason.encode!(@payment), [], "unexpected_status"},
          {200, Jason.encode!(@payment), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"},
          {200, "null", [], "invalid_response"},
          {200, "{}", [], "invalid_response"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :get_incoming_payment
              }} = IncomingPayment.get(client, @url, access_token: "test-token")
    end

    respond(
      200,
      Jason.encode!(
        put_in(@payment, ["methods"], [%{@method | "sharedSecret" => "private-secret="}])
      )
    )

    assert {:error,
            %Error{
              kind: :decoding,
              code: "invalid_response",
              validation_errors: [%{field: "methods[0].shared_secret"}]
            } = error} = IncomingPayment.get(client, @url, access_token: "test-token")

    refute inspect(Map.from_struct(error)) =~ "private-secret"
  end

  test "preserves HTTP errors and statuses without refreshing tokens or exposing raw failure bodies" do
    client = client(adapter: TransportAdapter)

    for status <- [401, 403, 404] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "denied",
                operation: :get_incoming_payment
              }} = IncomingPayment.get(client, @url, access_token: "test-token")
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             IncomingPayment.get(client, @url, access_token: "test-token")

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not follow redirects or replay signed reads on server errors" do
    base =
      HTTPServer.start(fn request ->
        status = if request.target == "/redirect", do: 302, else: 503
        {status, [{"location", "/other"}], "failed"}
      end)

    client = client(allow_http: true)

    for {target, status} <- [{"/redirect", 302}, {"/unavailable", 503}] do
      assert {:error, %Error{kind: :http, status: ^status, operation: :get_incoming_payment}} =
               IncomingPayment.get(client, base <> target, access_token: "test-token")

      assert_receive {:http_request, %{method: "GET", target: ^target}}
      refute_receive {:http_request, _}, 30
    end
  end

  test "labels timeout and dropped-connection failures without replay" do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :get_incoming_payment}} =
             IncomingPayment.get(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    base = HTTPServer.start(fn _ -> :close end)

    assert {:error, %Error{kind: :transport, operation: :get_incoming_payment}} =
             IncomingPayment.get(client(allow_http: true), base <> "/payment",
               access_token: "test-token"
             )

    assert_receive {:http_request, %{method: "GET", target: "/payment"}}
    refute_receive {:http_request, _}, 30
  end

  test "shared clients isolate per-call credentials during concurrent authenticated reads" do
    base =
      HTTPServer.start(fn request ->
        {200, [],
         Jason.encode!(Map.put(@payment, "echo", Map.new(request.headers)["authorization"]))}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"],
          do:
            {value,
             Task.async(fn ->
               IncomingPayment.get(client, base <> "/" <> value, access_token: value)
             end)}

    for {value, task} <- tasks do
      assert {:ok, payment} = Task.await(task)
      assert payment.extensions["echo"] == "GNAP " <> value
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}

      assert Map.new(wire.headers)["authorization"] ==
               "GNAP " <> String.trim_leading(wire.target, "/")

      assert verify_wire(wire)
    end
  end

  test "public incoming-payment reads remain unsigned even with an authenticated client" do
    public =
      @payment
      |> Map.delete("walletAddress")
      |> Map.put("authServer", "https://auth.example.com/tenant")

    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(public)} end)

    assert {:ok, %PublicIncomingPayment{}} =
             IncomingPayment.get_public(client(allow_http: true), base <> "/payment")

    assert_receive {:http_request, wire}
    headers = Map.new(wire.headers)
    refute Map.has_key?(headers, "authorization")
    refute Map.has_key?(headers, "signature")
    refute Map.has_key?(headers, "signature-input")
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

  # Reconstruct independently from the actual GET with the RFC 8032 public key.
  defp verify_wire(wire) do
    headers = Map.new(wire.headers)
    "sig1=" <> params = headers["signature-input"]

    assert String.starts_with?(
             params,
             ~s|("@method" "@target-uri" "authorization");keyid="example-key-1";created=|
           )

    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])
    url = "http://" <> headers["host"] <> wire.target

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": #{url}),
          ~s("authorization": #{headers["authorization"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [@public, :ed25519])
  end
end
