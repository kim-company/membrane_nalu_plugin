defmodule Membrane.NALU.SPSTest do
  use ExUnit.Case, async: true

  alias Membrane.NALU.SPS

  # SPS fixtures - RBSP-unescaped payloads without NAL header byte
  # Extracted from real test data using existing NALU parsing code
  @real_sps Base.decode64!("ZAAfrNlAUAW7ARAAAAAQAAADwPGDGWA=")

  @all_fixtures [@real_sps]

  describe "parse/1" do
    test "parses real SPS data from test file" do
      assert {:ok, sps} = SPS.parse(@real_sps)

      assert sps == %{
               profile_idc: 100,
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
               resolution: %{width: 1280, height: 720, raw_height: 720, raw_width: 1280},
               separate_colour_plane_flag: false,
               seq_parameter_set_id: 0,
               vui_parameters_present_flag: true,
               vui_parameters: %{
                 aspect_ratio_info_present_flag: true,
                 aspect_ratio_info: %{aspect_ratio_idc: 1},
                 overscan_info_present_flag: false,
                 overscan_appropriate_flag: false,
                 video_signal_type_present_flag: false,
                 video_signal_info: %{},
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
    end

    test "handles all fixture SPS payloads" do
      @all_fixtures
      |> Enum.with_index()
      |> Enum.each(fn {sps_payload, index} ->
        case SPS.parse(sps_payload) do
          {:ok, result} ->
            assert is_map(result)

          {:error, reason} ->
            assert false, "Fixture #{index} parsing failed: #{inspect(reason)}"
        end
      end)
    end

    test "handles empty payload gracefully" do
      assert {:ok, sps} = SPS.parse(<<>>)
      assert sps == %{}
    end

    test "validates SPS fixture data integrity" do
      # Verify our fixtures are correctly formed
      assert byte_size(@real_sps) > 3
      assert is_binary(@real_sps)
    end

    test "fixture payloads have valid SPS structure" do
      @all_fixtures
      |> Enum.each(fn payload ->
        # Should have at least profile_idc + constraint flags + level_idc + seq_parameter_set_id
        assert byte_size(payload) >= 4

        # Basic structure validation - profile_idc should be reasonable
        <<profile_idc, _rest::binary>> = payload
        # Valid H.264 profile range
        assert profile_idc in 66..244
      end)
    end
  end
end
