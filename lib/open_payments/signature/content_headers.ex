defmodule OpenPayments.Signature.ContentHeaders do
  @moduledoc false

  alias OpenPayments.Error

  # The caller encodes JSON once, then uses the same binary for these headers,
  # the signature base, and transmission. This byte-level helper does not parse
  # JSON, normalize text, or validate protocol payloads.
  @spec build(binary() | nil) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, Error.t()}
  def build(nil), do: {:ok, %{}}

  def build(body) when is_binary(body) do
    digest = :sha512 |> :crypto.hash(body) |> Base.encode64()

    {:ok,
     %{
       "content-digest" => "sha-512=:#{digest}:",
       "content-length" => Integer.to_string(byte_size(body)),
       "content-type" => "application/json"
     }}
  end

  def build(_body) do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid Open Payments request body",
       validation_errors: [
         %{field: :body, message: "must be an encoded body binary or nil for no body"}
       ]
     }}
  end
end
