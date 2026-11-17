defmodule OpenPayments.Types.InteractionFinish do
  @moduledoc """
  A grant interaction request's completion callback configuration.

  The pinned schema requires method `redirect`, an absolute callback `uri` and a
  string `nonce`. Additional JSON fields are preserved in `extensions`.
  The caller must supply a unique, unguessable nonce for each grant request;
  this data codec checks its type without generating or assessing its randomness.

  URI spelling is preserved without HTTP request-target restrictions. Inspection
  omits the nonce and extensions; explicit map/JSON exports include them for the
  protocol. This type does not follow redirects or verify a callback hash.

  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` converts its shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: [:method, :uri]}
  @enforce_keys [:method, :uri, :nonce]
  defstruct [:method, :uri, :nonce, extensions: %{}]

  @wire_fields ~w(method uri nonce)

  @type t :: %__MODULE__{
          method: String.t(),
          uri: String.t(),
          nonce: String.t(),
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes and validates interaction callback configuration."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    finish = %__MODULE__{
      method: data["method"],
      uri: data["uri"],
      nonce: data["nonce"],
      extensions: Map.drop(data, @wire_fields)
    }

    case validate(finish) do
      :ok -> {:ok, finish}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:interaction_finish, "must be a JSON object")])

  @doc "Validates a callback configuration without retaining rejected field values."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = finish) do
    errors =
      Enum.flat_map(
        [
          {finish.method == "redirect", :method, "must be redirect"},
          {Validation.absolute_uri?(finish.uri), :uri, "must be an absolute URI"},
          {Validation.string?(finish.nonce), :nonce, "must be a string"},
          {Validation.extensions?(finish.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved callback fields"}
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

  @doc "Converts to protocol fields, including the nonce, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = finish) do
    finish.extensions
    |> Map.drop(@wire_fields)
    |> Map.merge(%{"method" => finish.method, "uri" => finish.uri, "nonce" => finish.nonce})
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments interaction finish configuration",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.InteractionFinish do
  def encode(finish, opts) do
    finish |> OpenPayments.Types.InteractionFinish.to_map() |> Jason.Encode.map(opts)
  end
end
