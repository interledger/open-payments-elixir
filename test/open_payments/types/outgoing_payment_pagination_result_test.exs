defmodule OpenPayments.Types.OutgoingPaymentPaginationResultTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}

  alias OpenPayments.Types.{
    Amount,
    OutgoingPayment,
    OutgoingPaymentPaginationResult,
    OutgoingPaymentWithSpentAmounts,
    PageInfo
  }

  @pagination %{"hasNextPage" => false, "hasPreviousPage" => false}
  @amount %{"value" => "250", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => "https://resource.example.com/outgoing-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "failed" => false,
    "debitAmount" => @amount,
    "receiveAmount" => @amount,
    "sentAmount" => %{"value" => "0", "assetCode" => "USD", "assetScale" => 2},
    "createdAt" => "2026-11-18T09:20:50Z"
  }
  @wire %{"pagination" => @pagination, "result" => [@payment]}

  test "pins the list response and records Node's required wrapper and strict referenced items" do
    schema =
      Specification.document(:resource)["paths"]["/outgoing-payments"]["get"]["responses"]["200"][
        "content"
      ]["application/json"]["schema"]

    assert schema["type"] == "object"
    assert Enum.sort(Map.keys(schema["properties"])) == ~w(pagination result)
    refute Map.has_key?(schema, "required")
    refute Map.has_key?(schema, "additionalProperties")
    assert schema["properties"]["pagination"] == %{"$ref" => "#/components/schemas/page-info"}

    assert schema["properties"]["result"] == %{
             "type" => "array",
             "items" => %{
               "$ref" => "#/components/schemas/outgoing-payment"
             }
           }

    {:ok, details} = Specification.fetch_schema(:resource, "outgoing-payment")

    assert details["type"] == "object"
    assert details["additionalProperties"] == false
    refute Map.has_key?(details, "allOf")
  end

  test "round trips every official forward/backward list example with typed metadata and items" do
    examples =
      Specification.document(:resource)["paths"]["/outgoing-payments"]["get"]["responses"]["200"][
        "content"
      ]["application/json"]["examples"]

    assert Enum.sort(Map.keys(examples)) == ["backward pagination", "forward pagination"]

    for {_name, %{"value" => wire}} <- examples do
      assert {:ok,
              %OutgoingPaymentPaginationResult{pagination: %PageInfo{}, result: payments} = page} =
               OutgoingPaymentPaginationResult.from_map(wire)

      assert Enum.all?(payments, fn payment ->
               match?(
                 %OutgoingPayment{
                   debit_amount: %Amount{},
                   receive_amount: %Amount{},
                   sent_amount: %Amount{}
                 },
                 payment
               )
             end)

      assert Enum.map(payments, & &1.id) == Enum.map(wire["result"], & &1["id"])
      assert :ok = OutgoingPaymentPaginationResult.validate(page)
      assert OutgoingPaymentPaginationResult.to_map(page) == wire
      assert Jason.decode!(Jason.encode!(page)) == wire
    end
  end

  test "permits an empty page with typed metadata and never synthesizes cursors" do
    wire = %{"pagination" => @pagination, "result" => []}
    assert {:ok, page} = OutgoingPaymentPaginationResult.from_map(wire)
    assert page.result == []
    assert page.pagination.start_cursor == nil and page.pagination.end_cursor == nil
    assert :ok = OutgoingPaymentPaginationResult.validate(page)
    assert OutgoingPaymentPaginationResult.to_map(page) == wire
  end

  test "requires both wrapper fields following Node rather than defaulting missing or null values" do
    for {wire, field} <- [
          {Map.delete(@wire, "pagination"), :pagination},
          {Map.put(@wire, "pagination", nil), :pagination},
          {Map.delete(@wire, "result"), :result},
          {Map.put(@wire, "result", nil), :result}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               OutgoingPaymentPaginationResult.from_map(wire)
    end

    assert {:error, %Error{validation_errors: errors}} =
             OutgoingPaymentPaginationResult.from_map(%{})

    assert Enum.map(errors, & &1.field) == [:pagination, :result]
  end

  test "rejects malformed roots and result containers without retaining rejected values" do
    for root <- [nil, false, 1, "private-root", [], %URI{}] do
      assert {:error,
              %Error{validation_errors: [%{field: :outgoing_payment_pagination_result}]} = error} =
               OutgoingPaymentPaginationResult.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-root"
    end

    for result <- [false, "private-result", %{}, 1, [@payment | :invalid_tail]] do
      assert {:error, %Error{validation_errors: [%{field: :result}]} = error} =
               OutgoingPaymentPaginationResult.from_map(%{@wire | "result" => result})

      refute inspect(Map.from_struct(error)) =~ "private-result"
    end

    {:ok, typed} = OutgoingPaymentPaginationResult.from_map(@wire)

    assert {:error, %Error{validation_errors: [%{field: :outgoing_payment_pagination_result}]}} =
             OutgoingPaymentPaginationResult.from_map(typed)
  end

  test "delegates page metadata rules with safe prefixed field paths" do
    for {metadata, field} <- [
          {Map.delete(@pagination, "hasNextPage"), "pagination.has_next_page"},
          {Map.put(@pagination, "startCursor", ""), "pagination.start_cursor"},
          {Map.put(@pagination, "endCursor", nil), "pagination.end_cursor"},
          {Map.put(@pagination, "private-name", "private-value"), :pagination}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               OutgoingPaymentPaginationResult.from_map(%{@wire | "pagination" => metadata})

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "collects item failures at their original indexes and prefixes nested data errors" do
    wire = %{
      @wire
      | "result" => [
          nil,
          %{@payment | "sentAmount" => %{@amount | "value" => "private-amount"}},
          Map.put(@payment, "metadata", "private-metadata")
        ]
    }

    assert {:error, %Error{kind: :validation, validation_errors: errors} = error} =
             OutgoingPaymentPaginationResult.from_map(wire)

    assert Enum.map(errors, & &1.field) == [
             "result[0]",
             "result[1].sent_amount.value",
             "result[2].metadata"
           ]

    refute inspect(Map.from_struct(error)) =~ "private-"

    for {payment, field} <- [
          {Map.delete(@payment, "receiveAmount"), "result[0].receive_amount"},
          {Map.put(@payment, "walletAddress", nil), "result[0].wallet_address"},
          {Map.put(@payment, "failed", nil), "result[0].failed"},
          {Map.put(@payment, "quoteId", nil), "result[0].quote_id"},
          {Map.put(@payment, "createdAt", "2026-02-29T00:00:00Z"), "result[0].created_at"},
          {Map.put(@payment, "debitAmount", %{@amount | "assetScale" => 256}),
           "result[0].debit_amount.asset_scale"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               OutgoingPaymentPaginationResult.from_map(%{@wire | "result" => [payment]})
    end
  end

  test "rejects undeclared and spent item fields using the strict detailed schema" do
    for {field, value} <- [
          {"updatedAt", "private-time"},
          {"grantSpentDebitAmount", @amount},
          {"grantSpentReceiveAmount", @amount},
          {"wallet_address", "private-wallet"},
          {"private-field", "private-value"}
        ] do
      payment = Map.put(@payment, field, value)

      assert {:error, %Error{validation_errors: [%{field: :outgoing_payment}]}} =
               OutgoingPayment.from_map(payment)

      assert {:error, %Error{validation_errors: [%{field: "result[0]"}]} = error} =
               OutgoingPaymentPaginationResult.from_map(%{@wire | "result" => [payment]})

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves allowed wrapper, metadata and amount extensions without treating nested names as reserved" do
    payment =
      Map.merge(@payment, %{
        "sentAmount" => Map.put(@amount, "custom", [true, nil]),
        "metadata" => %{
          "grantSpentDebitAmount" => "private-metadata",
          "pagination" => %{"result" => []}
        }
      })

    wire =
      @wire
      |> Map.put("result", [payment])
      |> Map.put("custom", %{"nested" => [nil, false, 1]})
      |> Map.put("next", "private-extension")

    assert {:ok, page} = OutgoingPaymentPaginationResult.from_map(wire)
    assert page.extensions == Map.take(wire, ["custom", "next"])
    assert hd(page.result).sent_amount.extensions == %{"custom" => [true, nil]}
    assert :ok = OutgoingPaymentPaginationResult.validate(page)
    assert Jason.decode!(Jason.encode!(page)) == wire

    for bad <- [%{"custom" => self()}, %{"custom" => <<255>>}, %{custom: true}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               OutgoingPaymentPaginationResult.from_map(Map.merge(@wire, bad))
    end
  end

  test "preserves item order and duplicates without inferring relationships from pagination metadata" do
    second =
      Map.merge(@payment, %{
        "failed" => true,
        "sentAmount" => %{@amount | "value" => "0000"}
      })

    metadata =
      Map.merge(@pagination, %{
        "hasNextPage" => true,
        "hasPreviousPage" => true,
        "startCursor" => "z",
        "endCursor" => "a"
      })

    wire = %{"pagination" => metadata, "result" => [second, @payment, second]}
    assert {:ok, page} = OutgoingPaymentPaginationResult.from_map(wire)
    assert Enum.map(page.result, & &1.failed) == [true, false, true]
    assert :ok = OutgoingPaymentPaginationResult.validate(page)
    assert OutgoingPaymentPaginationResult.to_map(page) == wire
    assert {:ok, _} = OutgoingPaymentPaginationResult.from_map(%{wire | "result" => []})
  end

  test "keeps asset, amount and failed consistency rules outside the pure page codec without filling defaults" do
    for payment <- [
          %{@payment | "sentAmount" => %{@amount | "assetCode" => "EUR", "assetScale" => 3}},
          %{@payment | "sentAmount" => %{@amount | "value" => "18446744073709551615"}},
          %{@payment | "sentAmount" => @amount, "failed" => true},
          Map.delete(@payment, "failed"),
          Map.merge(@payment, %{
            "quoteId" => "urn:example:quote",
            "metadata" => %{},
            "createdAt" => "2020-01-01T00:00:00Z",
            "receiveAmount" => %{@amount | "value" => "0000", "assetCode" => "JPY"}
          })
        ] do
      wire = %{@wire | "result" => [payment]}
      assert {:ok, page} = OutgoingPaymentPaginationResult.from_map(wire)
      assert :ok = OutgoingPaymentPaginationResult.validate(page)
      assert OutgoingPaymentPaginationResult.to_map(page) == wire
    end
  end

  test "revalidates typed metadata/items/nested amounts and rejects maps or other response types" do
    {:ok, page} = OutgoingPaymentPaginationResult.from_map(@wire)
    [payment] = page.result
    {:ok, with_spent} = OutgoingPaymentWithSpentAmounts.from_map(@payment)

    for {invalid, field} <- [
          {%{page | pagination: @pagination}, :pagination},
          {%{page | pagination: %{page.pagination | end_cursor: ""}}, "pagination.end_cursor"},
          {%{page | result: nil}, :result},
          {%{page | result: [@payment]}, "result[0]"},
          {%{page | result: [with_spent]}, "result[0]"},
          {%{
             page
             | result: [
                 %{
                   payment
                   | sent_amount: %{payment.sent_amount | value: "private-amount"}
                 }
               ]
           }, "result[0].sent_amount.value"},
          {%{
             page
             | result: [%{payment | receive_amount: %{payment.receive_amount | asset_scale: 256}}]
           }, "result[0].receive_amount.asset_scale"},
          {%{page | result: [%{payment | debit_amount: @amount}]}, "result[0].debit_amount"},
          {%{page | result: [%{payment | quote_id: "private-relative"}]}, "result[0].quote_id"},
          {%{page | extensions: %{"pagination" => "private-value"}}, :extensions},
          {%{page | extensions: []}, :extensions}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               OutgoingPaymentPaginationResult.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "inspection hides page payloads and explicit exports remain unvalidated and authoritative" do
    wire =
      @wire
      |> Map.put("pagination", Map.put(@pagination, "startCursor", "private-cursor"))
      |> Map.put("private-field", "private-extension")
      |> Map.put("result", [Map.put(@payment, "metadata", %{"private-memo" => "private-value"})])

    {:ok, page} = OutgoingPaymentPaginationResult.from_map(wire)
    refute inspect(page) =~ "private-"
    refute inspect(page) =~ @payment["id"]
    assert OutgoingPaymentPaginationResult.to_map(page) == wire
    assert Jason.decode!(Jason.encode!(page)) == wire

    invalid = %{
      page
      | pagination: %{page.pagination | has_next_page: nil},
        extensions: Map.put(page.extensions, "result", "private-shadow")
    }

    assert {:error, _} = OutgoingPaymentPaginationResult.validate(invalid)
    exported = OutgoingPaymentPaginationResult.to_map(invalid)
    assert exported["pagination"]["hasNextPage"] == nil
    assert exported["result"] == wire["result"]
    assert Jason.decode!(Jason.encode!(invalid)) == exported
  end
end
