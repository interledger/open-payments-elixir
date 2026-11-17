defmodule OpenPayments.Types.OutgoingLimitsTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Amount, OutgoingLimits}

  @amount %{"value" => "500", "assetCode" => "USD", "assetScale" => 2}
  @receiver "https://wallet.example.com/tenant/incoming-payments/payment-1"
  @interval "R12/2019-08-24T14:15:22Z/P1M"

  test "matches pinned union branches, amount requirements, receiver pattern and interval string contract" do
    {:ok, schema} = Specification.fetch_schema(:auth, "limits-outgoing")

    assert schema["anyOf"] ==
             Enum.map(
               ~w(limits-outgoing-no-amount limits-outgoing-debit-amount limits-outgoing-receive-amount),
               &%{"$ref" => "#/components/schemas/#{&1}"}
             )

    for {name, required} <- [
          {"limits-outgoing-no-amount", []},
          {"limits-outgoing-debit-amount", ["debitAmount"]},
          {"limits-outgoing-receive-amount", ["receiveAmount"]}
        ] do
      {:ok, branch} = Specification.fetch_schema(:auth, name)
      assert Map.get(branch, "required", []) == required
      assert Map.get(branch, "additionalProperties", true) == true
      assert branch["properties"]["receiver"] == %{"$ref" => "#/components/schemas/receiver"}
      assert branch["properties"]["interval"] == %{"$ref" => "#/components/schemas/interval"}
    end

    {:ok, receiver} = Specification.fetch_schema(:auth, "receiver")
    assert receiver["format"] == "uri"
    assert receiver["pattern"] == "^(https|http)://(.+)/incoming-payments/(.+)$"
    {:ok, interval} = Specification.fetch_schema(:auth, "interval")
    assert interval["type"] == "string"
    refute Map.has_key?(interval, "format")
    refute Map.has_key?(interval, "pattern")
  end

  test "decodes outgoing limits from the official grant examples and round trips JSON" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    entries =
      for {_name, example} <- examples,
          access <- get_in(example, ["value", "access_token", "access"]) || [],
          limits = access["limits"],
          not is_nil(limits),
          do: limits

    assert entries != []

    for wire <- entries do
      assert {:ok, %OutgoingLimits{} = limits} = OutgoingLimits.from_map(wire)
      assert :ok = OutgoingLimits.validate(limits)
      assert OutgoingLimits.to_map(limits) == wire
      assert Jason.decode!(Jason.encode!(limits)) == wire
    end
  end

  test "supports empty, no-amount, debit and receive limits with omitted optional fields" do
    for wire <- [
          %{},
          %{"receiver" => @receiver},
          %{"interval" => @interval},
          %{"receiver" => @receiver, "interval" => @interval},
          %{"debitAmount" => @amount},
          %{"receiveAmount" => @amount}
        ] do
      assert {:ok, limits} = OutgoingLimits.from_map(wire)
      assert OutgoingLimits.to_map(limits) == wire
      assert :ok = OutgoingLimits.validate(limits)
      if Map.has_key?(wire, "debitAmount"), do: assert(%Amount{} = limits.debit_amount)
      if Map.has_key?(wire, "receiveAmount"), do: assert(%Amount{} = limits.receive_amount)
    end

    assert OutgoingLimits.to_map(%OutgoingLimits{}) == %{}
  end

  test "rejects null or malformed amounts and reports safe nested amount paths" do
    for {wire_field, field} <- [
          {"debitAmount", :debit_amount},
          {"receiveAmount", :receive_amount}
        ],
        value <- [nil, [], "500", 500] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               OutgoingLimits.from_map(%{wire_field => value})
    end

    for {wire_field, field} <- [
          {"debitAmount", "debit_amount.value"},
          {"receiveAmount", "receive_amount.value"}
        ],
        value <- ["18446744073709551616", "-1", "private-invalid-amount"] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               OutgoingLimits.from_map(%{wire_field => %{@amount | "value" => value}})

      refute inspect(Map.from_struct(error)) =~ "private-invalid-amount"
    end

    for value <- ["0", "000500", "18446744073709551615"] do
      wire = %{"debitAmount" => %{@amount | "value" => value}}
      assert {:ok, limits} = OutgoingLimits.from_map(wire)
      assert OutgoingLimits.to_map(limits) == wire
    end
  end

  test "rejects simultaneous debit and receive amounts in wire data and manual structs" do
    for wire <- [
          %{"debitAmount" => @amount, "receiveAmount" => @amount},
          %{"debitAmount" => nil, "receiveAmount" => @amount},
          %{"debitAmount" => @amount, "receiveAmount" => nil}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :limits}]}} =
               OutgoingLimits.from_map(wire)
    end

    {:ok, amount} = Amount.from_map(@amount)

    assert {:error, %Error{validation_errors: [%{field: :limits}]}} =
             OutgoingLimits.validate(%OutgoingLimits{
               debit_amount: amount,
               receive_amount: amount
             })
  end

  test "accepts the receiver examples, tenant paths, opaque identifiers and development URLs unchanged" do
    {:ok, schema} = Specification.fetch_schema(:auth, "receiver")

    for receiver <-
          schema["examples"] ++
            [
              @receiver,
              "https://Wallet.Example.COM:8443/tenant/incoming-payments/id%2Fvalue?part=1#state",
              "http://localhost:3000/tenant/incoming-payments/1"
            ] do
      assert {:ok, limits} = OutgoingLimits.from_map(%{"receiver" => receiver})
      assert limits.receiver == receiver
      assert OutgoingLimits.to_map(limits) == %{"receiver" => receiver}
    end
  end

  test "enforces the field-specific receiver URI pattern without converting wallet identifiers" do
    for receiver <- [
          nil,
          1,
          "",
          "/incoming-payments/payment-1",
          "$wallet.example.com/alice",
          "https://wallet.example.com/alice",
          "https://wallet.example.com/incoming-payments/",
          "https://wallet.example.com/other-payments/1",
          "ftp://wallet.example.com/incoming-payments/1",
          "https:///incoming-payments/1",
          "https://wallet.example.com/incoming-payments/%xx",
          "https://wallet.example.com/incoming-payments/1\n"
        ] do
      assert {:error, %Error{validation_errors: [%{field: :receiver}]}} =
               OutgoingLimits.from_map(%{"receiver" => receiver})
    end
  end

  test "preserves interval strings and schema examples without interpreting recurrences" do
    {:ok, schema} = Specification.fetch_schema(:auth, "interval")

    for interval <- schema["examples"] ++ [@interval, "", "provider-defined-interval"] do
      assert {:ok, limits} = OutgoingLimits.from_map(%{"interval" => interval})
      assert OutgoingLimits.to_map(limits) == %{"interval" => interval}
    end

    for interval <- [nil, 1, false, [], %{}, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :interval}]}} =
               OutgoingLimits.from_map(%{"interval" => interval})
    end
  end

  test "preserves permitted extensions at both limits and amount levels" do
    wire = %{
      "debitAmount" => Map.put(@amount, "custom-amount", [true, nil]),
      "custom-limits" => %{"value" => "retained"}
    }

    assert {:ok, limits} = OutgoingLimits.from_map(wire)
    assert limits.extensions == %{"custom-limits" => %{"value" => "retained"}}
    assert limits.debit_amount.extensions == %{"custom-amount" => [true, nil]}
    assert Jason.decode!(Jason.encode!(limits)) == wire

    for extensions <- [%{"debitAmount" => @amount}, %{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               OutgoingLimits.validate(%{limits | extensions: extensions})
    end
  end

  test "revalidates manual changes and omits nils without allowing reserved-field overrides" do
    {:ok, limits} =
      OutgoingLimits.from_map(%{
        "debitAmount" => @amount,
        "receiver" => @receiver,
        "interval" => @interval
      })

    for {changed, field} <- [
          {%{limits | debit_amount: @amount}, :debit_amount},
          {%{limits | debit_amount: %{limits.debit_amount | asset_scale: 256}},
           "debit_amount.asset_scale"},
          {%OutgoingLimits{receive_amount: @amount}, :receive_amount},
          {%OutgoingLimits{receive_amount: %{limits.debit_amount | value: "-1"}},
           "receive_amount.value"},
          {%{limits | receiver: "relative"}, :receiver},
          {%{limits | interval: false}, :interval}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               OutgoingLimits.validate(changed)
    end

    without_optionals = %{limits | receiver: nil, interval: nil, debit_amount: nil}
    assert :ok = OutgoingLimits.validate(without_optionals)
    assert OutgoingLimits.to_map(without_optionals) == %{}

    assert OutgoingLimits.to_map(%{limits | extensions: %{"receiver" => "override"}})["receiver"] ==
             @receiver
  end

  test "inspection hides amount and extension metadata without changing explicit exports" do
    wire = %{
      "receiveAmount" => Map.put(@amount, "custom", "private-amount-metadata"),
      "custom" => "private-extension"
    }

    {:ok, limits} = OutgoingLimits.from_map(wire)
    refute inspect(limits) =~ "private-"
    assert OutgoingLimits.to_map(limits) == wire
  end

  test "rejects non-objects and non-JSON extension input without retaining it" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :limits}]} = error} =
               OutgoingLimits.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for value <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               OutgoingLimits.from_map(value)
    end
  end
end
