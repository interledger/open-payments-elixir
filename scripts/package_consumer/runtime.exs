{:ok, _apps} = Application.ensure_all_started(:open_payments_elixir)
17 = length(OpenPayments.Specification.operations())
{:ok, amount} = OpenPayments.Types.Amount.new("1", "USD", 2)

%{"value" => "1", "assetCode" => "USD", "assetScale" => 2} =
  amount |> Jason.encode!() |> Jason.decode!()

{:ok, spent} =
  OpenPayments.Types.OutgoingPaymentGrantSpentAmounts.from_map(%{
    "spentReceiveAmount" => nil,
    "spentDebitAmount" => nil
  })

%{"spentReceiveAmount" => nil, "spentDebitAmount" => nil} =
  spent |> Jason.encode!() |> Jason.decode!()

IO.puts("Production consumer starts with bundled specifications and consolidated JSON encoders")
