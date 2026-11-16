defmodule OpenPayments.Test.HTTPServer do
  @moduledoc false

  # A small local wire fixture. OTP parses HTTP/1 request packets; tests control
  # responses and inspect the unmodified request target and body bytes.
  def start(reply, ip \\ {127, 0, 0, 1}) do
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        family,
        active: false,
        packet: :http_bin,
        ip: ip,
        reuseaddr: true
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    ExUnit.Callbacks.start_supervised!({Task, fn -> accept(listener, owner, reply) end})
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listener) end)
    host = ip |> :inet.ntoa() |> to_string()
    host = if family == :inet6, do: "[#{host}]", else: host
    "http://#{host}:#{port}"
  end

  defp accept(listener, owner, reply) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_request(socket)
        send(owner, {:http_request, request})
        respond(socket, reply.(request))
        :gen_tcp.close(socket)
        accept(listener, owner, reply)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket) do
    {:ok, {:http_request, method, {:abs_path, target}, _version}} =
      :gen_tcp.recv(socket, 0, 5_000)

    headers = read_headers(socket, [])
    :ok = :inet.setopts(socket, packet: :raw)
    length = headers |> Map.new() |> Map.get("content-length", "0") |> String.to_integer()
    body = if length == 0, do: "", else: read_body(socket, length)
    %{method: to_string(method), target: target, headers: headers, body: body}
  end

  defp read_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _index, name, _reserved, value}} ->
        read_headers(socket, [{name |> to_string() |> String.downcase(), value} | headers])

      {:ok, :http_eoh} ->
        Enum.reverse(headers)
    end
  end

  defp read_body(socket, length) do
    {:ok, body} = :gen_tcp.recv(socket, length, 5_000)
    body
  end

  defp respond(_socket, :close), do: :ok
  defp respond(socket, {:raw, response}), do: :gen_tcp.send(socket, response)

  defp respond(socket, {status, headers, body}) do
    fields = [
      {"content-length", Integer.to_string(byte_size(body))},
      {"connection", "close"} | headers
    ]

    response = [
      "HTTP/1.1 #{status} Response\r\n",
      Enum.map(fields, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end
end
