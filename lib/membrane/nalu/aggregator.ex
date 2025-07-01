defmodule Membrane.NALU.Aggregator do
  use Membrane.Filter

  alias Membrane.NALU

  def_input_pad(:input,
    accepted_format: %NALU.Format{alignment: :nalu}
  )

  def_output_pad(:output,
    accepted_format: Membrane.RemoteStream
  )

  def_options(
    alignment: [
      spec: :aud | :nalu,
      description: """
      - aud: group of units starting with an Access Unit Delimiter (useful for
        PES packaging)
      - nalu: each unit in its own buffer. Note: PTS/DTS values are going to be
        repeated, as they target AU units, not each single NALU.
      """,
      default: :aud
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{alignment: opts.alignment, acc: []}}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    format = %Membrane.RemoteStream{
      content_format: %NALU.Format{alignment: state.alignment},
      type: :packetized
    }

    {[stream_format: {:output, format}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{acc: []}) do
    {[end_of_stream: :output], state}
  end

  def handle_end_of_stream(:input, _ctx, state = %{acc: acc}) do
    buffer = timed_units_to_buffer(acc)
    state = put_in(state, [:acc], [])
    {[buffer: {:output, buffer}, end_of_stream: :output], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %{alignment: :nalu}) do
    buffers =
      buffer
      |> buffer_to_timed_units()
      |> timed_units_to_buffer()

    {[buffer: {:output, buffers}], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    chunk_fun = fn
      unit, [] when unit.header.type.id == :aud ->
        {:cont, [unit]}

      unit, acc when unit.header.type.id == :aud ->
        {:cont, Enum.reverse(acc), [unit]}

      unit, acc ->
        {:cont, [unit | acc]}
    end

    after_fun = fn
      [] -> {:cont, []}
      acc -> {:cont, Enum.reverse(acc), []}
    end

    acc = Enum.concat(state.acc, buffer_to_timed_units(buffer))

    {frames, pending} =
      acc
      |> Enum.chunk_while([], chunk_fun, after_fun)
      |> Enum.split(-1)

    state = put_in(state, [:acc], List.flatten(pending))

    buffers =
      frames
      |> Enum.map(fn units -> timed_units_to_buffer(units) end)
      |> Enum.reject(&is_nil/1)

    {[buffer: {:output, buffers}], state}
  end

  defp timed_units_to_buffer([]), do: nil

  defp timed_units_to_buffer([h | _] = timed_units) do
    is_keyframe =
      timed_units
      |> Enum.filter(fn x -> x.header.type.id == :idr_slice end)
      |> Enum.any?()

    payload =
      timed_units
      |> NALU.format_units()
      |> Enum.into(<<>>)

    %Membrane.Buffer{
      payload: payload,
      pts: h.pts,
      dts: h.dts,
      metadata: %{
        is_keyframe?: is_keyframe
      }
    }
  end

  defp buffer_to_timed_unit(buffer) do
    %{
      payload: buffer.payload,
      header: buffer.metadata.header,
      slice_header: buffer.metadata.slice_header,
      pts: buffer.pts,
      dts: buffer.dts
    }
  end

  defp buffer_to_timed_units(buffer) do
    buffer
    |> buffer_to_timed_unit()
    |> List.wrap()
  end
end
