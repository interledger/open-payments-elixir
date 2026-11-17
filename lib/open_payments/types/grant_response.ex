defmodule OpenPayments.Types.GrantResponse do
  @moduledoc """
  A response to an initial grant request, with typed nested protocol data.

  Required `continue` contains a `Continuation`. Exactly one of `interact`
  (`InteractionResponse`) or `access_token` (`AccessToken`) must be present,
  representing pending interaction or immediate approval. These are initial
  response rules; subject-only and wait-only continuation results are different
  response contracts.

  Optional `subject` is decoded as `Subject`, following the Node SDK's grant model
  and the initial schema's permission for extra fields. Subject alone does not
  replace the required initial-response branch. All recognized fields are
  validated when present, including explicit-null rejection; remaining JSON data
  is retained in `extensions`.

  Inspection omits payload values. Explicit map/JSON exports include tokens,
  callback values, subject identifiers and card results. This codec makes no
  requests, verifies no callbacks and does not establish permission to use a
  resource. Predicates report typed branch shape; use `validate/1` to revalidate
  modified structs. `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{AccessToken, Continuation, InteractionResponse, Subject, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:continue]
  defstruct [:continue, :interact, :access_token, :subject, extensions: %{}]

  @wire_fields ~w(continue interact access_token subject)
  @optional_fields [
    {:interact, InteractionResponse, :interaction_response},
    {:access_token, AccessToken, :access_token},
    {:subject, Subject, :subject}
  ]

  @type t :: %__MODULE__{
          continue: Continuation.t(),
          interact: InteractionResponse.t() | nil,
          access_token: AccessToken.t() | nil,
          subject: Subject.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes an initial grant response and validates its typed fields and branch."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, continuation} <-
           nested(Continuation.from_map(data["continue"]), :continue, :continuation),
         {:ok, fields} <- decode_optional(data) do
      response =
        struct!(
          __MODULE__,
          Map.merge(fields, %{
            continue: continuation,
            extensions: Map.drop(data, @wire_fields)
          })
        )

      case validate(response) do
        :ok -> {:ok, response}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:grant_response, "must be a JSON object")])

  @doc "Revalidates every typed child, the initial-response branch and extensions."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = response) do
    errors =
      child_errors(response.continue, :continue, Continuation, :continuation) ++
        Enum.flat_map(@optional_fields, fn {field, module, root} ->
          case Map.fetch!(response, field) do
            nil -> []
            value -> child_errors(value, field, module, root)
          end
        end) ++ branch_errors(response) ++ extension_errors(response.extensions)

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Reports pending-interaction branch shape without revalidating nested values."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{interact: %InteractionResponse{}, access_token: nil}), do: true
  def pending?(%__MODULE__{}), do: false

  @doc "Reports immediate access-token approval shape without revalidating nested values."
  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{interact: nil, access_token: %AccessToken{}}), do: true
  def approved?(%__MODULE__{}), do: false

  @doc "Converts to protocol fields, including sensitive values, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = response) do
    fields =
      Enum.reduce(@optional_fields, %{"continue" => Continuation.to_map(response.continue)}, fn
        {field, module, _root}, fields ->
          case Map.fetch!(response, field) do
            nil -> fields
            value -> Map.put(fields, Atom.to_string(field), module.to_map(value))
          end
      end)

    response.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp decode_optional(data) do
    Enum.reduce_while(@optional_fields, {:ok, %{}}, fn {field, module, root}, {:ok, fields} ->
      case optional(data, field, module, root) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(fields, field, decoded)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp optional(data, field, module, root) do
    case Map.fetch(data, Atom.to_string(field)) do
      :error -> {:ok, nil}
      {:ok, value} -> nested(module.from_map(value), field, root)
    end
  end

  defp nested({:ok, value}, _parent, _root), do: {:ok, value}

  defp nested({:error, error}, parent, root),
    do: invalid(prefix(error.validation_errors, parent, root))

  defp child_errors(%{__struct__: module} = value, parent, module, root) do
    case module.validate(value) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors, parent, root)
    end
  end

  defp child_errors(_value, parent, _module, _root),
    do: [issue(parent, "must be the expected typed response struct")]

  defp branch_errors(response) do
    if is_nil(response.interact) != is_nil(response.access_token),
      do: [],
      else: [issue(:grant_response, "must contain exactly one of interact or access_token")]
  end

  defp extension_errors(extensions) do
    if Validation.extensions?(extensions, @wire_fields),
      do: [],
      else: [
        issue(
          :extensions,
          "must be a JSON object with string keys and no reserved grant response fields"
        )
      ]
  end

  defp prefix(errors, parent, root) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == root, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments initial grant response",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.GrantResponse do
  def encode(response, opts) do
    response |> OpenPayments.Types.GrantResponse.to_map() |> Jason.Encode.map(opts)
  end
end
