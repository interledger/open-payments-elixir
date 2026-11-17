defmodule OpenPayments.Types.SubjectIdentifier do
  @moduledoc """
  A subject identifier requested or returned in a grant's subject information.

  The pinned schema requires an `id` string and the format discriminator `uri`.
  The `id` property itself has no URI format/pattern constraint, so this codec
  checks its string type without imposing wallet discovery or request URL rules.
  Additional JSON fields are retained in `extensions`.

  Inspection omits the identifier and extensions. Explicit map/JSON export includes
  them. This type does not resolve a wallet, verify identity, or make requests.
  Validate manually constructed or modified structs with `validate/1`;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: [:format]}
  @enforce_keys [:id, :format]
  defstruct [:id, :format, extensions: %{}]

  @wire_fields ~w(id format)

  @type t :: %__MODULE__{
          id: String.t(),
          format: String.t(),
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes a subject identifier without interpreting or resolving its value."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    identifier = %__MODULE__{
      id: data["id"],
      format: data["format"],
      extensions: Map.drop(data, @wire_fields)
    }

    case validate(identifier) do
      :ok -> {:ok, identifier}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:subject_identifier, "must be a JSON object")])

  @doc "Validates the identifier, format discriminator and permitted extension data."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = identifier) do
    errors =
      Enum.flat_map(
        [
          {Validation.string?(identifier.id), :id, "must be a string"},
          {identifier.format == "uri", :format, "must be uri"},
          {Validation.extensions?(identifier.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved subject-identifier fields"}
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

  @doc "Converts to protocol fields, including the identifier, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = identifier) do
    identifier.extensions
    |> Map.drop(@wire_fields)
    |> Map.merge(%{"id" => identifier.id, "format" => identifier.format})
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments subject identifier",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.SubjectIdentifier do
  def encode(identifier, opts) do
    identifier |> OpenPayments.Types.SubjectIdentifier.to_map() |> Jason.Encode.map(opts)
  end
end
