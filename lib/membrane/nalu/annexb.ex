defmodule Membrane.NALU.AnnexB do
  def parse_units!(payload, opts \\ []) do
    opts = Keyword.validate!(opts, preserve_original: false)

    Stream.unfold(payload, fn
      nil ->
        nil

      acc ->
        parse_next_unit(acc, [], opts)
    end)
  end

  def format_units(units) do
    units
    |> Stream.map(fn x = %{payload: payload} ->
      payload = escape_payload(payload)

      prefix = Map.get(x, :prefix, <<0, 0, 1>>)
      <<prefix::binary, payload::binary>>
    end)
  end

  @doc """
  Escapes the payload according to RBSP instructions.
  """
  def escape_payload(payload) when is_binary(payload) do
    escape_payload(payload, [])
  end

  defp escape_payload(<<0x00, 0x00, third::8, rest::binary>>, acc) when third <= 0x03 do
    escape_payload(<<third::8, rest::binary>>, [<<0x00, 0x00, 0x03>> | acc])
  end

  defp escape_payload(<<next::8, rest::binary>>, acc) do
    escape_payload(rest, [next | acc])
  end

  defp escape_payload(<<>>, acc) do
    acc
    |> Enum.reverse()
    |> :erlang.iolist_to_binary()
  end

  @doc """
  Removes emulation prevention bytes (0x03).
  """
  def unescape_payload(payload) do
    unescape_payload(payload, [])
  end

  defp unescape_payload(<<0x00, 0x00, 0x03, rest::binary>>, acc) do
    data = <<0x00, 0x00>>
    unescape_payload(rest, [data | acc])
  end

  defp unescape_payload(<<next::8, rest::binary>>, acc) do
    unescape_payload(rest, [next | acc])
  end

  defp unescape_payload(<<>>, acc) do
    acc
    |> Enum.reverse()
    |> :erlang.iolist_to_binary()
  end

  defp parse_next_unit(<<0, 0, 0, 1, rest::binary>>, [], opts) do
    # Start eating the NALU
    parse_next_unit(rest, [<<0, 0, 0, 1>>], opts)
  end

  defp parse_next_unit(<<0, 0, 1, rest::binary>>, [], opts) do
    # Start eating the NALU
    parse_next_unit(rest, [<<0, 0, 1>>], opts)
  end

  defp parse_next_unit(x = <<0, 0, 0, 1, _rest::binary>>, acc, opts) do
    # A complete unit has been processed, go on.
    {finalize_unit(acc, opts), x}
  end

  defp parse_next_unit(x = <<0, 0, 1, _rest::binary>>, acc, opts) do
    # A complete unit has been processed, go on.
    {finalize_unit(acc, opts), x}
  end

  defp parse_next_unit(<<x::binary-size(1)-unit(8), rest::binary>>, acc, opts) do
    parse_next_unit(rest, [x | acc], opts)
  end

  defp parse_next_unit(<<>>, acc, opts) do
    {finalize_unit(acc, opts), nil}
  end

  defp finalize_unit(iodata, opts) do
    [prefix | rest] = Enum.reverse(iodata)

    original_payload = :erlang.iolist_to_binary(rest)
    payload = unescape_payload(original_payload)

    x = %{prefix: prefix, payload: payload}

    if opts[:preserve_original] do
      Map.merge(x, %{original: original_payload})
    else
      x
    end
  end
end
