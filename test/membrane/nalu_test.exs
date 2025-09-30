defmodule Membrane.NALUTest do
  use ExUnit.Case,
    async: true,
    parameterize: [
      %{input: "test/data/avsync.ts"}
    ]

  alias Membrane.NALU

  test "NALU stream is not mangled with parsing", %{input: input} do
    input
    |> MPEG.TS.Demuxer.stream_file!()
    |> Enum.filter(fn %{pid: x} -> x == 0x100 end)
    |> Enum.map(fn x -> x.payload.data end)
    |> Enum.join(<<>>)
    |> NALU.parse_units!(preserve_original: true)
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

  test "uev decoding" do
    # Known Exponential-Golomb encodings:
    # 0 -> b1
    # 1 -> b010
    # 2 -> b011
    # 3 -> b00100
    # 4 -> b00101

    test_cases = [
      # "1" + padding
      {<<1::1, 0::7>>, 0},
      # "010" + padding
      {<<0::1, 1::1, 0::1, 0::5>>, 1},
      # "011" + padding
      {<<0::1, 1::1, 1::1, 0::5>>, 2},
      # "00100" + padding
      {<<0::2, 1::1, 0::2, 0::3>>, 3},
      # "00101" + padding
      {<<0::2, 1::1, 0::1, 1::1, 0::3>>, 4}
    ]

    for {binary, expected} <- test_cases do
      {result, _} = NALU.decode_uev(binary)
      assert result == expected
    end
  end
end
