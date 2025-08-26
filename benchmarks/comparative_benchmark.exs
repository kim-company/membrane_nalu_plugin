defmodule ComparativeBenchmark do
  alias Membrane.NALU
  alias Membrane.Buffer

  # Use real H.264 data from test files
  defp load_test_data do
    real_data = File.read!("test/data/input.h264")
    
    %{
      small: binary_part(real_data, 0, min(10_000, byte_size(real_data))),
      medium: binary_part(real_data, 0, min(50_000, byte_size(real_data))),
      large: binary_part(real_data, 0, min(200_000, byte_size(real_data))),
      extra_large: real_data
    }
  end

  # Generate partial NALU data to test partial parsing scenarios
  defp generate_partial_data do
    real_data = File.read!("test/data/input.h264")
    split_point = div(byte_size(real_data), 3)
    <<part1::binary-size(split_point), part2::binary>> = real_data
    {part1, part2}
  end

  # Parse real data into individual NALUs for aligned testing
  defp generate_aligned_data do
    File.read!("test/data/input.h264")
    |> NALU.parse_units!(assume_aligned: false, preserve_original: true)
    |> Enum.take(100)
    |> Enum.map(fn unit -> 
      # Reform individual NALUs with their prefixes
      <<unit.prefix::binary, unit.original::binary>>
    end)
  end

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

  # Simulate aggregator operations
  defp simulate_aggregator_nalu_mode(buffers) do
    Enum.map(buffers, fn buffer ->
      timed_unit = %{
        payload: buffer.payload,
        header: buffer.metadata.header,
        slice_header: buffer.metadata.slice_header,
        pts: buffer.pts,
        dts: buffer.dts
      }
      
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

  def run_parser_benchmarks do
    IO.puts("=== PARSER PERFORMANCE COMPARISON ===\n")
    
    test_data = load_test_data()
    {partial_1, partial_2} = generate_partial_data()
    aligned_data = generate_aligned_data()

    Benchee.run(
      %{
        # Core parsing operations - these should show major improvements
        "parse_units! (small)" => fn -> 
          NALU.parse_units!(test_data.small) |> Enum.to_list()
        end,
        "parse_units! (medium)" => fn -> 
          NALU.parse_units!(test_data.medium) |> Enum.to_list()
        end,
        "parse_units! (large)" => fn -> 
          NALU.parse_units!(test_data.large) |> Enum.to_list()
        end,

        # This should show MASSIVE improvements (was 706x slower)
        "parse_units! (partial data)" => fn ->
          units1 = NALU.parse_units!(partial_1, assume_aligned: false) |> Enum.to_list()
          {_complete, [{:retry, remainder}]} = Enum.split_with(units1, fn
            {:retry, _} -> false
            _ -> true
          end)
          
          full_chunk = remainder <> partial_2
          NALU.parse_units!(full_chunk, assume_aligned: false) |> Enum.to_list()
        end,

        # Header parsing should show improvement from caching
        "header parsing only" => fn ->
          test_data.medium
          |> NALU.parse_units!()
          |> Enum.map(fn unit -> unit.header end)
          |> Enum.to_list()
        end,

        # Slice header parsing should be much faster
        "slice header parsing" => fn ->
          test_data.medium
          |> NALU.parse_units!()
          |> Enum.filter(fn unit -> 
            unit.header.type.id in [:non_idr_slice, :idr_slice]
          end)
          |> Enum.map(fn unit -> unit.slice_header end)
          |> Enum.to_list()
        end,

        # Keyframe detection
        "keyframe detection" => fn ->
          units = NALU.parse_units!(test_data.large) |> Enum.to_list()
          NALU.has_keyframe(units)
        end
      },
      time: 10,
      memory_time: 2,
      reduction_time: 2,
      formatters: [Benchee.Formatters.Console]
    )
  end

  def run_aggregator_benchmarks do
    IO.puts("\n=== AGGREGATOR PERFORMANCE COMPARISON ===\n")
    
    small_buffers = generate_test_buffers(50)
    medium_buffers = generate_test_buffers(200)
    large_buffers = generate_test_buffers(1000)

    Benchee.run(
      %{
        # Core aggregator operations - should show major improvements
        "aggregator NALU mode (small)" => fn ->
          simulate_aggregator_nalu_mode(small_buffers)
        end,
        "aggregator NALU mode (medium)" => fn ->
          simulate_aggregator_nalu_mode(medium_buffers)
        end,
        "aggregator NALU mode (large)" => fn ->
          simulate_aggregator_nalu_mode(large_buffers)
        end,

        # NALU formatting should be much faster with iodata
        "NALU.format_units (optimized)" => fn ->
          timed_units = Enum.take(Enum.map(medium_buffers, fn buffer ->
            %{
              payload: buffer.payload,
              header: buffer.metadata.header,
              slice_header: buffer.metadata.slice_header,
              pts: buffer.pts,
              dts: buffer.dts
            }
          end), 100)
          
          NALU.format_units(timed_units) |> Enum.into(<<>>)
        end,

        # Keyframe detection should show improvement
        "keyframe detection (aggregator)" => fn ->
          medium_buffers
          |> Enum.map(fn buffer -> 
            buffer.metadata.header.type.id == :idr_slice
          end)
        end
      },
      time: 10,
      memory_time: 2,
      reduction_time: 2,
      formatters: [Benchee.Formatters.Console]
    )
  end

  def run do
    IO.puts("🚀 RUNNING COMPARATIVE BENCHMARKS - OPTIMIZED VERSION\n")
    IO.puts("This will compare the performance after optimizations.\n")
    
    run_parser_benchmarks()
    run_aggregator_benchmarks()
    
    IO.puts("\n✅ BENCHMARK COMPLETE!")
    IO.puts("Compare these results with the original benchmarks to see improvements.")
  end
end

# Create results directory
File.mkdir_p("benchmarks/results")

# Run the comparative benchmark
ComparativeBenchmark.run()