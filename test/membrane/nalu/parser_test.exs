defmodule Membrane.NALU.ParserTest do
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

          {Membrane.Testing.Pipeline, ^pid, {:handle_element_end_of_stream, {:sink, :input}}} ->
            {:halt, pid}
        end
      end,
      fn pid -> Membrane.Testing.Pipeline.terminate(pid) end
    )
  end

  test "Parses valid NALU units, NALU alignment" do
    [
      child(:source, %Membrane.File.Source{location: @input})
      |> child(:parser, %NALU.Parser{alignment: :nalu})
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
      |> child(:parser, %NALU.Parser{alignment: :aud})
      |> child(:sink, Membrane.Testing.Sink)
    ]
    |> consume_pipeline()
    |> Enum.each(fn buffer ->
      units = NALU.parse_units!(buffer.payload) |> Enum.into([])
      assert length(units) >= 1
      assert List.first(units).metadata.header.id == :aud
    end)
  end
end
