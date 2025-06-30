defmodule Membrane.NALU.Parser do
  use Membrane.Filter

  alias Membrane.NALU

  def_input_pad(:input,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:output,
    accepted_format: NALU.Format
  )

  def_options(
    # TODO: instead of making the user choose, we could check wether the input
    # remote stream is packetized or not, which has the same meaning.
    assume_aligned: [
      spec: boolean(),
      description: """
      When true, assumes that each input buffer contains a list of complete
      NALU units. This happens for example when parsing an MPEG-TS PES payload.

      Only then true buffers will contain DTS/PTS values.
      """,
      default: false
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{assume_aligned: opts.assume_aligned, partial: <<>>}}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[stream_format: {:output, %NALU.Format{alignment: :nalu}}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{partial: <<>>}) do
    {[end_of_stream: :output], state}
  end

  def handle_end_of_stream(:input, _ctx, state = %{partial: partial}) do
    buffers =
      partial
      |> NALU.parse_units!()
      |> units_to_buffers({nil, nil})

    state = put_in(state, [:partial], <<>>)

    {[buffer: {:output, buffers}, end_of_stream: :output], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %{assume_aligned: true}) do
    buffers =
      buffer.payload
      |> NALU.parse_units!(assume_aligned: true)
      |> units_to_buffers({buffer.dts, buffer.pts})

    {[buffer: {:output, buffers}], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {units, later} =
      (state.partial <> buffer.payload)
      |> NALU.parse_units!(assume_aligned: false)
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

    buffers = units_to_buffers(units, {nil, nil})
    {[buffer: {:output, buffers}], state}
  end

  defp units_to_buffers(units, {pts, dts}) do
    units
    |> Enum.map(fn x ->
      %Membrane.Buffer{
        payload: x.payload,
        pts: pts,
        dts: dts,
        metadata: %{
          header: x.header,
          slice_header: x.slice_header
        }
      }
    end)
  end
end
