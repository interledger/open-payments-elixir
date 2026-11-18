defmodule OpenPayments.Types.GrantContinuationResponse do
  @moduledoc """
  A response to continuing a grant, with typed continuation and result data.

  Required `continue` contains a `Continuation`. Optional `access_token` and
  `subject` become `AccessToken` and `Subject` structs. Either, both or neither
  result may be returned; the initial grant response's exclusive interaction or
  token branch does not apply here. Omitted results become nil, while explicit
  JSON nulls are rejected. Additional JSON fields remain in `extensions`.

  Predicates report typed result presence, without revalidating modified children,
  verifying callbacks or establishing resource authorization. `continuation_only?/1`
  means both recognized result fields are absent; it does not interpret extensions
  or infer server lifecycle state. The codec does not wait, poll or make requests.

  Inspection omits payload values. Explicit map/JSON exports include credentials,
  subject identifiers and any card results. Use `validate/1` to revalidate manually
  modified structs; `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{AccessToken, Continuation, Subject, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:continue]
  defstruct [:continue, :access_token, :subject, extensions: %{}]

  @wire_fields ~w(continue access_token subject)
  @optional_fields [{:access_token, AccessToken, :access_token}, {:subject, Subject, :subject}]

  @type t :: %__MODULE__{
          continue: Continuation.t(),
          access_token: AccessToken.t() | nil,
          subject: Subject.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes a grant continuation response, including subject-only and continuation-only results."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, continuation} <-
           nested(Continuation.from_map(data["continue"]), :continue, :continuation),
         {:ok, token} <- optional(data, :access_token, AccessToken, :access_token),
         {:ok, subject} <- optional(data, :subject, Subject, :subject) do
      response = %__MODULE__{
        continue: continuation,
        access_token: token,
        subject: subject,
        extensions: Map.drop(data, @wire_fields)
      }

      case validate(response) do
        :ok -> {:ok, response}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:grant_continuation_response, "must be a JSON object")])

  @doc "Revalidates the continuation, optional typed results and extension data."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = response) do
    errors =
      child_errors(response.continue, :continue, Continuation, :continuation) ++
        Enum.flat_map(@optional_fields, fn {field, module, root} ->
          case Map.fetch!(response, field) do
            nil -> []
            value -> child_errors(value, field, module, root)
          end
        end) ++ extension_errors(response.extensions)

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Reports typed access-token presence without revalidating its contents."
  @spec has_access_token?(t()) :: boolean()
  def has_access_token?(%__MODULE__{access_token: %AccessToken{}}), do: true
  def has_access_token?(%__MODULE__{}), do: false

  @doc "Reports typed subject presence without revalidating its contents."
  @spec has_subject?(t()) :: boolean()
  def has_subject?(%__MODULE__{subject: %Subject{}}), do: true
  def has_subject?(%__MODULE__{}), do: false

  @doc "Reports absence of both recognized result fields without inferring lifecycle state."
  @spec continuation_only?(t()) :: boolean()
  def continuation_only?(%__MODULE__{access_token: nil, subject: nil}), do: true
  def continuation_only?(%__MODULE__{}), do: false

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

  defp extension_errors(extensions) do
    if Validation.extensions?(extensions, @wire_fields),
      do: [],
      else: [
        issue(
          :extensions,
          "must be a JSON object with string keys and no reserved continuation response fields"
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
         description: "Invalid Open Payments grant continuation response",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.GrantContinuationResponse do
  def encode(response, opts) do
    response |> OpenPayments.Types.GrantContinuationResponse.to_map() |> Jason.Encode.map(opts)
  end
end
