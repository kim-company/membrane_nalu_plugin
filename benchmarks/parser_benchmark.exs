defmodule ParserBenchmark do
  alias Membrane.NALU

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

  def run do
    test_data = load_test_data()
    {partial_1, partial_2} = generate_partial_data()
    aligned_data = generate_aligned_data()

    Benchee.run(
      %{
        # Basic parsing operations
        "parse_units! (small)" => fn -> 
          NALU.parse_units!(test_data.small) |> Enum.to_list()
        end,
        "parse_units! (medium)" => fn -> 
          NALU.parse_units!(test_data.medium) |> Enum.to_list()
        end,
        "parse_units! (large)" => fn -> 
          NALU.parse_units!(test_data.large) |> Enum.to_list()
        end,
        "parse_units! (extra_large)" => fn -> 
          NALU.parse_units!(test_data.extra_large) |> Enum.to_list()
        end,

        # Aligned vs non-aligned parsing
        "parse_units! (aligned=true)" => fn ->
          aligned_data
          |> Enum.each(fn nalu -> 
            NALU.parse_units!(nalu, assume_aligned: true) |> Enum.to_list()
          end)
        end,
        "parse_units! (aligned=false)" => fn ->
          aligned_data
          |> Enum.each(fn nalu -> 
            NALU.parse_units!(nalu, assume_aligned: false) |> Enum.to_list()
          end)
        end,

        # Partial data scenarios (common in streaming)
        "parse_units! (partial data)" => fn ->
          # Simulate receiving data in chunks
          units1 = NALU.parse_units!(partial_1, assume_aligned: false) |> Enum.to_list()
          # Filter out retry units and extract partial data
          {_complete, [{:retry, remainder}]} = Enum.split_with(units1, fn
            {:retry, _} -> false
            _ -> true
          end)
          
          # Process second chunk with remainder
          full_chunk = remainder <> partial_2
          NALU.parse_units!(full_chunk, assume_aligned: false) |> Enum.to_list()
        end,

        # Header parsing performance
        "header parsing only" => fn ->
          test_data.medium
          |> NALU.parse_units!()
          |> Enum.map(fn unit -> unit.header end)
          |> Enum.to_list()
        end,

        # Slice header parsing (more expensive)
        "slice header parsing" => fn ->
          test_data.medium
          |> NALU.parse_units!()
          |> Enum.filter(fn unit -> 
            unit.header.type.id in [:non_idr_slice, :idr_slice]
          end)
          |> Enum.map(fn unit -> unit.slice_header end)
          |> Enum.to_list()
        end,

        # Memory allocation patterns
        "stream vs enum" => fn ->
          # Compare Stream (lazy) vs Enum (eager) processing
          test_data.large
          |> NALU.parse_units!()
          |> Stream.take(100)
          |> Enum.to_list()
        end,

        # Keyframe detection performance
        "keyframe detection" => fn ->
          units = NALU.parse_units!(test_data.large) |> Enum.to_list()
          NALU.has_keyframe(units)
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
ParserBenchmark.run()