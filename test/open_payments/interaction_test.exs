defmodule OpenPayments.InteractionTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Grant, Interaction, Key}
  alias OpenPayments.Test.TransportAdapter
  alias OpenPayments.Types.{InteractionFinish, InteractionResponse}

  @fixture File.read!(Path.expand("../fixtures/interaction/sha256.json", __DIR__))
           |> Jason.decode!()
  @fields ~w(client_nonce server_nonce interact_ref grant_endpoint)a
  @first hd(@fixture["vectors"])
  @context Enum.map(@fields, fn field -> {field, @first["inputs"][Atom.to_string(field)]} end)

  test "matches the published GNAP SHA-256 base64url vector" do
    expected = "x-gguKWTj8rQf7d7i3w3UhzvuJ5bpOlKyAlVpLxBffY"
    assert @first["hashes"]["base64url"] == expected
    assert {:ok, ^expected} = Interaction.hash(@context ++ [encoding: :base64url])
    assert :ok = Interaction.verify_hash(expected, @context ++ [encoding: :base64url])
  end

  test "matches independently generated Node vectors for both explicit encodings and the default" do
    assert length(@fixture["vectors"]) >= 2

    for vector <- @fixture["vectors"] do
      context = context(vector["inputs"])
      assert {:ok, hash} = Interaction.hash(context)
      assert hash == vector["hashes"]["base64"]

      for encoding <- [:base64, :base64url] do
        expected = vector["hashes"][Atom.to_string(encoding)]
        assert {:ok, ^expected} = Interaction.hash(context ++ [encoding: encoding])
        assert :ok = Interaction.verify_hash(expected, context ++ [encoding: encoding])
      end
    end
  end

  test "uses ordered newline-separated fields without a trailing newline or CRLF conversion" do
    for encoding <- [:base64, :base64url], {_name, wrong} <- @fixture["incorrect_bases"] do
      wrong_hash = wrong[Atom.to_string(encoding)]

      assert {:error, %Error{code: "invalid_interaction_hash"}} =
               Interaction.verify_hash(wrong_hash, @context ++ [encoding: encoding])
    end
  end

  test "preserves URI spelling and does not substitute callback or continuation endpoints" do
    for endpoint <- [
          "https://server.example.com/tx/",
          "https://Server.Example.COM/tx",
          "https://server.example.com:443/tx",
          "https://server.example.com/callback",
          "https://server.example.com/continue/id"
        ] do
      changed = Keyword.put(@context, :grant_endpoint, endpoint)
      assert {:ok, hash} = Interaction.hash(changed)
      refute hash == @first["hashes"]["base64"]

      assert {:error, %Error{code: "invalid_interaction_hash"}} =
               Interaction.verify_hash(@first["hashes"]["base64"], changed)
    end
  end

  test "binds every context component and compares canonically encoded equal-length hashes" do
    for field <- @fields do
      changed = Keyword.update!(@context, field, &(&1 <> "changed"))

      assert {:error,
              %Error{
                kind: :validation,
                operation: :verify_interaction_hash,
                code: "invalid_interaction_hash",
                validation_errors: [%{field: :hash}]
              }} = Interaction.verify_hash(@first["hashes"]["base64"], changed)
    end

    for encoding <- [:base64, :base64url] do
      expected = @first["hashes"][Atom.to_string(encoding)]
      replacement = if String.starts_with?(expected, "A"), do: "B", else: "A"
      wrong = replacement <> binary_part(expected, 1, byte_size(expected) - 1)

      assert {:error, %Error{code: "invalid_interaction_hash"}} =
               Interaction.verify_hash(wrong, @context ++ [encoding: encoding])
    end
  end

  test "rejects missing, empty, control, non-ASCII and edge-whitespace nonce/reference values" do
    for field <- ~w(client_nonce server_nonce interact_ref)a do
      for value <- [
            nil,
            1,
            false,
            [],
            "",
            "private\nvalue",
            "private\rvalue",
            "private\tvalue",
            "private\0value",
            "private🌍value",
            <<255>>,
            " private-value",
            "private-value "
          ] do
        assert {:error,
                %Error{
                  operation: :calculate_interaction_hash,
                  validation_errors: [%{field: ^field}]
                } = error} = Interaction.hash(Keyword.put(@context, field, value))

        refute inspect(Map.from_struct(error)) =~ "private"
      end

      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Interaction.hash(Keyword.delete(@context, field))
    end
  end

  test "retains internal ASCII spaces without trimming or guessing reference formats" do
    context = [
      client_nonce: "client nonce",
      server_nonce: "server nonce",
      interact_ref: "opaque reference/value",
      grant_endpoint: "http://localhost:3006/tenant"
    ]

    assert {:ok, hash} = Interaction.hash(context)
    assert :ok = Interaction.verify_hash(hash, context)

    assert {:error, %Error{code: "invalid_interaction_hash"}} =
             Interaction.verify_hash(
               hash,
               Keyword.put(context, :interact_ref, "opaque  reference/value")
             )
  end

  test "validates option shape, unique known names and encoding without negotiating algorithms" do
    for opts <- [
          nil,
          %{},
          [:bad],
          [{"client_nonce", "value"}],
          @context ++ [client_nonce: "private-value"],
          @context ++ [unknown: "private-value"],
          @context ++ [hash_method: "sha3-512"]
        ] do
      assert {:error,
              %Error{
                operation: :calculate_interaction_hash,
                validation_errors: [%{field: :options}]
              } = error} = Interaction.hash(opts)

      refute inspect(Map.from_struct(error)) =~ "private-value"

      assert {:error, %Error{operation: :verify_interaction_hash}} =
               Interaction.verify_hash(@first["hashes"]["base64"], opts)
    end

    for encoding <- [nil, "base64", :auto, :sha256, false] do
      assert {:error, %Error{validation_errors: [%{field: :encoding}]}} =
               Interaction.hash(@context ++ [encoding: encoding])
    end
  end

  test "requires a valid absolute HTTP(S) grant endpoint without fetching or normalizing it" do
    for endpoint <- [
          nil,
          1,
          "",
          "/auth",
          "$auth.example.com",
          "urn:example:grant",
          "ftp://auth.example.com",
          "https://user@auth.example.com/tx",
          "https://auth.example.com/tx#fragment",
          "https://auth.example.com:65536/tx",
          "https://auth.example.com/%xx"
        ] do
      assert {:error, %Error{validation_errors: [%{field: :grant_endpoint}]}} =
               Interaction.hash(Keyword.put(@context, :grant_endpoint, endpoint))
    end

    assert {:error, %Error{validation_errors: [%{field: :grant_endpoint}]}} =
             Interaction.hash(Keyword.delete(@context, :grant_endpoint))
  end

  test "rejects malformed, wrong-length and noncanonical callback hashes before equality comparison" do
    for encoding <- [:base64, :base64url] do
      expected = @first["hashes"][Atom.to_string(encoding)]
      size = byte_size(expected)

      noncanonical =
        String.duplicate("A", 42) <> "B" <> if(encoding == :base64, do: "=", else: "")

      invalid = [
        nil,
        [],
        1,
        false,
        "",
        "private-hash",
        expected <> "=",
        binary_part(expected, 0, size - 1),
        String.duplicate("%", size),
        noncanonical,
        :binary.copy(<<255>>, size)
      ]

      invalid =
        if encoding == :base64,
          do: [Base.encode64(:binary.copy(<<0>>, 31)) | invalid],
          else: invalid

      for value <- invalid do
        assert {:error,
                %Error{
                  operation: :verify_interaction_hash,
                  code: nil,
                  validation_errors: [%{field: :hash}]
                } = error} = Interaction.verify_hash(value, @context ++ [encoding: encoding])

        refute inspect(Map.from_struct(error)) =~ "private-hash"
      end
    end
  end

  test "requires the selected encoding without padded, alphabet or URL-decoding fallback" do
    base64 = @first["hashes"]["base64"]
    base64url = @first["hashes"]["base64url"]
    assert {:error, %Error{}} = Interaction.verify_hash(base64url, @context)

    assert {:error, %Error{}} =
             Interaction.verify_hash(base64, @context ++ [encoding: :base64url])

    assert {:error, %Error{}} = Interaction.verify_hash(URI.encode_www_form(base64), @context)

    assert {:error, %Error{}} =
             Interaction.verify_hash(String.replace(base64, "+", " "), @context)
  end

  test "reports only safe fields and does not retain contexts or hash values in errors" do
    context = Keyword.put(@context, :client_nonce, "private client nonce")

    assert {:error,
            %Error{
              kind: :validation,
              operation: :verify_interaction_hash,
              code: "invalid_interaction_hash",
              details: nil
            } = error} = Interaction.verify_hash(@first["hashes"]["base64"], context)

    refute inspect(Map.from_struct(error)) =~ "private"
    refute inspect(Map.from_struct(error)) =~ @first["hashes"]["base64"]
    refute inspect(Map.from_struct(error)) =~ @context[:server_nonce]
  end

  test "general JSON codecs retain their string contracts while hash inputs enforce ASCII requirements" do
    assert {:ok, _} =
             InteractionFinish.from_map(%{
               "method" => "redirect",
               "uri" => "https://client.example.com/callback",
               "nonce" => "Café 🌍"
             })

    assert {:ok, _} =
             InteractionResponse.from_map(%{
               "redirect" => "https://auth.example.com/consent",
               "finish" => ""
             })

    assert {:error, %Error{}} = Interaction.hash(Keyword.put(@context, :client_nonce, "Café 🌍"))
    assert {:error, %Error{}} = Interaction.hash(Keyword.put(@context, :server_nonce, ""))
  end

  test "verified callback gates continuation while mismatch makes no continuation request" do
    {:ok, key} = Key.from_seed(:binary.copy(<<1>>, 32), "test-key")

    {:ok, client} =
      Client.new_authenticated(
        wallet_address: "https://client.example.com/alice",
        key: key,
        adapter: TransportAdapter
      )

    continuation = %{
      "uri" => "https://auth.example.com/resume",
      "access_token" => %{"value" => "test-continuation-token"}
    }

    pending = %{
      "continue" => continuation,
      "interact" => %{
        "redirect" => "https://auth.example.com/consent",
        "finish" => @context[:server_nonce]
      }
    }

    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), :grant_requested)
      {request, Req.Response.new(body: Jason.encode!(pending))}
    end)

    payload = %{
      "access_token" => %{"access" => []},
      "interact" => %{
        "start" => ["redirect"],
        "finish" => %{
          "method" => "redirect",
          "uri" => "https://client.example.com/callback",
          "nonce" => @context[:client_nonce]
        }
      }
    }

    assert {:ok, grant} = Grant.request(client, @context[:grant_endpoint], payload)
    assert_received :grant_requested
    context = Keyword.put(@context, :server_nonce, grant.interact.finish)

    Process.put({TransportAdapter, :callback}, fn request ->
      assert Jason.decode!(request.body) == %{"interact_ref" => context[:interact_ref]}
      send(self(), :grant_continued)
      {request, Req.Response.new(body: Jason.encode!(%{"continue" => continuation}))}
    end)

    result =
      with :ok <-
             Interaction.verify_hash(
               @first["hashes"]["base64"],
               Keyword.put(context, :interact_ref, "changed-reference")
             ),
           do: Grant.continue(client, grant.continue, %{"interact_ref" => "changed-reference"})

    assert {:error, %Error{code: "invalid_interaction_hash"}} = result
    refute_received :grant_continued

    result =
      with :ok <- Interaction.verify_hash(@first["hashes"]["base64"], context),
           do: Grant.continue(client, grant.continue, %{"interact_ref" => context[:interact_ref]})

    assert {:ok, _} = result
    assert_received :grant_continued
    refute_received :grant_continued
  end

  defp context(inputs),
    do: Enum.map(@fields, fn field -> {field, inputs[Atom.to_string(field)]} end)
end
