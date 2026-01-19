defmodule Membrane.NALU.Aggregator do
  use Membrane.Filter

  alias Membrane.NALU
  alias Membrane.NALU.SPS

  @default_max_pending_units 120

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
    ],
    require_framerate?: [
      spec: boolean(),
      description: """
      When true, buffers are held until an SPS with VUI timing info is received.
      The output stream format is emitted with framerate before any buffers.
      """,
      default: false
    ],
    max_pending_units: [
      spec: pos_integer(),
      description: """
      Maximum number of output units to buffer while waiting for framerate.
      Defaults to #{@default_max_pending_units} to allow a few GOPs worth of SPS cadence.
      """,
      default: @default_max_pending_units
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       alignment: opts.alignment,
       acc: [],
       require_framerate?: opts.require_framerate?,
       max_pending_units: opts.max_pending_units,
       framerate: nil,
       stream_format_sent?: false,
       pending_outputs: [],
       pending_units: 0
     }}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    if state.require_framerate? and is_nil(state.framerate) do
      {[], state}
    else
      {[stream_format: {:output, build_stream_format(state)}],
       %{state | stream_format_sent?: true}}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{acc: []}) do
    if state.require_framerate? and not state.stream_format_sent? do
      raise "framerate not detected before end of stream"
    end

    {[end_of_stream: :output], state}
  end

  def handle_end_of_stream(:input, _ctx, state = %{acc: acc}) do
    if state.require_framerate? and not state.stream_format_sent? do
      raise "framerate not detected before end of stream"
    end

    buffer = timed_units_to_buffer(acc)
    state = put_in(state, [:acc], [])
    {buffer_actions, state} = emit_buffers(List.wrap(buffer), state)
    {buffer_actions ++ [end_of_stream: :output], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %{alignment: :nalu}) do
    state = maybe_update_framerate(buffer, state)

    buffers =
      buffer
      |> buffer_to_timed_units()
      |> timed_units_to_buffer()

    emit_buffers(List.wrap(buffers), state)
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    state = maybe_update_framerate(buffer, state)

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

    emit_buffers(buffers, state)
  end

  defp timed_units_to_buffer([]), do: nil

  defp timed_units_to_buffer([h | _] = timed_units) do
    unit_ids = Enum.map(timed_units, fn x -> x.header.type.id end)

    {unit_offsets, _} =
      Enum.map_reduce(timed_units, 0, fn x, offset ->
        size = byte_size(x.payload)
        item = %{offset: offset, size: byte_size(x.payload)}
        {item, offset + size}
      end)

    keyframe? = :idr_slice in unit_ids

    payload =
      timed_units
      |> NALU.format_units()
      |> Enum.into(<<>>)

    %Membrane.Buffer{
      payload: payload,
      pts: h.pts,
      dts: h.dts,
      metadata: %{
        is_keyframe?: keyframe?,
        units: unit_ids,
        offsets: unit_offsets
      }
    }
  end

  defp buffer_to_timed_unit(buffer) do
    %{
      payload: buffer.payload,
      header: buffer.metadata.header,
      pts: buffer.pts,
      dts: buffer.dts
    }
  end

  defp buffer_to_timed_units(buffer) do
    buffer
    |> buffer_to_timed_unit()
    |> List.wrap()
  end

  defp emit_buffers([], state) do
    maybe_emit_stream_format([], state)
  end

  defp emit_buffers(buffers, state) do
    if state.stream_format_sent? do
      {[buffer: {:output, buffers}], state}
    else
      maybe_emit_stream_format(buffers, state)
    end
  end

  defp maybe_emit_stream_format(buffers, state) do
    if state.require_framerate? do
      state =
        state
        |> queue_pending_outputs(buffers)
        |> ensure_pending_limit!()

      if state.framerate do
        actions = [stream_format: {:output, build_stream_format(state)}]
        pending = state.pending_outputs
        state = %{state | pending_outputs: [], pending_units: 0, stream_format_sent?: true}

        if pending == [] do
          {actions, state}
        else
          {actions ++ [buffer: {:output, pending}], state}
        end
      else
        {[], state}
      end
    else
      actions = [stream_format: {:output, build_stream_format(state)}]
      {actions ++ [buffer: {:output, buffers}], %{state | stream_format_sent?: true}}
    end
  end

  defp queue_pending_outputs(state, buffers) do
    new_outputs = state.pending_outputs ++ buffers
    increment = max(length(buffers), 1)

    %{state | pending_outputs: new_outputs, pending_units: state.pending_units + increment}
  end

  defp ensure_pending_limit!(%{pending_units: pending_units, max_pending_units: max} = state) do
    if pending_units > max do
      raise "framerate not detected after buffering #{pending_units} units"
    end

    state
  end

  defp build_stream_format(state) do
    %Membrane.RemoteStream{
      content_format: %NALU.Format{alignment: state.alignment, framerate: state.framerate},
      type: :packetized
    }
  end

  defp maybe_update_framerate(
         %Membrane.Buffer{metadata: %{header: %{type: %{id: :sps}}}} = buffer,
         state
       ) do
    case NALU.parse_nal_payload(:sps, buffer.payload) do
      {:ok, sps} ->
        case SPS.framerate_from_vui(sps) do
          nil -> state
          framerate when is_nil(state.framerate) -> %{state | framerate: framerate}
          _framerate -> state
        end

      _ ->
        state
    end
  end

  defp maybe_update_framerate(_buffer, state), do: state
end
