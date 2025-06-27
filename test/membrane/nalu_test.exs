defmodule Membrane.NALUTest do
  use ExUnit.Case,
    async: true,
    parameterize: [
      %{input: "test/data/input.h264"}
    ]

  alias Membrane.NALU

  test "NALU stream is not mangled with parsing", %{input: input} do
    input
    |> File.read!()
    |> NALU.parse_units!(preserve_original: true)
    # We only take 20 otherwise the test runs for too long for HD inputs.
    |> Enum.take(20)
    |> Stream.with_index()
    |> Enum.each(fn {unit, index} ->
      formatted = NALU.format_units([unit]) |> Enum.into(<<>>)
      original = <<unit.prefix::binary, unit.original::binary>>

      assert formatted == original, """
      parse->format process mangled unit at index #{index} for #{inspect(input)}
      -----
      #{inspect(original, base: :hex, limit: :infinity)}
      vs --
      #{inspect(formatted, base: :hex, limit: :infinity)}
      -----
      """
    end)
  end
end
