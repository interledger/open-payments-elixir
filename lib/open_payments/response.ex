defmodule OpenPayments.Response do
  @moduledoc false

  @derive {Inspect, only: [:status]}
  @enforce_keys [:status, :headers, :body, :trailers]
  defstruct [:status, :headers, :body, :trailers]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          trailers: [{String.t(), String.t()}]
        }
end
