defmodule Membrane.NALU.ParserBinTest do
  use ExUnit.Case, async: true
  alias Membrane.NALU

  import Membrane.ChildrenSpec

  @input "test/data/input.h264"

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
      |> child(:parser, %NALU.ParserBin{alignment: :aud})
      |> child(:sink, Membrane.Testing.Sink)
    ]
    |> consume_pipeline()
    |> Enum.each(fn buffer ->
      units = NALU.parse_units!(buffer.payload) |> Enum.into([])
      assert length(units) >= 1
      assert List.first(units).header.type.id == :aud

      if buffer.metadata.is_keyframe? do
        [:aud, :sps, :idr_slice]
        |> Enum.each(fn x ->
          assert x in Enum.map(units, fn u -> u.header.type.id end)
        end)
      end
    end)
  end
end
