# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Membrane NALU Plugin, an Elixir library that provides NALU (Network Abstraction Layer Unit) parsing and aggregation functionality for the Membrane multimedia framework. It handles H.264 video stream processing, specifically parsing and formatting NAL units using the Annex-B standard.

## Development Commands

### Core Commands
- `mix compile` - Compile the project
- `mix test` - Run all tests
- `mix format` - Format code according to project standards
- `mix docs` - Generate documentation
- `mix deps.get` - Fetch dependencies

### Testing
- `mix test` - Run all tests
- `mix test test/membrane/nalu_test.exs` - Run specific test file
- `mix test --cover` - Run tests with coverage report

## Architecture

### Core Modules

**`Membrane.NALU`** (`lib/membrane/nalu.ex`)
- Main module containing NALU type definitions and utility functions
- Defines NALU unit types (IDR slice, SPS, PPS, AUD, SEI, etc.) with H.264 standard mappings
- Provides `parse_units!/2` for parsing AnnexB payloads into structured NALU units
- Handles slice header parsing and Exponential-Golomb decoding
- Contains SEI message encoding functions for captions and metadata

**`Membrane.NALU.Parser`** (`lib/membrane/nalu/parser.ex`)
- Membrane Filter that converts raw H.264 streams into individual NALU units
- Supports both aligned (complete units per buffer) and unaligned input modes
- Manages partial unit buffering for stream boundary handling
- Outputs individual NALU units with parsed headers and metadata

**`Membrane.NALU.Aggregator`** (`lib/membrane/nalu/aggregator.ex`)
- Membrane Filter that groups NALU units back into frames or access units
- Two aggregation modes: `:aud` (groups by Access Unit Delimiter) and `:nalu` (individual units)
- Handles keyframe detection and PTS/DTS propagation
- Manages frame boundary detection for proper video packetization

**`Membrane.NALU.AnnexB`** (`lib/membrane/nalu/annexb.ex`)
- Low-level AnnexB format parser implementing H.264 byte stream parsing
- Handles start code detection (0x000001 and 0x0000001 prefixes)
- Manages RBSP escaping/unescaping for emulation prevention
- Stream-based parsing with partial unit retry mechanism

**`Membrane.NALU.Format`** (`lib/membrane/nalu/format.ex`)
- Format definition struct for NALU streams
- Specifies alignment (how units are grouped) and standard (AnnexB)

**`Membrane.NALU.RBSP`** (`lib/membrane/nalu/rbsp.ex`)
- Raw Byte Sequence Payload handling for H.264 emulation prevention
- Escape/unescape functions for 0x000003 byte insertion/removal

### Data Flow Architecture

1. **Raw H.264 Stream** → `NALU.Parser` → **Individual NALU units with metadata**
2. **NALU units** → `NALU.Aggregator` → **Grouped frames/access units**
3. **NALU units** → `NALU.format_units/1` → **AnnexB byte stream**

The plugin operates as Membrane filters within a processing pipeline, transforming between different representations of H.264 video data.

## Key Concepts

- **NALU Types**: IDR slices (keyframes), non-IDR slices (P/B frames), SPS/PPS (parameter sets), AUD (access unit delimiters), SEI (supplemental info)
- **AnnexB Format**: H.264 byte stream format with start codes (0x000001/0x0000001)
- **RBSP**: Raw Byte Sequence Payload with emulation prevention (0x000003 escaping)
- **Access Units**: Groups of NALU units representing complete video frames
- **Keyframe Detection**: Based on presence of IDR slice NALU units

## Dependencies

- `membrane_core` ~> 1.2 - Core Membrane framework
- `membrane_file_plugin` ~> 0.17 (test only) - File I/O for testing
- `ex_doc` (dev only) - Documentation generation

## Environment Setup

The project uses mise for version management:
- Elixir 1.18.3-otp-27
- Erlang 27.2.1

Install with: `mise install`