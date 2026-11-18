defmodule OpenPayments.OutgoingPaymentGrantSpentAmountsTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Key, OutgoingPayment, Specification, Token}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, ContinuationToken}
  alias OpenPayments.Types.OutgoingPaymentGrantSpentAmounts, as: SpentData

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @url "https://resource.example.com/tenant"
  @debit %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @spent %{"spentReceiveAmount" => @receive, "spentDebitAmount" => @debit}

  test "matches the pinned grant GET and decodes both official amount and null examples" do
    operation = Enum.find(Specification.operations(), &(&1.id == "get-outgoing-payment-grant"))
    assert operation.method == :get and operation.server == :resource
    assert operation.success_statuses == [200]

    content =
      Specification.document(:resource)["paths"]["/outgoing-payment-grant"]["get"]["responses"][
        "200"
      ]["content"]["application/json"]

    assert Enum.sort(content["schema"]["required"]) == ~w(spentDebitAmount spentReceiveAmount)
    assert map_size(content["examples"]) == 2

    for {_name, %{"value" => wire}} <- content["examples"] do
      respond(200, Jason.encode!(wire))

      assert {:ok, %SpentData{} = spent} =
               OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), @url,
                 access_token: token()
               )

      assert SpentData.to_map(spent) == wire
    end
  end

  test "signs exact bodyless grant GETs with raw/typed tokens and no filter or related lookups" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@spent)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "grant-spent-1"})
    prefix = "/tenant/opaque%2fresource/../tenant"
    target = prefix <> "/outgoing-payment-grant"
    original = client

    for {supplied, suffix} <- [{"test-resource-token", ""}, {token(), "/"}] do
      assert {:ok, spent} =
               OutgoingPayment.get_grant_spent_amounts(client, base <> prefix <> suffix,
                 access_token: supplied
               )

      assert SpentData.to_map(spent) == @spent
      assert_receive {:http_request, wire}
      assert wire.method == "GET" and wire.target == target and wire.body == ""
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["accept"] == "application/json" and headers["accept-encoding"] == "identity"
      assert headers["x-request-id"] == "grant-spent-1"
      refute Map.has_key?(headers, "content-digest")
      refute Map.has_key?(headers, "content-type")
      refute Map.has_key?(headers, "content-length")
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

  test "preserves root/tenant bases and HTTPS ports and retrieves fresh decreasing totals with per-call tokens" do
    client = client(adapter: TransportAdapter)

    for {base, expected} <- [
          {"https://RESOURCE.example.com", "https://resource.example.com/outgoing-payment-grant"},
          {"https://resource.example.com/",
           "https://resource.example.com/outgoing-payment-grant"},
          {"https://resource.example.com:8443/tenant/",
           "https://resource.example.com:8443/tenant/outgoing-payment-grant"},
          {"https://resource.example.com/tenant//",
           "https://resource.example.com/tenant//outgoing-payment-grant"}
        ],
        {value, access} <- [{"200", "first-token"}, {"100", "second-token"}] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == expected
        assert Req.Request.get_header(request, "authorization") == ["GNAP " <> access]
        wire = %{@spent | "spentDebitAmount" => %{@debit | "value" => value}}
        {request, Req.Response.new(body: Jason.encode!(wire))}
      end)

      assert {:ok, spent} =
               OutgoingPayment.get_grant_spent_amounts(client, base, access_token: access)

      assert spent.spent_debit_amount.value == value
    end
  end

  test "requires a valid authenticated client and one supported per-call token option" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :get_outgoing_payment_grant}} =
               OutgoingPayment.get_grant_spent_amounts(invalid, @url, access_token: "test-token")
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
      assert {:error, %Error{kind: :validation, operation: :get_outgoing_payment_grant} = error} =
               OutgoingPayment.get_grant_spent_amounts(client, @url, opts)

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
                operation: :get_outgoing_payment_grant,
                validation_errors: [%{field: ^field}]
              } = error} =
               OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), @url,
                 access_token: supplied
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "rejects invalid resource-server bases and any query marker before HTTP" do
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
          @url <> "?",
          @url <> "?part=1",
          "https://resource.example.com:65536/id"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :get_outgoing_payment_grant,
                validation_errors: [%{field: :url}]
              }} =
               OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), url,
                 access_token: "test-token"
               )
    end
  end

  test "preserves independent null/zero/asset data and extensions without inferring interval, budget or token state" do
    client = client(adapter: TransportAdapter)
    supplied = %{token() | expires_in: -1}
    zero = %{@debit | "value" => "0000"}

    for wire <- [
          @spent,
          %{"spentReceiveAmount" => nil, "spentDebitAmount" => nil},
          %{"spentReceiveAmount" => nil, "spentDebitAmount" => zero},
          %{"spentReceiveAmount" => @receive, "spentDebitAmount" => nil},
          %{
            "spentReceiveAmount" => %{
              @receive
              | "value" => "18446744073709551615",
                "assetScale" => 255
            },
            "spentDebitAmount" => zero,
            "private-extension" => %{"interval" => "uninterpreted"}
          }
        ] do
      respond(200, Jason.encode!(wire), [{"content-type", "text/plain"}])

      assert {:ok, spent} =
               OutgoingPayment.get_grant_spent_amounts(client, @url, access_token: supplied)

      assert SpentData.to_map(spent) == wire
      refute inspect(spent) =~ "private-"
    end
  end

  test "classifies malformed JSON, unsupported encoding and wrong success statuses safely" do
    for {status, body, headers, code} <- [
          {200, "private-invalid-json", [], "invalid_json"},
          {201, Jason.encode!(@spent), [], "unexpected_status"},
          {204, "", [], "unexpected_status"},
          {200, "null", [], "invalid_response"},
          {200, "{}", [], "invalid_response"},
          {200, Jason.encode!(@spent), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :get_outgoing_payment_grant
              } = error} =
               OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "requires both nullable fields and reports safe nested amount errors at status200" do
    for {wire, field} <- [
          {Map.delete(@spent, "spentReceiveAmount"), :spent_receive_amount},
          {Map.delete(@spent, "spentDebitAmount"), :spent_debit_amount},
          {%{"grantSpentReceiveAmount" => @receive, "grantSpentDebitAmount" => @debit},
           :spent_receive_amount},
          {Map.put(@spent, "spentReceiveAmount", false), :spent_receive_amount},
          {%{@spent | "spentDebitAmount" => %{@debit | "value" => "private-amount"}},
           "spent_debit_amount.value"},
          {%{@spent | "spentReceiveAmount" => %{@receive | "assetScale" => 256}},
           "spent_receive_amount.asset_scale"},
          {%{@spent | "spentReceiveAmount" => %{@receive | "value" => "18446744073709551616"}},
           "spent_receive_amount.value"}
        ] do
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :get_outgoing_payment_grant,
                validation_errors: [%{field: ^field}]
              } = error} =
               OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      assert error.description ==
               "Invalid Open Payments outgoing-payment grant spent-amount response"

      refute inspect(Map.from_struct(error)) =~ "private-"
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
                operation: :get_outgoing_payment_grant
              }} =
               OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not follow redirects or replay server, dropped-connection or timeout failures" do
    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/redirect/outgoing-payment-grant" -> {302, [{"location", "/other"}], ""}
          "/unavailable/outgoing-payment-grant" -> {503, [], "failed"}
          "/dropped/outgoing-payment-grant" -> :close
        end
      end)

    for {path, kind, status} <- [
          {"/redirect", :http, 302},
          {"/unavailable", :http, 503},
          {"/dropped", :transport, nil}
        ] do
      assert {:error,
              %Error{kind: ^kind, status: ^status, operation: :get_outgoing_payment_grant}} =
               OutgoingPayment.get_grant_spent_amounts(client(allow_http: true), base <> path,
                 access_token: "test-token"
               )

      target = path <> "/outgoing-payment-grant"
      assert_receive {:http_request, %{method: "GET", target: ^target}}
      refute_receive {:http_request, _}, 30
    end

    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), :attempt)
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error,
            %Error{kind: :transport, code: "timeout", operation: :get_outgoing_payment_grant}} =
             OutgoingPayment.get_grant_spent_amounts(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "isolates grant tokens and resource-server bases during concurrent reads on a shared client" do
    base =
      HTTPServer.start(fn request ->
        value = String.replace_prefix(Map.new(request.headers)["authorization"], "GNAP ", "")
        wire = Map.put(@spent, "echo", value)
        {200, [], Jason.encode!(wire)}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"] do
        {value,
         Task.async(fn ->
           OutgoingPayment.get_grant_spent_amounts(client, base <> "/" <> value,
             access_token: value
           )
         end)}
      end

    for {value, task} <- tasks do
      assert {:ok, spent} = Task.await(task)
      assert spent.extensions["echo"] == value
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}
      value = String.replace_prefix(Map.new(wire.headers)["authorization"], "GNAP ", "")
      assert wire.target == "/" <> value <> "/outgoing-payment-grant"
      assert verify_wire(wire)
    end
  end

  test "uses the newly rotated token on an explicit grant-spent read without management URL inference" do
    base =
      HTTPServer.start(fn request ->
        headers = Map.new(request.headers)

        case {request.method, request.target} do
          {"POST", "/manage"} ->
            assert headers["authorization"] == "GNAP test-resource-token"

            response = %{
              "access_token" => %{
                "value" => "rotated-resource-token",
                "manage" => "http://" <> headers["host"] <> "/manage/rotated",
                "access" => []
              }
            }

            {200, [], Jason.encode!(response)}

          {"GET", "/tenant/outgoing-payment-grant"} ->
            assert headers["authorization"] == "GNAP rotated-resource-token"
            {200, [], Jason.encode!(@spent)}
        end
      end)

    client = client(allow_http: true)
    original = %{token() | manage: base <> "/manage"}
    assert {:ok, rotated} = Token.rotate(client, original)
    assert_receive {:http_request, %{method: "POST", target: "/manage"} = rotation_wire}
    assert verify_wire(rotation_wire)
    refute_receive {:http_request, _}, 20

    assert {:ok, spent} =
             OutgoingPayment.get_grant_spent_amounts(client, base <> "/tenant",
               access_token: rotated.access_token
             )

    assert SpentData.to_map(spent) == @spent
    assert original.value == "test-resource-token"

    assert_receive {:http_request,
                    %{method: "GET", target: "/tenant/outgoing-payment-grant", body: ""} =
                      read_wire}

    assert verify_wire(read_wire)
    refute_receive {:http_request, _}, 20
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
