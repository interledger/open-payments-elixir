defmodule OpenPayments.Error do
  @moduledoc """
  Structured errors returned by Open Payments operations and protocol validation.

  Validation issues identify a field and explain its constraint without retaining
  the rejected value. Inspection omits descriptions and arbitrary server details;
  applications should take care when logging those fields explicitly.
  """

  @derive {Inspect, only: [:kind, :status, :code, :operation, :validation_errors]}
  defexception kind: :validation,
               status: nil,
               code: nil,
               description: nil,
               details: nil,
               validation_errors: [],
               operation: nil

  @type kind :: :configuration | :validation | :signing | :transport | :http | :decoding
  @type validation_issue :: %{field: atom() | String.t(), message: String.t()}
  @type t :: %__MODULE__{
          kind: kind(),
          status: pos_integer() | nil,
          code: String.t() | nil,
          description: String.t() | nil,
          details: map() | nil,
          validation_errors: [validation_issue()],
          operation: atom() | nil
        }

  @impl true
  def message(%__MODULE__{description: description}) when is_binary(description), do: description
  def message(%__MODULE__{kind: kind}), do: "Open Payments #{kind} error"
end
