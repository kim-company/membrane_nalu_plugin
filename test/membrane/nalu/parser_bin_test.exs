defmodule Membrane.NALU.ParserBinTest do
  use ExUnit.Case, async: true
  alias Membrane.NALU

  import Membrane.ChildrenSpec

  @input "test/data/avsync.ts"

  def consume_pipeline(spec) do
    Stream.resource(
      fn -> Membrane.Testing.Pipeline.start_link_supervised!(spec: spec) end,
      fn pid ->
        receive do
          {Membrane.Testing.Pipeline, ^pid,
           {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
            {[buffer], pid}

          {Membrane.Testing.Pipeline, ^pid,
           {:handle_child_notification, {{:end_of_stream, :input}, :sink}}} ->
            {:halt, pid}
        after
          3_000 ->
            raise "test timeout"
        end
      end,
      fn pid -> Membrane.Testing.Pipeline.terminate(pid, force?: true) end
    )
  end

  test "Parses valid NALU units, NALU alignment" do
    [
      child(:source, %Membrane.File.Source{location: @input})
      |> child(:demuxer, Membrane.MPEG.TS.Demuxer)
      |> via_out(:output, options: [pid: 0x100])
      |> child(:parser, %NALU.ParserBin{alignment: :nalu})
      |> child(:sink, Membrane.Testing.Sink)
    ]
    |> consume_pipeline()
    |> Enum.each(fn buffer ->
      units = NALU.parse_units!(buffer.payload) |> Enum.into([])
      assert length(units) == 1
    end)
  end

  test "Parses valid NALU units, AU alignment" do
    [
      child(:source, %Membrane.File.Source{location: @input})
      |> child(:demuxer, Membrane.MPEG.TS.Demuxer)
      |> via_out(:output, options: [pid: 0x100])
      |> child(:parser, %NALU.ParserBin{alignment: :aud, assume_aligned: true})
      |> child(:sink, Membrane.Testing.Sink)
    ]
    |> consume_pipeline()
    |> Enum.each(fn buffer ->
      units = NALU.parse_units!(buffer.payload) |> Enum.into([])
      assert length(units) >= 1
      assert List.first(units).header.type.id == :aud

      is_keyframe = buffer.metadata.is_keyframe?

      if is_keyframe do
        [:aud, :sps, :idr_slice]
        |> Enum.each(fn x ->
          assert x in Enum.map(units, fn u -> u.header.type.id end)
        end)
      end
    end)
  end

  test "SPS buffers contain expected metadata" do
    [
      child(:source, %Membrane.File.Source{location: @input})
      |> child(:parser, %NALU.ParserBin{alignment: :nalu})
      |> child(:sink, Membrane.Testing.Sink)
    ]
    |> consume_pipeline()
    |> Enum.each(fn buffer ->
      sps = Enum.find_index(buffer.metadata.units, fn x -> x == :sps end)

      if sps != nil do
        %{offset: offset, size: size} = Enum.at(buffer.metadata.offsets, sps)
        <<_skip::binary-size(offset), sps::binary-size(size), _rest::binary>> = buffer.payload
        {:ok, sps} = NALU.parse_nal_payload(:sps, sps)
        assert is_map(sps)
        assert map_size(sps) > 0
      end
    end)
  end
end
