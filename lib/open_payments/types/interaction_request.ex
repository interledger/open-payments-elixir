defmodule OpenPayments.Types.InteractionRequest do
  @moduledoc """
  Consent interaction preferences sent in a grant request's `interact` field.

  The pinned schema requires a `start` array whose entries are `redirect`. It
  does not require the array to be nonempty or unique. Optional `finish` becomes
  a typed `InteractionFinish`; omission becomes nil, while explicit null is invalid.
  Additional JSON fields are preserved in `extensions` at both object levels.

  Inspection omits the callback and extensions. Map/JSON export includes callback
  nonces. This type does not generate nonces, open a consent page, verify callback
  hashes or continue a grant. Validate manually constructed or modified structs
  with `validate/1`; `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{InteractionFinish, Validation}

  @derive {Inspect, only: [:start]}
  @enforce_keys [:start]
  defstruct [:start, :finish, extensions: %{}]

  @wire_fields ~w(start finish)

  @type t :: %__MODULE__{
          start: [String.t()],
          finish: InteractionFinish.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes and validates grant interaction preferences and callback data."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, finish} <- decode_finish(data) do
      interaction = %__MODULE__{
        start: data["start"],
        finish: finish,
        extensions: Map.drop(data, @wire_fields)
      }

      case validate(interaction) do
        :ok -> {:ok, interaction}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:interaction_request, "must be a JSON object")])

  @doc "Validates a struct and its typed callback, treating nil finish as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = interaction) do
    errors =
      Enum.flat_map(
        [
          {start?(interaction.start), :start,
           "must be an array containing only redirect strings"},
          {Validation.extensions?(interaction.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved interaction fields"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors ++ finish_errors(interaction.finish) do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to protocol fields, including callback nonces, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = interaction) do
    fields = %{"start" => interaction.start}

    fields =
      if is_nil(interaction.finish),
        do: fields,
        else: Map.put(fields, "finish", InteractionFinish.to_map(interaction.finish))

    interaction.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp decode_finish(data) do
    case Map.fetch(data, "finish") do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case InteractionFinish.from_map(value) do
          {:ok, finish} -> {:ok, finish}
          {:error, error} -> invalid(prefix(error.validation_errors))
        end
    end
  end

  defp start?(start) when is_list(start), do: Enum.all?(start, &(&1 == "redirect"))
  defp start?(_start), do: false

  defp finish_errors(nil), do: []

  defp finish_errors(%InteractionFinish{} = finish) do
    case InteractionFinish.validate(finish) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors)
    end
  end

  defp finish_errors(_finish),
    do: [issue(:finish, "must be an InteractionFinish struct when present")]

  defp prefix(errors) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :interaction_finish, do: :finish, else: "finish.#{field}")}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments interaction request",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.InteractionRequest do
  def encode(interaction, opts) do
    interaction |> OpenPayments.Types.InteractionRequest.to_map() |> Jason.Encode.map(opts)
  end
end
