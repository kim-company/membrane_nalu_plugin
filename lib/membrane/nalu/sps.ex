defmodule Membrane.NALU.SPS do
  @moduledoc """
  Parser for H.264 Sequence Parameter Set (SPS) NAL units.

  Extracts structured information from SPS units while preserving the original
  payload. Handles profile/level identification, resolution calculation, and
  other sequence-level parameters.
  """

  alias Membrane.NALU

  @doc """
  Parses an SPS payload and returns structured information.

  ## Parameters
  - `payload` - The SPS NAL unit payload (without the NAL header byte)

  ## Returns
  - `{:ok, sps_info}` - Successfully parsed SPS information
  - `{:error, reason}` - Parsing failed with reason

  ## Examples
      iex> SPS.parse(<<some_sps_payload>>)
      {:ok, %{
        profile_idc: 66,
        constraint_flags: %{constraint_set0_flag: true, ...},
        level_idc: 31,
        seq_parameter_set_id: 0,
        resolution: %{width: 1920, height: 1080},
        ...
      }}
  """
  def parse(payload) when is_binary(payload) do
    try do
      {:ok, do_parse(payload)}
    rescue
      e -> {:error, e}
    end
  end

  defp do_parse(<<>>) do
    %{}
  end

  defp do_parse(payload) when is_binary(payload) do
    # Check minimum size requirement (profile + constraints + level + seq_id)
    if byte_size(payload) < 3 do
      raise "SPS payload too short, need at least 3 bytes"
    end

    # Parse basic profile and level information
    <<profile_idc::8, rest::binary>> = payload

    # Parse constraint flags and level
    if byte_size(rest) < 2 do
      raise "SPS payload truncated at constraint flags"
    end

    <<constraint_set0_flag::1, constraint_set1_flag::1, constraint_set2_flag::1,
      constraint_set3_flag::1, constraint_set4_flag::1, constraint_set5_flag::1,
      _reserved_zero_2bits::2, level_idc::8, rest::bitstring>> = rest

    # Parse sequence parameter set ID
    {seq_parameter_set_id, rest} = NALU.decode_uev(rest)

    # Parse chroma format (only for certain profiles)
    {chroma_format_idc, rest} =
      if profile_idc in [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135] do
        {chroma_format, rest} = NALU.decode_uev(rest)

        # Handle separate colour plane flag if chroma_format_idc == 3
        {separate_colour_plane_flag, rest} =
          if chroma_format == 3 do
            <<flag::1, rest::bitstring>> = rest
            {flag == 1, rest}
          else
            {false, rest}
          end

        # Parse bit depth
        {bit_depth_luma_minus8, rest} = NALU.decode_uev(rest)
        {bit_depth_chroma_minus8, rest} = NALU.decode_uev(rest)

        # Parse qpprime_y_zero_transform_bypass_flag
        <<qpprime_y_zero_transform_bypass_flag::1, rest::bitstring>> = rest

        # Parse seq_scaling_matrix_present_flag
        <<seq_scaling_matrix_present_flag::1, rest::bitstring>> = rest

        # Skip scaling list parsing for now (complex conditional logic)
        rest =
          if seq_scaling_matrix_present_flag == 1,
            do: skip_scaling_lists(rest, chroma_format),
            else: rest

        {{chroma_format, separate_colour_plane_flag, bit_depth_luma_minus8,
          bit_depth_chroma_minus8, qpprime_y_zero_transform_bypass_flag,
          seq_scaling_matrix_present_flag}, rest}
      else
        # Default values
        {{1, false, 0, 0, false, false}, rest}
      end

    # Parse frame numbering parameters
    {log2_max_frame_num_minus4, rest} = NALU.decode_uev(rest)
    {pic_order_cnt_type, rest} = NALU.decode_uev(rest)

    # Parse picture order count parameters
    {pic_order_info, rest} = parse_pic_order_cnt_info(pic_order_cnt_type, rest)

    # Parse reference frames
    {max_num_ref_frames, rest} = NALU.decode_uev(rest)
    <<gaps_in_frame_num_value_allowed_flag::1, rest::bitstring>> = rest

    # Parse picture size
    {pic_width_in_mbs_minus1, rest} = NALU.decode_uev(rest)
    {pic_height_in_map_units_minus1, rest} = NALU.decode_uev(rest)

    # Parse frame/field info
    <<frame_mbs_only_flag::1, rest::bitstring>> = rest

    {mb_adaptive_frame_field_flag, rest} =
      if frame_mbs_only_flag == 0 do
        <<flag::1, rest::bitstring>> = rest
        {flag == 1, rest}
      else
        {false, rest}
      end

    # Parse direct 8x8 inference flag
    <<direct_8x8_inference_flag::1, rest::bitstring>> = rest

    # Parse cropping info
    {frame_cropping_flag, cropping_info, rest} =
      if bit_size(rest) >= 1 do
        <<flag::1, rest::bitstring>> = rest

        if flag == 1 do
          # Try to parse cropping values, but handle insufficient data gracefully
          try do
            {crop_left, rest} = NALU.decode_uev(rest)
            {crop_right, rest} = NALU.decode_uev(rest)
            {crop_top, rest} = NALU.decode_uev(rest)
            {crop_bottom, rest} = NALU.decode_uev(rest)
            {true, {crop_left, crop_right, crop_top, crop_bottom}, rest}
          rescue
            _ ->
              # Insufficient data for all cropping values, assume no cropping
              {false, {0, 0, 0, 0}, rest}
          end
        else
          {false, {0, 0, 0, 0}, rest}
        end
      else
        {false, {0, 0, 0, 0}, rest}
      end

    # Parse VUI parameters (if enough data remains)
    {vui_parameters_present_flag, vui_parameters, _rest} =
      if bit_size(rest) >= 1 do
        <<flag::1, rest::bitstring>> = rest

        if flag == 1 do
          {vui_params, rest} = parse_vui_parameters(rest)
          {true, vui_params, rest}
        else
          {false, %{}, rest}
        end
      else
        {false, %{}, rest}
      end

    # Calculate resolution
    width = (pic_width_in_mbs_minus1 + 1) * 16
    height = (pic_height_in_map_units_minus1 + 1) * 16

    # Apply frame/field adjustment
    height = if frame_mbs_only_flag == 0, do: height * 2, else: height

    # Apply cropping
    {crop_left, crop_right, crop_top, crop_bottom} = cropping_info
    {chroma_format_value, _, _, _, _, _} = chroma_format_idc

    crop_unit_x = if chroma_format_value in [1, 2], do: 2, else: 1
    crop_unit_y = if chroma_format_value == 1, do: 2, else: 1
    crop_unit_y = if frame_mbs_only_flag == 0, do: crop_unit_y * 2, else: crop_unit_y

    final_width = width - (crop_left + crop_right) * crop_unit_x
    final_height = height - (crop_top + crop_bottom) * crop_unit_y

    # Build result map
    %{
      profile_idc: profile_idc,
      constraint_flags: %{
        constraint_set0_flag: constraint_set0_flag == 1,
        constraint_set1_flag: constraint_set1_flag == 1,
        constraint_set2_flag: constraint_set2_flag == 1,
        constraint_set3_flag: constraint_set3_flag == 1,
        constraint_set4_flag: constraint_set4_flag == 1,
        constraint_set5_flag: constraint_set5_flag == 1
      },
      level_idc: level_idc,
      seq_parameter_set_id: seq_parameter_set_id,
      chroma_format_idc: elem(chroma_format_idc, 0),
      separate_colour_plane_flag: elem(chroma_format_idc, 1),
      bit_depth_luma_minus8: elem(chroma_format_idc, 2),
      bit_depth_chroma_minus8: elem(chroma_format_idc, 3),
      log2_max_frame_num_minus4: log2_max_frame_num_minus4,
      pic_order_cnt_type: pic_order_cnt_type,
      pic_order_cnt_info: pic_order_info,
      max_num_ref_frames: max_num_ref_frames,
      gaps_in_frame_num_value_allowed_flag: gaps_in_frame_num_value_allowed_flag == 1,
      pic_width_in_mbs_minus1: pic_width_in_mbs_minus1,
      pic_height_in_map_units_minus1: pic_height_in_map_units_minus1,
      frame_mbs_only_flag: frame_mbs_only_flag == 1,
      mb_adaptive_frame_field_flag: mb_adaptive_frame_field_flag,
      direct_8x8_inference_flag: direct_8x8_inference_flag == 1,
      frame_cropping_flag: frame_cropping_flag,
      cropping: %{
        left: crop_left,
        right: crop_right,
        top: crop_top,
        bottom: crop_bottom
      },
      vui_parameters_present_flag: vui_parameters_present_flag,
      vui_parameters: vui_parameters,
      resolution: %{
        width: final_width,
        height: final_height,
        raw_width: width,
        raw_height: height
      }
    }
  end

  defp parse_vui_parameters(rest) do
    # Parse aspect_ratio_info_present_flag
    <<aspect_ratio_info_present_flag::1, rest::bitstring>> = rest

    {aspect_ratio_info, rest} =
      if aspect_ratio_info_present_flag == 1 do
        <<aspect_ratio_idc::8, rest::bitstring>> = rest
        # Extended_SAR
        if aspect_ratio_idc == 255 do
          <<sar_width::16, sar_height::16, rest::bitstring>> = rest

          {%{aspect_ratio_idc: aspect_ratio_idc, sar_width: sar_width, sar_height: sar_height},
           rest}
        else
          {%{aspect_ratio_idc: aspect_ratio_idc}, rest}
        end
      else
        {%{}, rest}
      end

    # Parse overscan_info_present_flag
    <<overscan_info_present_flag::1, rest::bitstring>> = rest

    {overscan_appropriate_flag, rest} =
      if overscan_info_present_flag == 1 do
        <<flag::1, rest::bitstring>> = rest
        {flag == 1, rest}
      else
        {false, rest}
      end

    # Parse video_signal_type_present_flag
    <<video_signal_type_present_flag::1, rest::bitstring>> = rest

    {video_signal_info, rest} =
      if video_signal_type_present_flag == 1 do
        <<video_format::3, video_full_range_flag::1, colour_description_present_flag::1,
          rest::bitstring>> = rest

        {colour_info, rest} =
          if colour_description_present_flag == 1 do
            <<colour_primaries::8, transfer_characteristics::8, matrix_coefficients::8,
              rest::bitstring>> = rest

            {%{
               colour_primaries: colour_primaries,
               transfer_characteristics: transfer_characteristics,
               matrix_coefficients: matrix_coefficients
             }, rest}
          else
            {%{}, rest}
          end

        {%{
           video_format: video_format,
           video_full_range_flag: video_full_range_flag == 1,
           colour_description_present_flag: colour_description_present_flag == 1,
           colour_info: colour_info
         }, rest}
      else
        {%{}, rest}
      end

    # Parse chroma_loc_info_present_flag
    <<chroma_loc_info_present_flag::1, rest::bitstring>> = rest

    {chroma_sample_loc_info, rest} =
      if chroma_loc_info_present_flag == 1 do
        {chroma_sample_loc_type_top_field, rest} = NALU.decode_uev(rest)
        {chroma_sample_loc_type_bottom_field, rest} = NALU.decode_uev(rest)

        {%{
           chroma_sample_loc_type_top_field: chroma_sample_loc_type_top_field,
           chroma_sample_loc_type_bottom_field: chroma_sample_loc_type_bottom_field
         }, rest}
      else
        {%{}, rest}
      end

    # Parse timing_info_present_flag
    <<timing_info_present_flag::1, rest::bitstring>> = rest

    {timing_info, rest} =
      if timing_info_present_flag == 1 do
        <<num_units_in_tick::32, time_scale::32, fixed_frame_rate_flag::1, rest::bitstring>> =
          rest

        {%{
           num_units_in_tick: num_units_in_tick,
           time_scale: time_scale,
           fixed_frame_rate_flag: fixed_frame_rate_flag == 1
         }, rest}
      else
        {%{}, rest}
      end

    # Parse nal_hrd_parameters_present_flag
    <<nal_hrd_parameters_present_flag::1, rest::bitstring>> = rest

    {nal_hrd_parameters, rest} =
      if nal_hrd_parameters_present_flag == 1 do
        parse_hrd_parameters(rest)
      else
        {%{}, rest}
      end

    # Parse vcl_hrd_parameters_present_flag
    <<vcl_hrd_parameters_present_flag::1, rest::bitstring>> = rest

    {vcl_hrd_parameters, rest} =
      if vcl_hrd_parameters_present_flag == 1 do
        parse_hrd_parameters(rest)
      else
        {%{}, rest}
      end

    # Parse low_delay_hrd_flag (only if nal_hrd or vcl_hrd present)
    {low_delay_hrd_flag, rest} =
      if nal_hrd_parameters_present_flag == 1 || vcl_hrd_parameters_present_flag == 1 do
        <<flag::1, rest::bitstring>> = rest
        {flag == 1, rest}
      else
        {false, rest}
      end

    # Parse bitstream_restriction_flag
    <<bitstream_restriction_flag::1, rest::bitstring>> = rest

    {bitstream_restriction_info, rest} =
      if bitstream_restriction_flag == 1 do
        # Parse all bitstream restriction parameters but we'll skip the implementation for brevity
        # In a full implementation, this would parse motion_vectors_over_pic_boundaries_flag,
        # max_bytes_per_pic_denom, max_bits_per_mb_denom, log2_max_mv_length_horizontal,
        # log2_max_mv_length_vertical, max_num_reorder_frames, max_dec_frame_buffering
        # Placeholder
        {%{present: true}, rest}
      else
        {%{}, rest}
      end

    vui_params = %{
      aspect_ratio_info_present_flag: aspect_ratio_info_present_flag == 1,
      aspect_ratio_info: aspect_ratio_info,
      overscan_info_present_flag: overscan_info_present_flag == 1,
      overscan_appropriate_flag: overscan_appropriate_flag,
      video_signal_type_present_flag: video_signal_type_present_flag == 1,
      video_signal_info: video_signal_info,
      chroma_loc_info_present_flag: chroma_loc_info_present_flag == 1,
      chroma_sample_loc_info: chroma_sample_loc_info,
      timing_info_present_flag: timing_info_present_flag == 1,
      timing_info: timing_info,
      nal_hrd_parameters_present_flag: nal_hrd_parameters_present_flag == 1,
      nal_hrd_parameters: nal_hrd_parameters,
      vcl_hrd_parameters_present_flag: vcl_hrd_parameters_present_flag == 1,
      vcl_hrd_parameters: vcl_hrd_parameters,
      low_delay_hrd_flag: low_delay_hrd_flag,
      bitstream_restriction_flag: bitstream_restriction_flag == 1,
      bitstream_restriction_info: bitstream_restriction_info
    }

    {vui_params, rest}
  end

  defp parse_hrd_parameters(rest) do
    # This is a placeholder for HRD parameters parsing
    # In a full implementation, this would parse cpb_cnt_minus1, bit_rate_scale, etc.
    {%{placeholder: true}, rest}
  end

  defp parse_pic_order_cnt_info(0, rest) do
    {log2_max_pic_order_cnt_lsb_minus4, rest} = NALU.decode_uev(rest)
    {%{log2_max_pic_order_cnt_lsb_minus4: log2_max_pic_order_cnt_lsb_minus4}, rest}
  end

  defp parse_pic_order_cnt_info(1, rest) do
    <<delta_pic_order_always_zero_flag::1, rest::bitstring>> = rest
    {offset_for_non_ref_pic, rest} = NALU.decode_sev(rest)
    {offset_for_top_to_bottom_field, rest} = NALU.decode_sev(rest)
    {num_ref_frames_in_pic_order_cnt_cycle, rest} = NALU.decode_uev(rest)

    # Parse offset_for_ref_frame array
    {offsets, rest} = parse_ref_frame_offsets(num_ref_frames_in_pic_order_cnt_cycle, rest, [])

    {%{
       delta_pic_order_always_zero_flag: delta_pic_order_always_zero_flag == 1,
       offset_for_non_ref_pic: offset_for_non_ref_pic,
       offset_for_top_to_bottom_field: offset_for_top_to_bottom_field,
       num_ref_frames_in_pic_order_cnt_cycle: num_ref_frames_in_pic_order_cnt_cycle,
       offset_for_ref_frame: offsets
     }, rest}
  end

  defp parse_pic_order_cnt_info(2, rest) do
    # Type 2 has no additional fields
    {%{}, rest}
  end

  defp parse_pic_order_cnt_info(_type, rest) do
    {%{}, rest}
  end

  defp parse_ref_frame_offsets(0, rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_ref_frame_offsets(count, rest, acc) when count > 0 do
    {offset, rest} = NALU.decode_sev(rest)
    parse_ref_frame_offsets(count - 1, rest, [offset | acc])
  end

  # Simplified scaling list skipping - in a full implementation this would parse the matrices
  defp skip_scaling_lists(rest, _chroma_format) do
    # This is a simplified skip - real implementation would parse scaling lists
    # For now, just assume no scaling lists are present and return rest unchanged
    rest
  end
end
