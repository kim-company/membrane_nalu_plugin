defmodule Membrane.NALU.AnnexB do
  alias Membrane.NALU.RBSP

  def parse_units!(payload, opts \\ []) do
    opts = Keyword.validate!(opts, preserve_original: false, assume_aligned: true)

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
      payload = RBSP.escape(payload)
      prefix = Map.get(x, :prefix, <<0, 0, 1>>)
      <<prefix::binary, payload::binary>>
    end)
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
    if opts[:assume_aligned] do
      {finalize_unit(acc, opts), nil}
    else
      {reject_partial_unit(acc), nil}
    end
  end

  defp reject_partial_unit(acc) do
    payload =
      acc
      |> Enum.reverse()
      |> :erlang.iolist_to_binary()

    {:retry, payload}
  end

  defp finalize_unit(iodata, opts) do
    [prefix | rest] = Enum.reverse(iodata)
    original_payload = :erlang.iolist_to_binary(rest)

    x = %{prefix: prefix, payload: RBSP.unescape(original_payload)}

    if opts[:preserve_original] do
      Map.put(x, :original, original_payload)
    else
      x
    end
  end
end
