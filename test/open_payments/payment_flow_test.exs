defmodule OpenPayments.PaymentFlowTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{
    Client,
    Error,
    Grant,
    IncomingPayment,
    Interaction,
    Key,
    OutgoingPayment,
    Quote,
    Token,
    WalletAddress
  }

  alias OpenPayments.Test.HTTPServer
  alias OpenPayments.Types.{Amount, CreateOutgoingPayment, CreateQuote, GrantResponse, Pagination}

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @debit %{"value" => "2600", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @created "2026-11-18T09:20:50Z"
  @client_nonce "flow-client-nonce"
  @server_nonce "flow-server-nonce"
  @interact_ref "flow-interaction-ref"

  for form <- [:quote, :direct] do
    test "completes discovery, authorization, #{form} payment and cleanup through public APIs" do
      ctx = prepare_flow()
      approved = approve_sender(ctx)

      {:ok, quoted} =
        Quote.create(
          ctx.client,
          ctx.sender.resource_server,
          %CreateQuote{wallet_address: ctx.sender.id, receiver: ctx.incoming.id, method: "ilp"},
          access_token: approved.access_token
        )

      assert quoted.receive_amount.asset_code == ctx.receiver.asset_code
      assert quoted.debit_amount.asset_code == ctx.sender.asset_code

      assert {:ok, ^quoted} =
               Quote.get(ctx.client, quoted.id, access_token: approved.access_token)

      {:ok, rotated} = Token.rotate(ctx.client, approved.access_token)

      assert {:error, %Error{kind: :http, status: 401}} =
               OutgoingPayment.get_grant_spent_amounts(ctx.client, ctx.sender.resource_server,
                 access_token: approved.access_token
               )

      request = outgoing_request(unquote(form), ctx, quoted)

      {:ok, created} =
        OutgoingPayment.create(ctx.client, ctx.sender.resource_server, request,
          access_token: rotated.access_token
        )

      {:ok, fetched} =
        OutgoingPayment.get(ctx.client, created.id, access_token: rotated.access_token)

      assert fetched.sent_amount == fetched.debit_amount
      assert fetched.receive_amount == ctx.incoming.incoming_amount
      assert fetched.metadata == request.metadata

      {:ok, page} =
        OutgoingPayment.list(ctx.client, ctx.sender.resource_server, ctx.sender.id,
          access_token: rotated.access_token,
          pagination: %Pagination{first: 1}
        )

      assert page.result == [fetched]

      {:ok, spent} =
        OutgoingPayment.get_grant_spent_amounts(ctx.client, ctx.sender.resource_server,
          access_token: rotated.access_token
        )

      assert spent.spent_debit_amount == created.grant_spent_debit_amount
      assert spent.spent_receive_amount == created.grant_spent_receive_amount

      {:ok, completed} =
        IncomingPayment.complete(ctx.client, ctx.incoming.id,
          access_token: ctx.receiver_grant.access_token
        )

      assert completed.completed
      assert completed.received_amount == completed.incoming_amount

      {:ok, incoming_page} =
        IncomingPayment.list(ctx.client, ctx.receiver.resource_server, ctx.receiver.id,
          access_token: ctx.receiver_grant.access_token
        )

      assert incoming_page.result == [completed]

      assert :ok = Token.revoke(ctx.client, rotated.access_token)

      assert {:error, %Error{kind: :http, status: 401}} =
               OutgoingPayment.get_grant_spent_amounts(ctx.client, ctx.sender.resource_server,
                 access_token: rotated.access_token
               )

      assert :ok = Grant.cancel(ctx.client, approved.continue)
      assert :ok = Grant.cancel(ctx.client, ctx.receiver_grant.continue)

      requests = drain_requests()
      assert length(requests) == 24
      assert count(requests, "POST", "/tenant/sender/outgoing-payments") == 1
      assert count(requests, "POST", "/continue/sender/1") == 1
      assert count(requests, "DELETE", "/continue/sender/2") == 1
      assert count(requests, "DELETE", "/manage/sender/2") == 1
      refute Enum.any?(requests, &String.starts_with?(&1.target, "/consent"))
      refute_receive {:http_request, _}, 20
    end
  end

  test "the application rejects a mismatched callback before continuing or creating a payment" do
    ctx = prepare_flow()
    {:ok, pending} = sender_grant(ctx)
    assert GrantResponse.pending?(pending)
    drain_requests()
    hash = callback_hash(ctx.sender.auth_server)

    assert {:error, %Error{operation: :verify_interaction_hash, code: "invalid_interaction_hash"}} =
             continue_after_callback(ctx, pending, hash, "changed-reference")

    refute_receive {:http_request, _}, 20
    assert :ok = Grant.cancel(ctx.client, pending.continue)
    assert :ok = Grant.cancel(ctx.client, ctx.receiver_grant.continue)
    assert Enum.all?(drain_requests(), &(&1.method == "DELETE"))
  end

  for failure <- [:drop, :invalid_response] do
    test "reconciles #{failure} after server-side creation without an automatic second payment" do
      ctx = prepare_flow(unquote(failure))
      approved = approve_sender(ctx)
      drain_requests()
      {:ok, debit} = Amount.from_map(@debit)

      request = %CreateOutgoingPayment{
        wallet_address: ctx.sender.id,
        incoming_payment: ctx.incoming.id,
        debit_amount: debit
      }

      assert {:error, %Error{operation: :create_outgoing_payment} = error} =
               OutgoingPayment.create(ctx.client, ctx.sender.resource_server, request,
                 access_token: approved.access_token
               )

      assert error.kind == if(unquote(failure) == :drop, do: :transport, else: :decoding)
      requests = drain_requests()
      assert count(requests, "POST", "/tenant/sender/outgoing-payments") == 1
      assert length(requests) == 1
      refute_receive {:http_request, _}, 30

      # Reconciliation is an explicit application decision, using a separate GET.
      {:ok, page} =
        OutgoingPayment.list(ctx.client, ctx.sender.resource_server, ctx.sender.id,
          access_token: approved.access_token
        )

      assert length(page.result) == 1

      {:ok, spent} =
        OutgoingPayment.get_grant_spent_amounts(ctx.client, ctx.sender.resource_server,
          access_token: approved.access_token
        )

      assert spent.spent_debit_amount == hd(page.result).debit_amount
      assert Enum.all?(drain_requests(), &(&1.method == "GET"))
    end
  end

  defp prepare_flow(failure \\ :none) do
    base =
      HTTPServer.start(fn request ->
        verify_request(request)
        route(request, failure)
      end)

    {:ok, public} = Client.new_public(allow_http: true)
    {:ok, sender} = WalletAddress.get(public, base <> "/wallets/sender")
    {:ok, key} = Key.from_seed(@seed, "flow-key-1")

    {:ok, client} =
      Client.new_authenticated(wallet_address: sender.id, key: key, allow_http: true)

    {:ok, receiver} = WalletAddress.get(client, base <> "/wallets/receiver")

    for wallet <- [sender, receiver] do
      {:ok, jwks} = WalletAddress.get_keys(client, wallet.id)
      assert hd(jwks.keys).x == Base.url_encode64(@public, padding: false)
    end

    {:ok, grant} =
      Grant.request(client, receiver.auth_server, %{
        "access_token" => %{
          "access" => [
            %{
              "type" => "incoming-payment",
              "actions" => ["create", "read", "complete", "list"],
              "identifier" => receiver.id
            }
          ]
        }
      })

    assert GrantResponse.approved?(grant)

    {:ok, incoming} =
      IncomingPayment.create(
        client,
        receiver.resource_server,
        %{"walletAddress" => receiver.id, "incomingAmount" => @receive},
        access_token: grant.access_token
      )

    {:ok, ^incoming} = IncomingPayment.get(client, incoming.id, access_token: grant.access_token)
    {:ok, advertised} = IncomingPayment.get_public(client, incoming.id)
    assert advertised.auth_server == receiver.auth_server
    assert advertised.incoming_amount == incoming.incoming_amount
    assert advertised.received_amount.value == "0"

    %{
      client: client,
      sender: sender,
      receiver: receiver,
      receiver_grant: grant,
      incoming: incoming
    }
  end

  defp sender_grant(ctx) do
    Grant.request(ctx.client, ctx.sender.auth_server, %{
      "access_token" => %{
        "access" => [
          %{"type" => "quote", "actions" => ["create", "read"]},
          %{
            "type" => "outgoing-payment",
            "actions" => ["create", "read", "list"],
            "identifier" => ctx.sender.id
          }
        ]
      },
      "interact" => %{
        "start" => ["redirect"],
        "finish" => %{
          "method" => "redirect",
          "uri" => "https://client.example.com/callback",
          "nonce" => @client_nonce
        }
      }
    })
  end

  defp approve_sender(ctx) do
    {:ok, pending} = sender_grant(ctx)
    assert GrantResponse.pending?(pending)
    assert pending.continue.wait == 0

    {:ok, approved} =
      continue_after_callback(ctx, pending, callback_hash(ctx.sender.auth_server), @interact_ref)

    assert approved.access_token.value == "sender-resource-1"
    assert approved.continue.uri != pending.continue.uri
    approved
  end

  # Application orchestration: callback verification must succeed before HTTP continuation.
  defp continue_after_callback(ctx, pending, hash, reference) do
    with :ok <-
           Interaction.verify_hash(hash,
             client_nonce: @client_nonce,
             server_nonce: pending.interact.finish,
             interact_ref: reference,
             grant_endpoint: ctx.sender.auth_server
           ) do
      Grant.continue(ctx.client, pending.continue, %{"interact_ref" => reference})
    end
  end

  # Independent callback source: four LF-separated fields, no SDK hash helper.
  defp callback_hash(endpoint),
    do:
      :sha256
      |> :crypto.hash(Enum.join([@client_nonce, @server_nonce, @interact_ref, endpoint], "\n"))
      |> Base.encode64()

  defp outgoing_request(:quote, ctx, quoted),
    do: %CreateOutgoingPayment{
      wallet_address: ctx.sender.id,
      quote_id: quoted.id,
      metadata: %{"order" => "Café 🌍"}
    }

  defp outgoing_request(:direct, ctx, quoted),
    do: %CreateOutgoingPayment{
      wallet_address: ctx.sender.id,
      incoming_payment: ctx.incoming.id,
      debit_amount: quoted.debit_amount,
      metadata: %{"order" => "Café 🌍"}
    }

  # This simulator models protocol state only, not ILP settlement or an ASE implementation.
  defp route(%{method: "GET", target: "/wallets/" <> suffix} = request, _failure) do
    base = origin(request)

    case String.split(suffix, "/") do
      [role] ->
        json(200, %{
          "id" => base <> "/wallets/" <> role,
          "assetCode" => if(role == "sender", do: "USD", else: "EUR"),
          "assetScale" => 2,
          "authServer" => base <> "/auth/" <> role,
          "resourceServer" => base <> "/tenant/" <> role
        })

      [_role, "jwks.json"] ->
        json(200, %{
          "keys" => [
            %{
              "kid" => "flow-key-1",
              "alg" => "EdDSA",
              "kty" => "OKP",
              "crv" => "Ed25519",
              "x" => Base.url_encode64(@public, padding: false)
            }
          ]
        })
    end
  end

  defp route(%{method: "POST", target: "/auth/" <> role} = request, _failure) do
    payload = Jason.decode!(request.body)
    assert payload["client"] == origin(request) <> "/wallets/sender"
    access = payload["access_token"]["access"]
    Process.put({:access, role}, access)
    response = %{"continue" => continuation(request, role, 1)}

    if role == "receiver" do
      Process.put({:token, role}, "receiver-resource-1")
      json(200, Map.put(response, "access_token", issued_token(request, role, 1)))
    else
      assert payload["interact"]["finish"]["nonce"] == @client_nonce

      json(
        200,
        Map.put(response, "interact", %{
          "redirect" => origin(request) <> "/consent/sender",
          "finish" => @server_nonce
        })
      )
    end
  end

  defp route(%{method: "POST", target: "/continue/sender/1"} = request, _failure) do
    assert authorized?(request, "sender-continue-1")
    assert Jason.decode!(request.body) == %{"interact_ref" => @interact_ref}
    Process.put({:token, "sender"}, "sender-resource-1")

    json(200, %{
      "continue" => continuation(request, "sender", 2),
      "access_token" => issued_token(request, "sender", 1)
    })
  end

  defp route(%{method: "DELETE", target: "/continue/" <> suffix} = request, _failure) do
    [role, version] = String.split(suffix, "/")
    assert authorized?(request, role <> "-continue-" <> version)
    assert request.body == ""
    {204, [], ""}
  end

  defp route(%{method: "POST", target: "/manage/sender/1"} = request, _failure) do
    assert authorized?(request, "sender-resource-1")
    assert request.body == ""
    Process.put({:token, "sender"}, "sender-resource-2")
    json(200, %{"access_token" => issued_token(request, "sender", 2)})
  end

  defp route(%{method: "DELETE", target: "/manage/sender/2"} = request, _failure) do
    assert authorized?(request, "sender-resource-2")
    assert request.body == ""
    Process.put({:token, "sender"}, nil)
    {204, [], ""}
  end

  defp route(%{method: "POST", target: "/tenant/receiver/incoming-payments"} = request, _failure) do
    assert authorized?(request, "receiver-resource-1")
    payload = Jason.decode!(request.body)
    assert payload["walletAddress"] == origin(request) <> "/wallets/receiver"
    assert payload["incomingAmount"] == @receive

    incoming = %{
      "id" => origin(request) <> "/tenant/receiver/incoming-payments/in-1",
      "walletAddress" => payload["walletAddress"],
      "incomingAmount" => @receive,
      "receivedAmount" => %{@receive | "value" => "0"},
      "completed" => false,
      "createdAt" => @created,
      "methods" => [
        %{"type" => "ilp", "ilpAddress" => "test.receiver", "sharedSecret" => "test-secret"}
      ]
    }

    Process.put(:incoming, incoming)
    json(201, incoming)
  end

  defp route(
         %{method: "GET", target: "/tenant/receiver/incoming-payments/in-1"} = request,
         _failure
       ) do
    incoming = Process.get(:incoming)

    if Map.has_key?(Map.new(request.headers), "authorization") do
      assert authorized?(request, "receiver-resource-1")
      json(200, incoming)
    else
      json(
        200,
        incoming
        |> Map.delete("walletAddress")
        |> Map.put("authServer", origin(request) <> "/auth/receiver")
      )
    end
  end

  defp route(
         %{method: "POST", target: "/tenant/receiver/incoming-payments/in-1/complete"} = request,
         _failure
       ) do
    assert authorized?(request, "receiver-resource-1")
    incoming = Map.put(Process.get(:incoming), "completed", true)
    Process.put(:incoming, incoming)
    json(200, Map.delete(incoming, "methods"))
  end

  defp route(
         %{method: "GET", target: "/tenant/receiver/incoming-payments?" <> query} = request,
         _failure
       ) do
    assert authorized?(request, "receiver-resource-1")

    assert URI.decode_query(query) == %{
             "wallet-address" => origin(request) <> "/wallets/receiver"
           }

    json(200, page(Map.delete(Process.get(:incoming), "methods")))
  end

  defp route(%{method: "POST", target: "/tenant/sender/quotes"} = request, _failure) do
    assert authorized?(request, Process.get({:token, "sender"}))
    payload = Jason.decode!(request.body)
    assert payload["receiver"] == Process.get(:incoming)["id"]
    assert payload["method"] == "ilp"

    quoted = %{
      "id" => origin(request) <> "/tenant/sender/quotes/q-1",
      "walletAddress" => payload["walletAddress"],
      "receiver" => payload["receiver"],
      "debitAmount" => @debit,
      "receiveAmount" => @receive,
      "method" => "ilp",
      "createdAt" => @created
    }

    Process.put(:quote, quoted)
    json(201, quoted)
  end

  defp route(%{method: "GET", target: "/tenant/sender/quotes/q-1"} = request, _failure) do
    assert authorized?(request, Process.get({:token, "sender"}))
    json(200, Process.get(:quote))
  end

  defp route(%{method: "POST", target: "/tenant/sender/outgoing-payments"} = request, failure) do
    assert authorized?(request, Process.get({:token, "sender"}))
    refute Process.get(:outgoing), "an automatic replay would create a second payment"
    payload = Jason.decode!(request.body)
    receiver = Process.get(:incoming)["id"]
    assert payload["walletAddress"] == origin(request) <> "/wallets/sender"

    if Map.has_key?(payload, "quoteId") do
      assert payload["quoteId"] == Process.get(:quote)["id"]
    else
      assert payload["incomingPayment"] == receiver
      assert payload["debitAmount"] == @debit
    end

    outgoing = %{
      "id" => origin(request) <> "/tenant/sender/outgoing-payments/out-1",
      "walletAddress" => payload["walletAddress"],
      "receiver" => receiver,
      "debitAmount" => @debit,
      "receiveAmount" => @receive,
      "sentAmount" => @debit,
      "failed" => false,
      "createdAt" => @created
    }

    outgoing =
      if Map.has_key?(payload, "metadata"),
        do: Map.put(outgoing, "metadata", payload["metadata"]),
        else: outgoing

    Process.put(:outgoing, outgoing)
    Process.put(:incoming, Map.put(Process.get(:incoming), "receivedAmount", @receive))

    case failure do
      :drop ->
        :close

      :invalid_response ->
        json(201, %{"id" => outgoing["id"]})

      :none ->
        json(
          201,
          Map.merge(outgoing, %{
            "grantSpentDebitAmount" => @debit,
            "grantSpentReceiveAmount" => @receive
          })
        )
    end
  end

  defp route(
         %{method: "GET", target: "/tenant/sender/outgoing-payments/out-1"} = request,
         _failure
       ) do
    assert authorized?(request, Process.get({:token, "sender"}))
    json(200, Process.get(:outgoing))
  end

  defp route(
         %{method: "GET", target: "/tenant/sender/outgoing-payments?" <> query} = request,
         _failure
       ) do
    assert authorized?(request, Process.get({:token, "sender"}))
    assert URI.decode_query(query)["wallet-address"] == origin(request) <> "/wallets/sender"
    json(200, page(Process.get(:outgoing)))
  end

  defp route(
         %{method: "GET", target: "/tenant/sender/outgoing-payment-grant"} = request,
         _failure
       ) do
    if authorized?(request, Process.get({:token, "sender"})) do
      json(200, %{"spentReceiveAmount" => @receive, "spentDebitAmount" => @debit})
    else
      json(401, %{"error" => "invalid_token"})
    end
  end

  defp continuation(request, role, version),
    do: %{
      "uri" => origin(request) <> "/continue/" <> role <> "/#{version}",
      "wait" => 0,
      "access_token" => %{"value" => role <> "-continue-#{version}"}
    }

  defp issued_token(request, role, version),
    do: %{
      "value" => role <> "-resource-#{version}",
      "manage" => origin(request) <> "/manage/" <> role <> "/#{version}",
      "access" => Process.get({:access, role})
    }

  defp authorized?(_request, nil), do: false

  defp authorized?(request, value),
    do: Map.new(request.headers)["authorization"] == "GNAP " <> value

  defp origin(request), do: "http://" <> Map.new(request.headers)["host"]

  defp json(status, body),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(body)}

  defp page(payment),
    do: %{
      "pagination" => %{"hasNextPage" => false, "hasPreviousPage" => false},
      "result" => [payment]
    }

  defp verify_request(request) do
    headers = Map.new(request.headers)

    public? =
      request.method == "GET" and
        (String.starts_with?(request.target, "/wallets/") or
           (request.target == "/tenant/receiver/incoming-payments/in-1" and
              not Map.has_key?(headers, "authorization")))

    if public? do
      refute Map.has_key?(headers, "authorization")
      refute Map.has_key?(headers, "signature")
      refute Map.has_key?(headers, "signature-input")
    else
      verify_signature(request, headers)
    end
  end

  # Reconstruct the Node-profile signature base from received bytes, independently
  # of the SDK signer, message_signatures verifier and private-key export helpers.
  defp verify_signature(request, headers) do
    auth = if Map.has_key?(headers, "authorization"), do: ["authorization"], else: []

    content =
      if request.body == "", do: [], else: ["content-digest", "content-length", "content-type"]

    components = ["@method", "@target-uri"] ++ auth ++ content
    "sig1=" <> params = headers["signature-input"]

    prefix =
      "(" <> Enum.map_join(components, " ", &~s("#{&1}")) <> ~s|);keyid="flow-key-1";created=|

    assert String.starts_with?(params, prefix)
    assert Regex.match?(~r/\A[0-9]+\z/, String.replace_prefix(params, prefix, ""))

    if content != [] do
      assert headers["content-digest"] ==
               "sha-512=:#{Base.encode64(:crypto.hash(:sha512, request.body))}:"

      assert headers["content-length"] == Integer.to_string(byte_size(request.body))
      assert headers["content-type"] == "application/json"
    end

    base =
      Enum.map_join(components, "\n", fn
        "@method" -> ~s("@method": #{request.method})
        "@target-uri" -> ~s("@target-uri": #{origin(request)}#{request.target})
        name -> ~s("#{name}": #{headers[name]})
      end) <> "\n" <> ~s("@signature-params": #{params})

    [_, signature] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])
    assert :crypto.verify(:eddsa, :none, base, Base.decode64!(signature), [@public, :ed25519])
  end

  defp count(requests, method, path),
    do: Enum.count(requests, &(&1.method == method and URI.parse(&1.target).path == path))

  defp drain_requests do
    receive do
      {:http_request, request} -> [request | drain_requests()]
    after
      0 -> []
    end
  end
end
