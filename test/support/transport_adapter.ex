defmodule OpenPayments.Test.TransportAdapter do
  @moduledoc false

  def run(request), do: Process.get({__MODULE__, :callback}).(request)
end
