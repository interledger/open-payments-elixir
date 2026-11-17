defmodule OpenPayments.Types.InteractionResponse do
  @moduledoc """
  Interaction instructions in a pending grant response's `interact` field.

  Required `redirect` follows the schema's absolute-URI format and retains its
  spelling. Required `finish` is an opaque string used to secure the callback;
  this codec checks its type without imposing UUID, length or alphabet rules.
  Additional JSON fields are retained in `extensions`.

  Inspection omits redirect, finish and extension values. Explicit map/JSON
  exports include them. This type does not open the consent URI, generate callback
  values or verify a callback hash. Validate manually modified structs with
  `validate/1`; `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: []}
  @enforce_keys [:redirect, :finish]
  defstruct [:redirect, :finish, extensions: %{}]

  @wire_fields ~w(redirect finish)

  @type t :: %__MODULE__{
          redirect: String.t(),
          finish: String.t(),
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes interaction instructions without following the redirect or verifying a callback."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    interaction = %__MODULE__{
      redirect: data["redirect"],
      finish: data["finish"],
      extensions: Map.drop(data, @wire_fields)
    }

    case validate(interaction) do
      :ok -> {:ok, interaction}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:interaction_response, "must be a JSON object")])

  @doc "Revalidates typed interaction instructions without retaining rejected values in errors."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = interaction) do
    errors =
      Enum.flat_map(
        [
          {Validation.absolute_uri?(interaction.redirect), :redirect, "must be an absolute URI"},
          {Validation.string?(interaction.finish), :finish, "must be a string"},
          {Validation.extensions?(interaction.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved interaction response fields"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to protocol fields, including callback values, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = interaction) do
    interaction.extensions
    |> Map.drop(@wire_fields)
    |> Map.merge(%{"redirect" => interaction.redirect, "finish" => interaction.finish})
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments interaction response",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.InteractionResponse do
  def encode(interaction, opts) do
    interaction |> OpenPayments.Types.InteractionResponse.to_map() |> Jason.Encode.map(opts)
  end
end
