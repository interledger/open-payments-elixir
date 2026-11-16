defmodule OpenPayments.TransportTest do
  use ExUnit.Case, async: false

  alias MessageSignatures.Message
  alias OpenPayments.{Error, Key, Request, Response, Transport}
  alias OpenPayments.Test.{HTTPServer, TrackedPayload, TransportAdapter}

  @keys File.read!(Path.expand("../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()
  @created 1_618_884_473

  test "transmits the exact signed method, target, headers and JSON bytes" do
    base =
      HTTPServer.start(fn _ -> {200, [{"content-type", "application/json"}], ~s({"ok":true})} end)

    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")
    payload = %TrackedPayload{recipient: self(), value: "Café 🌍"}
    target = "/tenant/a/../quotes/%61?x=a%2Fb&x=2&cursor=%7e"

    {:ok, request} =
      Request.prepare(:post, base <> target,
        allow_http: true,
        key: key,
        access_token: "public-test-token",
        json: payload,
        created: @created
      )

    assert_received :payload_encoded

    assert {:ok, %Response{status: 200, body: ~s({"ok":true})}} = Transport.execute(request)
    assert_receive {:http_request, wire}
    assert wire.method == "POST"
    assert wire.target == target
    assert wire.body == request.body
    assert byte_size(wire.body) == 24
    assert Map.take(Map.new(wire.headers), Map.keys(request.headers)) == request.headers

    assert Map.new(wire.headers)["content-digest"] ==
             "sha-512=:#{Base.encode64(:crypto.hash(:sha512, wire.body))}:"

    assert {:ok, _} = verify(wire)
    refute_received :payload_encoded
  end

  test "normalizes empty queries before signing and preserves encoded queries and empty bodies" do
    base = HTTPServer.start(fn _ -> {204, [], ""} end)
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")

    for {target, transmitted} <- [
          {"/tenant?", "/tenant"},
          {"/tenant/%2F?x=one+two&x=%20", "/tenant/%2F?x=one+two&x=%20"}
        ],
        body <- [nil, ""] do
      {:ok, request} =
        Request.prepare(:post, base <> target,
          allow_http: true,
          key: key,
          body: body,
          created: @created
        )

      assert {:ok, %Response{status: 204, body: ""}} = Transport.execute(request)
      assert_receive {:http_request, wire}
      assert request.url == base <> transmitted
      assert wire.target == transmitted
      assert wire.body == ""
      assert {:ok, _} = verify(wire)
    end
  end

  test "transmits a matching IPv6 Host with its nondefault port" do
    base = HTTPServer.start(fn _ -> {200, [], "ok"} end, {0, 0, 0, 0, 0, 0, 0, 1})
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")

    {:ok, request} =
      Request.prepare(:get, base <> "/tenant",
        allow_http: true,
        key: key,
        access_token: "public-test-token",
        created: @created
      )

    assert {:ok, %Response{status: 200}} = Transport.execute(request)
    assert_receive {:http_request, wire}
    assert Map.new(wire.headers)["host"] == String.replace_prefix(base, "http://", "")
    assert {:ok, _} = verify(wire)
  end

  test "keeps public GET unsigned and transmits DELETE authorization" do
    base = HTTPServer.start(fn _ -> {200, [], "ok"} end)
    {:ok, request} = Request.prepare(:get, base <> "/wallet/alice", allow_http: true)
    assert {:ok, _} = Transport.execute(request)
    assert_receive {:http_request, wire}
    headers = Map.new(wire.headers)
    refute Map.has_key?(headers, "authorization")
    refute Map.has_key?(headers, "signature")

    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")

    {:ok, request} =
      Request.prepare(:delete, base <> "/tenant/token/manage",
        allow_http: true,
        key: key,
        access_token: "public-test-token",
        created: @created
      )

    assert {:ok, _} = Transport.execute(request)
    assert_receive {:http_request, wire}
    assert wire.method == "DELETE"
    assert Map.new(wire.headers)["authorization"] == "GNAP public-test-token"
    assert {:ok, _} = verify(wire)
  end

  test "returns raw response bytes, duplicate headers, and all HTTP status classes" do
    gzip = :zlib.gzip(~s({"private":"response"}))

    base =
      HTTPServer.start(fn _ ->
        {200,
         [
           {"content-type", "application/json"},
           {"content-encoding", "gzip"},
           {"set-cookie", "a=1"},
           {"set-cookie", "b=2"}
         ], gzip}
      end)

    {:ok, request} = Request.prepare(:get, base, allow_http: true)
    assert {:ok, response} = Transport.execute(request)
    assert response.body == gzip
    assert Enum.sort(for {"set-cookie", value} <- response.headers, do: value) == ["a=1", "b=2"]
    assert response.trailers == []
    refute inspect(response) =~ "a=1"

    for {status, body} <- [
          {202, "not JSON"},
          {204, ""},
          {400, "bad input"},
          {500, "server error"}
        ] do
      adapter(fn req -> {req, Req.Response.new(status: status, body: body)} end)

      assert {:ok, %Response{status: ^status, body: ^body}} =
               Transport.execute(request, adapter: TransportAdapter)
    end
  end

  test "does not follow redirects or retry failed mutation responses" do
    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/start" -> {307, [{"location", "/follow"}], "redirect"}
          "/busy" -> {503, [{"retry-after", "0"}], "busy"}
          "/follow" -> {200, [], "followed"}
        end
      end)

    {:ok, request} = Request.prepare(:post, base <> "/start", allow_http: true, json: %{})
    assert {:ok, %Response{status: 307}} = Transport.execute(request)
    assert_receive {:http_request, %{target: "/start"}}
    refute_receive {:http_request, _}, 30

    {:ok, request} = Request.prepare(:post, base <> "/busy", allow_http: true, json: %{})
    assert {:ok, %Response{status: 503}} = Transport.execute(request)
    assert_receive {:http_request, %{target: "/busy"}}
    refute_receive {:http_request, _}, 30
  end

  test "does not replay a mutation after the server reads it and closes the connection" do
    base = HTTPServer.start(fn _ -> :close end)
    {:ok, request} = Request.prepare(:post, base <> "/mutation", allow_http: true, json: %{})
    assert {:error, %Error{kind: :transport}} = Transport.execute(request)
    assert_receive {:http_request, %{target: "/mutation"}}
    refute_receive {:http_request, _}, 30
  end

  test "returns receive timeouts and connection failures without retrying" do
    base =
      HTTPServer.start(fn _ ->
        Process.sleep(100)
        {200, [], "late"}
      end)

    {:ok, request} = Request.prepare(:get, base, allow_http: true)

    assert {:error, %Error{kind: :transport, code: "timeout"}} =
             Transport.execute(request, receive_timeout: 20)

    assert_receive {:http_request, _}
    refute_receive {:http_request, _}, 30

    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    {:ok, request} = Request.prepare(:get, "http://127.0.0.1:#{port}", allow_http: true)
    assert {:error, %Error{kind: :transport, code: "econnrefused"}} = Transport.execute(request)
  end

  test "handles malformed HTTP responses and closed connections safely" do
    base = HTTPServer.start(fn _ -> {:raw, "not HTTP private-server-detail\r\n\r\n"} end)
    {:ok, request} = Request.prepare(:get, base, allow_http: true)
    assert {:error, %Error{kind: :transport} = error} = Transport.execute(request)
    assert error.details == nil
    refute inspect(Map.from_struct(error)) =~ "private-server-detail"
  end

  test "uses finite per-call timeouts and a bare Req request with no built-in steps" do
    {:ok, prepared} = Request.prepare(:get, "https://wallet.example.com/alice")

    adapter(fn req ->
      assert req.request_steps == []
      assert req.response_steps == []
      assert req.error_steps == []
      assert req.options.connect_options == [timeout: 123]
      assert req.options.receive_timeout == 456
      assert req.options.request_timeout == 789
      assert req.options.pool_timeout == 321
      {req, Req.Response.new(body: "ok")}
    end)

    assert {:ok, _} =
             Transport.execute(prepared,
               adapter: TransportAdapter,
               connect_timeout: 123,
               receive_timeout: 456,
               request_timeout: 789,
               pool_timeout: 321
             )
  end

  test "ignores global Req options that could mutate signed requests" do
    original = Req.default_options()
    on_exit(fn -> Req.default_options(original) end)

    Req.default_options(
      params: [injected: "value"],
      json: %{"changed" => true},
      retry: :safe_transient,
      redirect: true,
      auth: {:bearer, "global-secret"}
    )

    {:ok, prepared} = Request.prepare(:get, "https://wallet.example.com/alice?original=1")

    adapter(fn req ->
      assert URI.to_string(req.url) == prepared.url
      assert req.body == nil
      refute Map.has_key?(req.options, :auth)
      {req, Req.Response.new(body: "ok")}
    end)

    assert {:ok, _} = Transport.execute(prepared, adapter: TransportAdapter)
  end

  test "validates transport options before invoking the adapter" do
    {:ok, request} = Request.prepare(:get, "https://wallet.example.com/alice")
    adapter(fn _ -> flunk("invalid options must not invoke adapter") end)

    for opts <- [nil, %{}, [unknown: true], [receive_timeout: 1, receive_timeout: 2]] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :options}]}} =
               Transport.execute(request, opts)
    end

    for field <- [:connect_timeout, :receive_timeout, :request_timeout, :pool_timeout],
        value <- [nil, 0, -1, :infinity, "100", 1.5] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Transport.execute(request, [{field, value}, {:adapter, TransportAdapter}])
    end

    for value <- [nil, "adapter", URI, fn req -> req end] do
      assert {:error, %Error{validation_errors: [%{field: :adapter}]}} =
               Transport.execute(request, adapter: value)
    end

    assert {:error, %Error{validation_errors: [%{field: :request}]}} = Transport.execute(nil)
  end

  test "redacts adapter errors and exceptions and response inspection" do
    {:ok, request} =
      Request.prepare(:get, "https://wallet.example.com/?private-query-must-not-leak")

    for reason <- [:nxdomain, {:tls_alert, "private-server-detail-must-not-leak"}] do
      adapter(fn req -> {req, %Req.TransportError{reason: reason}} end)

      assert {:error, %Error{kind: :transport} = error} =
               Transport.execute(request, adapter: TransportAdapter)

      refute inspect(Map.from_struct(error)) =~ "must-not-leak"
    end

    adapter(fn _ -> raise "private-exception-must-not-leak" end)

    assert {:error, %Error{kind: :transport} = error} =
             Transport.execute(request, adapter: TransportAdapter)

    refute inspect(Map.from_struct(error)) =~ "must-not-leak"

    response = %Response{
      status: 200,
      body: "private-body",
      headers: [{"secret", "private-header"}],
      trailers: []
    }

    refute inspect(response) =~ "private"
  end

  defp adapter(callback), do: Process.put({TransportAdapter, :callback}, callback)

  defp verify(wire) do
    public = Base.url_decode64!(@keys["public_jwk"]["x"], padding: false)
    url = "http://" <> Map.new(wire.headers)["host"] <> wire.target
    message = Message.from_request(method: wire.method, url: url, headers: wire.headers)

    required =
      ~w(@method @target-uri) ++
        if(Map.has_key?(Map.new(wire.headers), "content-digest"),
          do: ~w(content-digest content-length content-type),
          else: []
        )

    MessageSignatures.verify(message,
      key_resolver: fn _, _ -> {:ok, {:ed25519, public}} end,
      now: @created,
      policy: [required_components: required]
    )
  end
end
