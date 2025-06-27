defmodule Membrane.NALU do
  alias Membrane.NALU.AnnexB

  @nalu_reserved_types %{
    1 => %{
      id: :non_idr_slice,
      name: "Coded slice of a non-IDR picture",
      common_role: "P/B frames"
    },
    5 => %{
      id: :idr_slice,
      name: "Coded slice of an IDR picture (keyframe)",
      common_role: "I-frames"
    },
    6 => %{
      id: :sei,
      name: "Supplemental enhancement information",
      common_role: "Captions, timing, HDR, etc."
    },
    7 => %{id: :sps, name: "Sequence parameter set", common_role: "Stream-level info"},
    8 => %{id: :pps, name: "Picture parameter set", common_role: "Picture-level info"},
    9 => %{id: :aud, name: "Access unit delimiter", common_role: "Frame boundary marker"},
    10 => %{
      id: :end_of_sequence,
      name: "End of sequence",
      common_role: "Marks end of video sequence"
    },
    11 => %{id: :end_of_stream, name: "End of stream", common_role: "EOF marker"},
    12 => %{id: :filler_data, name: "Filler data", common_role: "Bitrate padding"},
    13 => %{
      id: :sps_extension,
      name: "Sequence parameter set extension",
      common_role: "SVC extension"
    },
    14 => %{id: :prefix_nal, name: "Prefix NAL unit", common_role: "SVC/MVC pre-slice headers"},
    15 => %{id: :subset_sps, name: "Subset sequence parameter set", common_role: "Extended SPS"},
    19 => %{
      id: :auxiliary_slice,
      name: "Coded slice of an auxiliary coded picture",
      common_role: "Auxiliary layers (e.g. alpha)"
    },
    20 => %{
      id: :slice_extension,
      name: "Coded slice extension",
      common_role: "SVC/MVC slice extension"
    },
    21 => %{
      id: :depth_view_slice,
      name: "Coded slice extension for depth view component",
      common_role: "MVC depth data"
    }
  }

  @nalu_slice_type %{
    0 => %{id: :p, name: "P slice (P frame only)"},
    1 => %{id: :b, name: "B slice (B frame only)"},
    2 => %{id: :i, name: "I slice (I frame only)"},
    3 => %{id: :sp, name: "SP slice (Switching P)"},
    4 => %{id: :si, name: "SI slice (Switching I)"},
    5 => %{id: :p_mixed, name: "P slice (mixed frame, primarily P)"},
    6 => %{id: :b_mixed, name: "B slice (mixed frame, primarily B)"},
    7 => %{id: :i_mixed, name: "I slice (mixed frame, primarily I)"},
    8 => %{id: :sp_mixed, name: "SP slice (mixed frame)"},
    9 => %{id: :si_mixed, name: "SI slice (mixed frame)"}
  }

  @doc """
  Parses a payload of AnnexB units.
  """
  def parse_units!(payload, opts \\ []) do
    payload
    |> AnnexB.parse_units!(opts)
    |> Stream.map(fn
      {:retry, data} ->
        {:retry, data}

      x ->
        <<header::binary-size(1)-unit(8), payload::binary>> = x.payload
        header = parse_header(header)

        slice_header =
          if get_in(header, [:type, :id]) in [:non_idr_slice, :idr_slice] do
            parse_slice_header(payload)
          else
            %{}
          end

        x
        |> put_in([:payload], payload)
        |> put_in([:header], header)
        |> put_in([:slice_header], slice_header)
    end)
  end

  defp parse_slice_header(payload) do
    {_first_mb_in_slice, payload} = decode_uev(payload)
    {slice_type_code, _payload} = decode_uev(payload)

    type =
      @nalu_slice_type
      |> Map.get(slice_type_code, %{id: :unknown, name: "Unknown NALU slice type"})
      |> Map.merge(%{code: slice_type_code})

    %{type: type}
  end

  defp parse_header(<<0::1, prio::2, type::5>>) do
    make_header(type, prio)
  end

  defp make_header(code, prio) do
    type =
      @nalu_reserved_types
      |> Map.get(code, %{id: :unknown, name: "Unknown NALU unit type"})
      |> Map.merge(%{code: code})

    %{type: type, priority: prio}
  end

  def has_keyframe(units) do
    units
    |> Enum.map(fn x -> get_in(x.header, [:type, :id]) in [:idr_slice] end)
    |> Enum.any?()
  end

  @doc """
  Takes a list of parsed units and returns a their binary representation.
  """
  def format_units(units) do
    units
    |> Stream.map(fn x = %{payload: payload, header: header} ->
      header = encode_header(header)
      payload = <<header::binary, payload::binary>>

      x
      |> Map.take([:prefix])
      |> Map.merge(%{payload: payload})
    end)
    |> AnnexB.format_units()
  end

  def encode_sei(sei_messages) do
    payload =
      sei_messages
      |> List.wrap()
      |> Enum.map(fn %{type: type, message: message} ->
        type = encode_ff(type)

        size =
          message
          |> byte_size()
          |> encode_ff()

        <<type::binary, size::binary, message::binary>>
      end)
      |> Enum.join(<<>>)

    %{
      type: 6,
      payload: <<
        payload::binary,
        # RBSP trailing bits, we're already byte aligned.
        0x80
      >>
    }
  end

  def encode_itu_t_t35(atsc) when is_binary(atsc) do
    # TODO: check the statements about SEIs not picked up.
    # Why the extra 0xFF is wrong
    # 	•	In H-264 every RBSP (including an SEI NALU) must finish with
    # rbsp_trailing_bits(), i.e. one ‘1’ bit followed by as many ‘0’ bits
    # as needed to reach the next byte boundary.
    # At byte-aligned positions that is the single byte 0x80.
    # 	•	0xFF contains eight ‘1’ bits, so after the mandatory stop_one_bit the
    # seven alignment bits are not zero, violating §7.3.2.9 of
    # ITU-T H.264 / ISO/IEC 14496-10.

    # ISO IEC 14496, annex D
    %{
      type: 4,
      message: <<
        # country_code (US), if you put something else ffmpeg will not parse it.
        0xB5,
        # provider code (ATSC)
        0x31::16,
        atsc::binary
      >>
    }
  end

  def encode_atsc_a53(cea708) when is_binary(cea708) do
    # A53 part 4
    # https://github.com/FFmpeg/FFmpeg/blob/afe6c1238ac4119ec9c9dedc42220c4595f6a33c/libavcodec/h2645_sei.c#L144
    <<
      "GA94",
      # user data type code (caption data)
      0x03,
      cea708::binary,
      # marker bits
      0xFF
    >>
  end

  def decode_uev(payload) do
    decode_uev(payload, 0)
  end

  defp decode_uev(<<>>, n) when n > 0 do
    raise "Unable to decode unsigned Exponential-Golomb (ue(v)) after #{n} bytes"
  end

  defp decode_uev(<<0::1, rest::bitstring>>, n) do
    decode_uev(rest, n + 1)
  end

  defp decode_uev(<<1::1, rest::bitstring>>, n) do
    <<remainer::bitstring-size(n)-unit(1), rest::bitstring>> = rest
    leading_zero_bit_count = byte_size(remainer) * 8 - bit_size(remainer)
    remainer = <<0::size(leading_zero_bit_count)-unit(1), remainer::bitstring>>

    uev = 2 ** n - 1 + :binary.decode_unsigned(remainer)
    {uev, rest}
  end

  def encode_ff(n) when n >= 0, do: encode_ff(n, <<>>)

  defp encode_ff(n, acc) when n >= 255 do
    encode_ff(n - 255, <<acc::binary, 0xFF>>)
  end

  defp encode_ff(n, acc), do: <<acc::binary, n>>

  def decode_ff(binary) when is_binary(binary) do
    decode_ff(binary, 0)
  end

  defp decode_ff(<<>>, acc), do: {acc, <<>>}

  defp decode_ff(<<0xFF, rest::binary>>, acc) do
    decode_ff(rest, acc + 255)
  end

  defp decode_ff(<<n, rest::binary>>, acc) do
    {acc + n, rest}
  end

  defp encode_header(%{type: %{code: code}, priority: prio}) do
    <<0::1, prio::2, code::5>>
  end

  def make_unit(%{payload: payload, type: type}, prio \\ 0) do
    %{payload: payload, header: make_header(type, prio)}
  end
end
