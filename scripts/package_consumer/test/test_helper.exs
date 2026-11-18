ExUnit.start()

defmodule PackageConsumer.Adapter do
  @moduledoc false
  def run(request), do: Process.get({__MODULE__, :reply}).(request)
end
