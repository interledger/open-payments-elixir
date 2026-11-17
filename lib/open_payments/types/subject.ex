defmodule OpenPayments.Types.Subject do
  @moduledoc """
  Subject information requested or returned by an authorization server.

  The pinned schema requires `sub_ids` to contain exactly one typed
  `SubjectIdentifier`. Missing, null, empty and multi-entry arrays are invalid.
  Additional JSON fields are retained in `extensions`. The wire name remains
  `sub_ids`; no camel-case alias is substituted.

  Inspection omits subject values and extensions; explicit map/JSON exports
  contain them. This data codec makes no requests and does not verify identity.
  Validate manually constructed or modified structs with `validate/1`;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{SubjectIdentifier, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:sub_ids]
  defstruct [:sub_ids, extensions: %{}]

  @wire_fields ~w(sub_ids)

  @type t :: %__MODULE__{
          sub_ids: [SubjectIdentifier.t()],
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes a subject object and its single identifier without resolving it."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, identifiers} <- identifiers(data["sub_ids"], &SubjectIdentifier.from_map/1) do
      subject = %__MODULE__{sub_ids: identifiers, extensions: Map.drop(data, @wire_fields)}

      case validate(subject) do
        :ok -> {:ok, subject}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:subject, "must be a JSON object")])

  @doc "Revalidates the single typed subject identifier and root extension fields."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = subject) do
    extension_errors =
      if Validation.extensions?(subject.extensions, @wire_fields),
        do: [],
        else: [
          issue(
            :extensions,
            "must be a JSON object with string keys and no reserved subject fields"
          )
        ]

    identifier_errors =
      case identifiers(subject.sub_ids, &validate_identifier/1) do
        {:ok, _identifiers} -> []
        {:error, error} -> error.validation_errors
      end

    case extension_errors ++ identifier_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to protocol fields, including subject identifiers, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = subject) do
    subject.extensions
    |> Map.drop(@wire_fields)
    |> Map.put("sub_ids", Enum.map(subject.sub_ids, &SubjectIdentifier.to_map/1))
  end

  defp identifiers([value], decoder) do
    case decoder.(value) do
      {:ok, identifier} -> {:ok, [identifier]}
      {:error, error} -> invalid(prefix(error.validation_errors))
    end
  end

  defp identifiers(_values, _decoder),
    do: invalid([issue(:sub_ids, "must be an array containing exactly one subject identifier")])

  defp validate_identifier(%SubjectIdentifier{} = identifier) do
    case SubjectIdentifier.validate(identifier) do
      :ok -> {:ok, identifier}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_identifier(_value),
    do: invalid([issue(:subject_identifier, "must be a SubjectIdentifier struct")])

  defp prefix(errors) do
    Enum.map(errors, fn %{field: field} = error ->
      %{
        error
        | field: if(field == :subject_identifier, do: "sub_ids[0]", else: "sub_ids[0].#{field}")
      }
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments subject information",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.Subject do
  def encode(subject, opts) do
    subject |> OpenPayments.Types.Subject.to_map() |> Jason.Encode.map(opts)
  end
end
