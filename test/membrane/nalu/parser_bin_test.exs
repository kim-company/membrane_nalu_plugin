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
    sps_units =
      [
        child(:source, %Membrane.File.Source{location: @input})
        |> child(:parser, %NALU.ParserBin{alignment: :nalu})
        |> child(:sink, Membrane.Testing.Sink)
      ]
      |> consume_pipeline()
      |> Enum.flat_map(fn buffer ->
        buffer.metadata.units
        |> Enum.filter(fn {x, _} -> x == :sps end)
        |> Enum.map(&elem(&1, 1))
      end)

    assert length(sps_units) > 0, "Expected to find at least one SPS buffer"

    sps_units
    |> Enum.each(fn sps ->
      assert sps == %{
               constraint_flags: %{
                 constraint_set0_flag: false,
                 constraint_set1_flag: false,
                 constraint_set2_flag: false,
                 constraint_set3_flag: false,
                 constraint_set4_flag: false,
                 constraint_set5_flag: false
               },
               bit_depth_chroma_minus8: 0,
               bit_depth_luma_minus8: 0,
               chroma_format_idc: 1,
               cropping: %{left: 0, right: 0, bottom: 0, top: 0},
               direct_8x8_inference_flag: true,
               frame_cropping_flag: false,
               frame_mbs_only_flag: true,
               gaps_in_frame_num_value_allowed_flag: false,
               level_idc: 31,
               log2_max_frame_num_minus4: 0,
               max_num_ref_frames: 4,
               mb_adaptive_frame_field_flag: false,
               pic_height_in_map_units_minus1: 44,
               pic_order_cnt_info: %{log2_max_pic_order_cnt_lsb_minus4: 2},
               pic_order_cnt_type: 0,
               pic_width_in_mbs_minus1: 79,
               profile_idc: 100,
               resolution: %{width: 1280, height: 720, raw_height: 720, raw_width: 1280},
               separate_colour_plane_flag: false,
               seq_parameter_set_id: 0,
               vui_parameters_present_flag: true,
               vui_parameters: %{
                 aspect_ratio_info_present_flag: true,
                 aspect_ratio_info: %{aspect_ratio_idc: 1},
                 overscan_info_present_flag: false,
                 overscan_appropriate_flag: false,
                 video_signal_type_present_flag: true,
                 video_signal_info: %{
                   video_format: 5,
                   video_full_range_flag: false,
                   colour_description_present_flag: true,
                   colour_info: %{
                     colour_primaries: 1,
                     transfer_characteristics: 1,
                     matrix_coefficients: 1
                   }
                 },
                 chroma_loc_info_present_flag: false,
                 chroma_sample_loc_info: %{},
                 timing_info_present_flag: true,
                 timing_info: %{
                   num_units_in_tick: 1,
                   time_scale: 60,
                   fixed_frame_rate_flag: false
                 },
                 nal_hrd_parameters_present_flag: false,
                 nal_hrd_parameters: %{},
                 vcl_hrd_parameters_present_flag: false,
                 vcl_hrd_parameters: %{},
                 low_delay_hrd_flag: false,
                 bitstream_restriction_flag: false,
                 bitstream_restriction_info: %{}
               }
             }
    end)
  end
end
