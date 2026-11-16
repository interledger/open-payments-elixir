defmodule OpenPayments.Signature.Headers do
  @moduledoc false

  alias MessageSignatures.{Message, SignatureBase, SignatureParams}
  alias OpenPayments.{Error, Key}

  @max_created 999_999_999_999_999

  # Operates on a prepared request. The caller owns URL/header validation, JSON
  # encoding, body presence, and exact-byte transmission. Content headers must
  # already be present when body_present? is true. This is the reviewed Node
  # Open Payments profile, not the final GNAP RFC 9635 profile.
  @spec build(Key.t(), Message.t(), boolean(), non_neg_integer()) ::
          {:ok, %{String.t() => String.t()}} | {:error, Error.t()}
  def build(key, message, body_present?, created) do
    with :ok <- validate_inputs(key, message, body_present?, created),
         {:ok, params} <-
           SignatureParams.new(components(message, body_present?),
             keyid: Key.key_id(key),
             created: created
           ),
         {:ok, base} <- SignatureBase.build(message, params, []),
         {:ok, signature} <- Key.sign(key, base),
         {:ok, signature_input} <- SignatureParams.serialize(params) do
      {:ok,
       %{
         "signature-input" => "sig1=" <> signature_input,
         "signature" => "sig1=:#{Base.encode64(signature)}:"
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, %MessageSignatures.Error{reason: reason}} -> signing_failure(reason)
    end
  rescue
    _error in [MessageSignatures.Error, ArgumentError] -> signing_failure(:invalid_message)
  end

  defp components(message, body_present?) do
    authorization =
      case Message.field_value(message, "authorization") do
        {:ok, _value} -> ["authorization"]
        :error -> []
      end

    content = if body_present?, do: ~w(content-digest content-length content-type), else: []
    ["@method", "@target-uri"] ++ authorization ++ content
  end

  defp validate_inputs(key, message, body_present?, created) do
    errors =
      [
        {is_struct(key, Key), :key, "must be an Open Payments key"},
        {prepared_request?(message), :request, "must be a prepared request message"},
        {is_boolean(body_present?), :body_present, "must be a boolean"},
        {is_integer(created) and created >= 0 and created <= @max_created, :created,
         "must be a nonnegative Unix timestamp within the structured-field integer range"}
      ]
      |> Enum.flat_map(fn
        {true, _field, _message} -> []
        {false, field, message} -> [%{field: field, message: message}]
      end)

    if errors == [] do
      :ok
    else
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments signature inputs",
         validation_errors: errors
       }}
    end
  end

  defp prepared_request?(%Message{kind: :request, method: method, uri: %URI{} = uri}) do
    is_binary(method) and method != "" and is_binary(uri.scheme) and uri.scheme != "" and
      is_binary(uri.host) and uri.host != ""
  end

  defp prepared_request?(_message), do: false

  defp signing_failure(reason) do
    {:error,
     %Error{
       kind: :signing,
       code: Atom.to_string(reason),
       description: "Unable to generate Open Payments signature headers"
     }}
  end
end
