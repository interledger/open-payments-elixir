defmodule OpenPayments.Types.GrantContinuationRequest do
  @moduledoc """
  The optional JSON payload for continuing a grant.

  The pinned schema permits an empty object or an optional `interact_ref` string.
  Omission becomes nil; explicit JSON null is rejected. Reference spelling is
  preserved without UUID, alphabet or length constraints. Additional JSON fields
  are retained in `extensions`. The wire name remains `interact_ref`.

  Unlike the Node SDK's TypeScript `Required` body type, this codec permits an
  empty object as declared by the shared schema. It models a JSON object only:
  `from_map(nil)` is invalid, while `OpenPayments.Grant.continue/2` omits the HTTP
  body separately. An empty struct exports as an empty JSON object.

  Inspection omits reference and extension values. Explicit map/JSON exports
  include them. This codec does not generate references, verify callback hashes,
  wait, poll or send requests. Use `validate/1` after modifying a struct;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: []}
  defstruct [:interact_ref, extensions: %{}]

  @wire_fields ["interact_ref"]

  @type t :: %__MODULE__{
          interact_ref: String.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes an optional interaction reference and permitted JSON extension fields."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    request = %__MODULE__{
      interact_ref: data["interact_ref"],
      extensions: Map.drop(data, @wire_fields)
    }

    case validate_fields(request, Map.has_key?(data, "interact_ref")) do
      :ok -> {:ok, request}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:grant_continuation_request, "must be a JSON object")])

  @doc "Revalidates typed payload data, treating a nil reference as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = request),
    do: validate_fields(request, not is_nil(request.interact_ref))

  @doc "Converts to protocol fields, including any interaction reference, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    fields =
      if is_nil(request.interact_ref), do: %{}, else: %{"interact_ref" => request.interact_ref}

    request.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp validate_fields(request, reference_present?) do
    errors =
      Enum.flat_map(
        [
          {not reference_present? or Validation.string?(request.interact_ref), :interact_ref,
           "must be a string when present"},
          {Validation.extensions?(request.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved continuation request fields"}
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

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments grant continuation request",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.GrantContinuationRequest do
  def encode(request, opts) do
    request |> OpenPayments.Types.GrantContinuationRequest.to_map() |> Jason.Encode.map(opts)
  end
end
