defmodule Membrane.NALU.ParserBinTest do
  use ExUnit.Case, async: true
  alias Membrane.NALU

  import Membrane.ChildrenSpec

  @input "test/data/avsync.ts"
  @sps_with_vui Base.decode64!("ZAAfrNlAUAW7ARAAAAAQAAADwPGDGWA=")

  defp annexb_unit(nal_type, payload, nal_ref_idc) do
    header = <<0::1, nal_ref_idc::2, nal_type::5>>
    <<0, 0, 0, 1, header::binary, payload::binary>>
  end

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

  test "emits stream format with framerate before buffers when required" do
    sps_payload = Membrane.NALU.RBSP.escape(@sps_with_vui)

    payload =
      annexb_unit(9, <<0xF0>>, 0) <>
        annexb_unit(7, sps_payload, 3) <>
        annexb_unit(5, <<0x88>>, 3) <>
        annexb_unit(9, <<0xF0>>, 0)

    spec = [
      child(:source, %Membrane.Testing.Source{
        output: [%Membrane.Buffer{payload: payload}],
        stream_format: %Membrane.RemoteStream{}
      })
      |> child(:parser, %NALU.ParserBin{alignment: :aud, require_framerate?: true})
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    assert_receive {Membrane.Testing.Pipeline, ^pid,
                    {:handle_child_notification, {{:stream_format, :input, format}, :sink}}},
                   3_000

    assert %Membrane.RemoteStream{
             content_format: %NALU.Format{framerate: {_, _}}
           } = format

    refute_receive {Membrane.Testing.Pipeline, ^pid,
                    {:handle_child_notification, {{:buffer, _buffer}, :sink}}}, 0

    assert_receive {Membrane.Testing.Pipeline, ^pid,
                    {:handle_child_notification, {{:buffer, _buffer}, :sink}}}, 3_000

    Membrane.Testing.Pipeline.terminate(pid, force?: true)
  end

  test "raises when framerate is required but not found in time" do
    Process.flag(:trap_exit, true)

    payload = <<0, 0, 0, 1, 0x41, 0x00>>

    spec = [
      child(:source, %Membrane.Testing.Source{
        output: [%Membrane.Buffer{payload: payload}, %Membrane.Buffer{payload: payload}],
        stream_format: %Membrane.RemoteStream{}
      })
      |> child(:parser, %NALU.ParserBin{
        alignment: :nalu,
        require_framerate?: true,
        max_pending_units: 1
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 3_000
    assert inspect(reason) =~ "framerate"
  end

  test "derives framerate from PTS when VUI timing is absent" do
    aud_payload = <<0, 0, 0, 1, 0x09, 0xF0>>
    delta = div(Membrane.Time.second(), 30)

    buffers = [
      %Membrane.Buffer{payload: aud_payload, pts: 0, dts: 0},
      %Membrane.Buffer{payload: aud_payload, pts: delta, dts: delta}
    ]

    spec = [
      child(:source, %Membrane.Testing.Source{
        output: buffers,
        stream_format: %Membrane.RemoteStream{}
      })
      |> child(:parser, %NALU.ParserBin{
        alignment: :aud,
        assume_aligned: true,
        require_framerate?: true
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    assert_receive {Membrane.Testing.Pipeline, ^pid,
                    {:handle_child_notification, {{:stream_format, :input, format}, :sink}}},
                   3_000

    assert %Membrane.RemoteStream{
             content_format: %NALU.Format{framerate: {_, ^delta}}
           } = format

    Membrane.Testing.Pipeline.terminate(pid, force?: true)
  end
end
