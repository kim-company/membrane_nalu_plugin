defmodule Membrane.NALU.RBSP do
  @moduledoc """
  Implements Raw Byte Sequence Payload encoding/decoding.
  """

  @doc """
  Escapes the payload according to RBSP instructions.
  """
  def escape(payload) when is_binary(payload) do
    escape(payload, [])
  end

  defp escape(<<0x00, 0x00, third::8, rest::binary>>, acc) when third <= 0x03 do
    escape(<<third::8, rest::binary>>, [<<0x00, 0x00, 0x03>> | acc])
  end

  defp escape(<<next::8, rest::binary>>, acc) do
    escape(rest, [next | acc])
  end

  defp escape(<<>>, acc) do
    acc
    |> Enum.reverse()
    |> :erlang.iolist_to_binary()
  end

  @doc """
  Removes emulation prevention bytes (0x03).
  """
  def unescape(payload) do
    unescape(payload, [])
  end

  defp unescape(<<0x00, 0x00, 0x03, rest::binary>>, acc) do
    data = <<0x00, 0x00>>
    unescape(rest, [data | acc])
  end

  defp unescape(<<next::8, rest::binary>>, acc) do
    unescape(rest, [next | acc])
  end

  defp unescape(<<>>, acc) do
    acc
    |> Enum.reverse()
    |> :erlang.iolist_to_binary()
  end
end
