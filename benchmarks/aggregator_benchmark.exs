defmodule AggregatorBenchmark do
  alias Membrane.NALU
  alias Membrane.Buffer

  # Generate test NALU units as buffers (simulating parser output)
  defp generate_test_buffers(count) do
    for i <- 1..count do
      # Create different types of NALUs with realistic distribution
      {type, priority} = case rem(i, 10) do
        0 -> {9, 0}  # AUD (Access Unit Delimiter) - frame boundaries
        1 -> {7, 1}  # SPS (Sequence Parameter Set)
        2 -> {8, 1}  # PPS (Picture Parameter Set)
        3 -> {5, 2}  # IDR slice (keyframe)
        4 -> {1, 1}  # Non-IDR slice (P/B frame)
        _ -> {1, 1}  # More Non-IDR slices
      end

      header = %{
        type: %{id: get_type_id(type), code: type},
        priority: priority
      }

      payload_size = case type do
        7 -> Enum.random(50..100)   # SPS - smaller
        8 -> Enum.random(30..80)    # PPS - smaller
        9 -> 4                      # AUD - very small
        _ -> Enum.random(200..2000) # Slices - larger
      end

      payload = :crypto.strong_rand_bytes(payload_size)
      
      # Add timing info (realistic PTS/DTS values)
      pts = i * 40_000  # ~25fps (40ms per frame)
      dts = pts - Enum.random(0..80_000)  # B-frames can have reordering

      %Buffer{
        payload: payload,
        pts: pts,
        dts: dts,
        metadata: %{
          header: header,
          slice_header: (if type in [1, 5], do: %{type: %{id: :p}}, else: %{})
        }
      }
    end
  end

  defp get_type_id(type_code) do
    case type_code do
      1 -> :non_idr_slice
      5 -> :idr_slice
      6 -> :sei
      7 -> :sps
      8 -> :pps
      9 -> :aud
      _ -> :unknown
    end
  end

  # Generate buffers with AUD boundaries for testing aud alignment
  defp generate_aud_aligned_buffers(frame_count) do
    for frame <- 1..frame_count do
      frame_buffers = [
        # Start with AUD
        create_buffer(9, frame * 40_000),
        # Add SPS/PPS occasionally
        if rem(frame, 30) == 1 do
          [create_buffer(7, frame * 40_000), create_buffer(8, frame * 40_000)]
        else
          []
        end,
        # Add slices
        for _ <- 1..Enum.random(3..8) do
          type = if rem(frame, 15) == 1, do: 5, else: 1  # IDR every 15 frames
          create_buffer(type, frame * 40_000)
        end
      ]
      |> List.flatten()
      |> Enum.filter(& &1)
      
      frame_buffers  # Return the actual buffers
    end
    |> List.flatten()
  end

  defp create_buffer(type_code, pts) do
    %Buffer{
      payload: :crypto.strong_rand_bytes(Enum.random(50..500)),
      pts: pts,
      dts: pts,
      metadata: %{
        header: %{
          type: %{id: get_type_id(type_code), code: type_code},
          priority: 0
        },
        slice_header: %{}
      }
    }
  end

  # Simulate aggregator state and operations
  defp simulate_aggregator_nalu_mode(buffers) do
    # In NALU mode, each buffer is processed individually
    Enum.map(buffers, fn buffer ->
      timed_unit = %{
        payload: buffer.payload,
        header: buffer.metadata.header,
        slice_header: buffer.metadata.slice_header,
        pts: buffer.pts,
        dts: buffer.dts
      }
      
      # Simulate timed_units_to_buffer
      unit_ids = [timed_unit.header.type.id]
      is_keyframe = :idr_slice in unit_ids

      payload = NALU.format_units([timed_unit]) |> Enum.into(<<>>)

      %Buffer{
        payload: payload,
        pts: timed_unit.pts,
        dts: timed_unit.dts,
        metadata: %{
          is_keyframe?: is_keyframe,
          units: unit_ids
        }
      }
    end)
  end

  defp simulate_aggregator_aud_mode(buffers) do
    # Simulate the chunking logic for AUD alignment
    chunk_fun = fn
      buffer, [] when buffer.metadata.header.type.id == :aud ->
        timed_unit = buffer_to_timed_unit(buffer)
        {:cont, [timed_unit]}

      buffer, acc when buffer.metadata.header.type.id == :aud ->
        timed_unit = buffer_to_timed_unit(buffer)
        {:cont, Enum.reverse(acc), [timed_unit]}

      buffer, acc ->
        timed_unit = buffer_to_timed_unit(buffer)
        {:cont, [timed_unit | acc]}
    end

    after_fun = fn
      [] -> {:cont, []}
      acc -> {:cont, Enum.reverse(acc), []}
    end

    buffers
    |> Enum.map(&buffer_to_timed_unit/1)
    |> Enum.chunk_while([], chunk_fun, after_fun)
    |> Enum.map(fn units -> timed_units_to_buffer(units) end)
    |> Enum.reject(&is_nil/1)
  end

  defp buffer_to_timed_unit(%Buffer{} = buffer) do
    %{
      payload: buffer.payload,
      header: buffer.metadata.header,
      slice_header: buffer.metadata.slice_header,
      pts: buffer.pts,
      dts: buffer.dts
    }
  end
  
  # Handle case where buffer is already a timed unit
  defp buffer_to_timed_unit(unit) when is_map(unit) and not is_struct(unit) do
    unit
  end

  defp timed_units_to_buffer([]), do: nil
  defp timed_units_to_buffer([h | _] = timed_units) do
    unit_ids = Enum.map(timed_units, fn x -> x.header.type.id end)
    is_keyframe = :idr_slice in unit_ids

    payload = NALU.format_units(timed_units) |> Enum.into(<<>>)

    %Buffer{
      payload: payload,
      pts: h.pts,
      dts: h.dts,
      metadata: %{
        is_keyframe?: is_keyframe,
        units: unit_ids
      }
    }
  end

  def run do
    # Generate test data
    small_buffers = generate_test_buffers(50)
    medium_buffers = generate_test_buffers(200)
    large_buffers = generate_test_buffers(1000)
    aud_aligned_buffers = generate_aud_aligned_buffers(100)

    Benchee.run(
      %{
        # NALU alignment mode benchmarks
        "aggregator NALU mode (small)" => fn ->
          simulate_aggregator_nalu_mode(small_buffers)
        end,
        "aggregator NALU mode (medium)" => fn ->
          simulate_aggregator_nalu_mode(medium_buffers)
        end,
        "aggregator NALU mode (large)" => fn ->
          simulate_aggregator_nalu_mode(large_buffers)
        end,

        # AUD alignment mode benchmarks
        "aggregator AUD mode (small)" => fn ->
          simulate_aggregator_aud_mode(small_buffers)
        end,
        "aggregator AUD mode (medium)" => fn ->
          simulate_aggregator_aud_mode(medium_buffers)
        end,
        "aggregator AUD mode (AUD aligned)" => fn ->
          simulate_aggregator_aud_mode(aud_aligned_buffers)
        end,

        # Individual operations
        "buffer_to_timed_unit conversion" => fn ->
          Enum.map(medium_buffers, &buffer_to_timed_unit/1)
        end,

        "timed_units_to_buffer conversion" => fn ->
          timed_units = Enum.map(medium_buffers, &buffer_to_timed_unit/1)
          # Group by 5 to simulate frame grouping
          timed_units
          |> Enum.chunk_every(5)
          |> Enum.map(&timed_units_to_buffer/1)
        end,

        # Chunking operations (most expensive part)
        "Enum.chunk_while (AUD detection)" => fn ->
          timed_units = Enum.map(aud_aligned_buffers, &buffer_to_timed_unit/1)
          
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

          Enum.chunk_while(timed_units, [], chunk_fun, after_fun)
        end,

        # Format operations
        "NALU.format_units" => fn ->
          timed_units = Enum.take(Enum.map(medium_buffers, &buffer_to_timed_unit/1), 100)
          NALU.format_units(timed_units) |> Enum.into(<<>>)
        end,

        # Keyframe detection
        "keyframe detection (aggregator)" => fn ->
          timed_units = Enum.map(medium_buffers, &buffer_to_timed_unit/1)
          Enum.map(timed_units, fn unit ->
            :idr_slice == unit.header.type.id
          end)
        end,

        # Memory allocation patterns
        "list reversal overhead" => fn ->
          # Simulate the Enum.reverse operations in chunking
          lists = Enum.chunk_every(1..1000, 10)
          Enum.map(lists, &Enum.reverse/1)
        end,

        # Accumulator management
        "accumulator operations" => fn ->
          # Simulate the acc management in handle_buffer
          acc = []
          new_units = Enum.take(Enum.map(medium_buffers, &buffer_to_timed_unit/1), 50)
          
          full_acc = Enum.concat(acc, new_units)
          {_frames, _pending} = Enum.split(full_acc, -1)
        end
      },
      time: 10,
      memory_time: 2,
      reduction_time: 2,
      formatters: [
        Benchee.Formatters.Console
      ]
    )
  end
end

# Create results directory
File.mkdir_p("benchmarks/results")

# Run the benchmark
AggregatorBenchmark.run()