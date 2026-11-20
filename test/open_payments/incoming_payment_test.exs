defmodule OpenPayments.IncomingPaymentTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, IncomingPayment, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{Amount, ILPPaymentMethod, PublicIncomingPayment}

  @method %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-secret"}
  @payment %{
    "id" => "https://wallet.example.com/tenant/incoming-payments/payment-1",
    "completed" => false,
    "receivedAmount" => %{"value" => "0", "assetCode" => "USD", "assetScale" => 2},
    "createdAt" => "2026-11-17T09:20:50.52Z",
    "authServer" => "https://auth.wallet.example.com/tenant",
    "methods" => [@method]
  }

  test "matches the pinned incoming-payment read and public response branch" do
    operation = Enum.find(Specification.operations(), &(&1.id == "get-incoming-payment"))
    assert operation.method == :get
    assert operation.server == :resource
    assert operation.success_statuses == [200]

    document = Specification.document(:resource)
    response = document["paths"]["/incoming-payments/{id}"]["get"]["responses"]["200"]

    assert %{"$ref" => "#/components/schemas/incoming-payment-without-access-token"} in response[
             "content"
           ]["application/json"]["schema"]["anyOf"]
  end

  test "reads a full resource URL over real unsigned HTTP without changing its path or query" do
    wire = Map.put(@payment, "custom", %{"value" => [true, nil]})
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(wire)} end)
    {:ok, client} = Client.new_public(allow_http: true, headers: %{"X-Request-ID" => "read-1"})
    target = "/tenant/opaque%2fresource/../payment?part=a%2Bb&part=second"

    assert {:ok, %PublicIncomingPayment{} = payment} =
             IncomingPayment.get_public(client, base <> target)

    assert %Amount{} = payment.received_amount
    assert [%ILPPaymentMethod{}] = payment.methods
    assert PublicIncomingPayment.to_map(payment) == wire
    assert_receive {:http_request, request}
    assert request.method == "GET"
    assert request.target == target
    assert request.body == ""
    headers = Map.new(request.headers)
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    assert headers["x-request-id"] == "read-1"
    refute Map.has_key?(headers, "signature")
    refute Map.has_key?(headers, "signature-input")
    refute Map.has_key?(headers, "authorization")
    refute inspect(payment) =~ "test-secret"
  end

  test "decodes the pinned public examples without imposing response/request identity equality" do
    {:ok, schema} = Specification.fetch_schema(:resource, "incoming-payment-without-access-token")
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for wire <- schema["examples"] do
      respond(200, Jason.encode!(wire))

      assert {:ok, payment} =
               IncomingPayment.get_public(client, "https://alias.example.com/payment")

      assert PublicIncomingPayment.to_map(payment) == wire
    end
  end

  test "permits resource queries and HTTPS ports and fetches fresh state on each read" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)
    url = "https://wallet.example.com:8443/tenant/resource?part=1&part=2"

    for completed <- [false, true] do
      Process.put({TransportAdapter, :callback}, fn request ->
        send(self(), {:requested, URI.to_string(request.url)})
        {request, Req.Response.new(body: Jason.encode!(%{@payment | "completed" => completed}))}
      end)

      assert {:ok, payment} = IncomingPayment.get_public(client, url)
      assert payment.completed == completed
      assert_received {:requested, ^url}
    end
  end

  test "rejects invalid resource targets and clients before making a request" do
    Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for url <- [
          nil,
          [],
          "",
          "/incoming-payments/payment-1",
          "$wallet.example.com/alice",
          "http://localhost:3000/resource",
          "ftp://wallet.example.com/resource",
          "https://user@wallet.example.com/resource",
          "https://wallet.example.com/resource#fragment",
          "https://wallet.example.com:65536/resource"
        ] do
      assert {:error, %Error{kind: :validation, operation: :get_public_incoming_payment}} =
               IncomingPayment.get_public(client, url)
    end

    assert {:error, %Error{kind: :configuration, operation: :get_public_incoming_payment}} =
             IncomingPayment.get_public(nil, "https://wallet.example.com/resource")
  end

  test "returns decoding errors for invalid JSON, unexpected status and content encoding" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for {status, body, headers, code} <- [
          {200, "", [], "invalid_json"},
          {200, "not-json", [], "invalid_json"},
          {204, "", [], "unexpected_status"},
          {201, Jason.encode!(@payment), [], "unexpected_status"},
          {200, Jason.encode!(@payment), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"}
        ] do
      Process.put({TransportAdapter, :callback}, fn request ->
        {request, Req.Response.new(status: status, body: body, headers: headers)}
      end)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :get_public_incoming_payment
              }} =
               IncomingPayment.get_public(client, "https://wallet.example.com/resource")
    end
  end

  test "accepts minimal public responses without inferring details from the request URL" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for wire <- [
          %{"authServer" => "https://auth.example.com"},
          %{
            "authServer" => "https://auth.example.com",
            "receivedAmount" => %{"value" => "300", "assetCode" => "EUR", "assetScale" => 2}
          }
        ] do
      respond(200, Jason.encode!(wire))

      assert {:ok, %PublicIncomingPayment{id: nil, methods: nil} = payment} =
               IncomingPayment.get_public(client, "https://wallet.example.com/resource")

      assert PublicIncomingPayment.to_map(payment) == wire
    end
  end

  test "validates the public schema and returns safe nested error paths" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for body <- ["null", "[]", "{}", Jason.encode!(Map.delete(@payment, "authServer"))] do
      respond(200, body)

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :get_public_incoming_payment
              }} =
               IncomingPayment.get_public(client, "https://wallet.example.com/resource")
    end

    wire = Map.put(@payment, "methods", [Map.put(@method, "sharedSecret", "private-secret=")])
    respond(200, Jason.encode!(wire))

    assert {:error, %Error{validation_errors: [%{field: "methods[0].shared_secret"}]} = error} =
             IncomingPayment.get_public(client, "https://wallet.example.com/resource")

    refute inspect(Map.from_struct(error)) =~ "private-secret"
  end

  test "preserves HTTP failure statuses and recognized server errors" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for status <- [401, 403, 404] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "denied",
                operation: :get_public_incoming_payment
              }} =
               IncomingPayment.get_public(client, "https://wallet.example.com/resource")
    end

    respond(500, "private-raw-error-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             IncomingPayment.get_public(client, "https://wallet.example.com/resource")

    refute inspect(Map.from_struct(error)) =~ "private-raw-error-body"
  end

  test "identifies the public operation on timeout and dropped connections without replay" do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    assert {:error,
            %Error{kind: :transport, code: "timeout", operation: :get_public_incoming_payment}} =
             IncomingPayment.get_public(client, "https://wallet.example.com/resource")

    base = HTTPServer.start(fn _ -> :close end)
    {:ok, local} = Client.new_public(allow_http: true)

    assert {:error, %Error{kind: :transport, operation: :get_public_incoming_payment}} =
             IncomingPayment.get_public(local, base <> "/resource")

    assert_receive {:http_request, %{target: "/resource"}}
    refute_receive {:http_request, _}, 30
  end

  test "does not follow redirects or retry server errors" do
    base =
      HTTPServer.start(fn request ->
        status = if request.target == "/redirect", do: 302, else: 503
        {status, [{"location", "/other"}], "failed"}
      end)

    {:ok, client} = Client.new_public(allow_http: true)

    for {status, target} <- [{302, "/redirect"}, {503, "/unavailable"}] do
      assert {:error,
              %Error{kind: :http, status: ^status, operation: :get_public_incoming_payment}} =
               IncomingPayment.get_public(client, base <> target)

      assert_receive {:http_request, %{target: ^target}}
      refute_receive {:http_request, _}, 30
    end
  end

  defp respond(status, body) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body)}
    end)
  end
end
