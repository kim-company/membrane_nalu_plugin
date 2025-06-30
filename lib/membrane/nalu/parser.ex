defmodule Membrane.NALU.Parser do
  use Membrane.Filter

  alias Membrane.NALU

  def_input_pad(:input,
    accepted_format: _
  )

  def_output_pad(:output,
    accepted_format: NALU.Format
  )

  def_options(
    alignment: [
      spec: :aud | :nalu,
      description: """
      - aud: group of units starting with an Access Unit Delimiter (useful for PES packaging)
      - nalu: each unit in its own buffer. Note: PTS/DTS values are going to be
        repeated, as they target AU units, not each single NALU.
      """,
      default: :aud
    ],
    assume_aligned: [
      spec: boolean(),
      description: """
      When true, assumes that each input buffer contains a list of complete NALU units. This happens for example when parsing an MPEG-TS PES payload. Timing is forwarded from input to output buffers only alignment is :aud and assume_aligned==true, as in the other cases 
      """,
      default: false
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{alignment: opts.alignment, assume_aligned: opts.assume_aligned, partial: <<>>, aud_acc: []}}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[stream_format: {:output, %NALU.Format{alignment: state.alignment}}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {units, later} =
      (state.partial <> buffer.payload)
      |> NALU.parse_units!(assume_aligned: state.assume_aligned)
      |> Enum.split_with(fn
        {:retry, _data} -> false
        _unit -> true
      end)

    if length(later) > 1 do
      raise RuntimeError, "At most 1 partial unit can remain unprocessed"
    end

    state =
      case later do
        [] -> put_in(state, [:partial], <<>>)
        [{:retry, val}] -> put_in(state, [:partial], val)
      end

    handle_units(units, {buffer.pts, buffer.dts}, state)
  end

  def handle_units(units, timing, state = %{alignment: :nalu}) do
    # Then each unit becomes a buffer.
    buffers = Enum.map(units, &units_to_buffer([&1], timing))
    {[buffer: {:output, buffers}], state}
  end

  def handle_units(
        units = [%{header: %{id: :aud}} | _],
        timing,
        state = %{alignment: :aud, assume_aligned: true}
      ) do
    buffer = units_to_buffer(units, timing)
    {[buffer: {:output, buffer}], state}
  end

  def handle_units(units, _timing, state = %{alignment: :aud}) do
    chunk_fun = fn
      unit, [] when unit.header.id == :aud ->
        {:cont, [unit]}

      unit, acc when unit.header.id == :aud ->
        {:cont, Enum.reverse(acc), [unit]}

      unit, acc ->
        {:cont, [unit | acc]}
    end

    after_fun = fn
      [] -> {:cont, []}
      acc -> {:cont, Enum.reverse(acc), []}
    end

    chunks =
      state.aud_acc
      |> Enum.concat(units)
      |> Enum.chunk_while([], chunk_fun, after_fun)

    {chunks, state} =
      if state.assume_aligned do
        {chunks, state}
      else
        {chunks, last} = Enum.split(chunks, -1)
        {chunks, put_in(state, [:aud_acc], last)}
      end

    # We cannot tell anything about the timing here.
    buffers = Enum.map(chunks, fn units -> units_to_buffer(units, {nil, nil}) end)
    {[buffer: {:output, buffers}], state}
  end

  defp units_to_buffer(units, {dts, pts}) do
    is_keyframe =
      units
      |> Enum.filter(fn x -> x.header.type == :idr_slice end)
      |> Enum.any?()

    payload =
      units
      |> NALU.format_units()
      |> Enum.into(<<>>)

    %Membrane.Buffer{
      payload: payload,
      pts: pts,
      dts: dts,
      metadata: %{
        is_keyframe: is_keyframe
      }
    }
  end
end
