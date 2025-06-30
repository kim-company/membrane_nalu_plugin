defmodule Membrane.NALU.ParserBin do
  use Membrane.Bin

  alias Membrane.NALU

  def_input_pad(:input,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:output,
    accepted_format: Membrane.RemoteStream
  )

  def_options(
    assume_aligned: [
      spec: boolean(),
      description: """
      When true, assumes that each input buffer contains a list of complete
      NALU units. This happens for example when parsing an MPEG-TS PES payload.

      Only then true buffers will contain DTS/PTS values.
      """,
      default: false
    ],
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
    spec = [
      bin_input(:input)
      |> child(:parser, %NALU.Parser{assume_aligned: opts.assume_aligned})
      |> child(:aggregator, %NALU.Aggregator{alignment: opts.alignment})
      |> bin_output(:output)
    ]

    {[spec: spec], %{}}
  end
end
