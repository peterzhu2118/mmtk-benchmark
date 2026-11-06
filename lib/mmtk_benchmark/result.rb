# frozen_string_literal: true

require "json"
require "time"

module MMTkBenchmark
  VARIANTS = {
    "baseline" => {
      "label" => "Ruby",
      "description" => "Ruby without modular GC",
      "environment" => {},
    },
    "modular_default" => {
      "label" => "Modular GC (default)",
      "description" => "Ruby configured with modular GC, using the default GC",
      "environment" => {},
    },
    "mmtk_dynamic" => {
      "label" => "MMTk (dynamic)",
      "description" => "StickyImmix with MemBalancer heap sizing",
      "environment" => {
        "RUBY_GC_LIBRARY" => "mmtk",
        "MMTK_PLAN" => "StickyImmix",
        "MMTK_HEAP_MODE" => "dynamic",
      },
    },
    "mmtk_ruby" => {
      "label" => "MMTk (ruby)",
      "description" => "StickyImmix with Ruby-style free-slot heap sizing",
      "environment" => {
        "RUBY_GC_LIBRARY" => "mmtk",
        "MMTK_PLAN" => "StickyImmix",
        "MMTK_HEAP_MODE" => "ruby",
      },
    },
    "mmtk_cpu" => {
      "label" => "MMTk (cpu)",
      "description" => "StickyImmix with GC CPU-overhead heap sizing",
      "environment" => {
        "RUBY_GC_LIBRARY" => "mmtk",
        "MMTK_PLAN" => "StickyImmix",
        "MMTK_HEAP_MODE" => "cpu",
      },
    },
  }.freeze

  CATEGORY_ORDER = %w[headline other micro gc].freeze
  CATEGORY_LABELS = {
    "headline" => "Headline Benchmarks",
    "other" => "Other Benchmarks",
    "micro" => "MicroBenchmarks",
    "gc" => "GC Benchmarks",
  }.freeze

  # Converts ruby-bench's raw JSON into a compact, versioned website result.
  class ResultBuilder
    def self.build(date:, ruby:, ruby_bench:, benchmark_metadata:, raw:, configuration:, hardware:)
      new(
        date: date,
        ruby: ruby,
        ruby_bench: ruby_bench,
        benchmark_metadata: benchmark_metadata,
        raw: raw,
        configuration: configuration,
        hardware: hardware,
      ).build
    end

    def initialize(date:, ruby:, ruby_bench:, benchmark_metadata:, raw:, configuration:, hardware:)
      @date = date
      @ruby = ruby
      @ruby_bench = ruby_bench
      @benchmark_metadata = benchmark_metadata
      @raw = raw
      @configuration = configuration
      @hardware = hardware
    end

    def build
      raw_benchmarks = @raw.fetch("raw_data")
      names = raw_benchmarks.values.flat_map(&:keys).uniq
      names.sort_by! do |name|
        metadata = @benchmark_metadata.fetch(name, {})
        [CATEGORY_ORDER.index(metadata.fetch("category", "other")) || CATEGORY_ORDER.length, name]
      end

      benchmarks = names.each_with_object({}) do |name, output|
        metadata = @benchmark_metadata.fetch(name, {})
        results = VARIANTS.keys.each_with_object({}) do |variant, values|
          measurement = raw_benchmarks.dig(variant, name)
          values[variant] = serialize_measurement(measurement) if measurement
        end
        next if results.empty?

        output[name] = {
          "category" => metadata.fetch("category", "other"),
          "description" => metadata.fetch("desc", name),
          "results" => results,
        }
      end

      variants = VARIANTS.each_with_object({}) do |(name, metadata), output|
        output[name] = deep_copy(metadata).merge(
          "ruby_description" => @raw.dig("metadata", name),
        )
      end

      {
        "schema_version" => 1,
        "date" => @date,
        "measured_at" => Time.now.utc.iso8601,
        "ruby" => @ruby,
        "ruby_bench" => @ruby_bench,
        "configuration" => @configuration,
        "hardware" => @hardware,
        "variants" => variants,
        "benchmarks" => benchmarks,
      }
    end

    private

    def serialize_measurement(data)
      samples = data.fetch("bench", []).map(&:to_f)
      return if samples.empty?

      rss_samples = data.fetch("rss_samples", []).map(&:to_f)
      retained_rss = positive_number(data["rss"])
      mean_rss = if rss_samples.empty?
        retained_rss
      else
        mean(rss_samples)
      end

      {
        "time_seconds" => mean(samples),
        "time_stddev_percent" => stddev_percent(samples),
        "time_samples_seconds" => samples,
        "warmup_samples_seconds" => data.fetch("warmup", []).map(&:to_f),
        "iteration_count" => samples.length,
        "mean_rss_bytes" => mean_rss,
        "retained_rss_bytes" => retained_rss,
        "rss_samples_bytes" => rss_samples,
        "max_rss_bytes" => positive_number(data["maxrss"]),
      }
    end

    def mean(values)
      values.sum / values.length.to_f
    end

    def stddev_percent(values)
      return 0.0 if values.length < 2

      average = mean(values)
      return 0.0 if average.zero?

      variance = values.sum { |value| (value - average)**2 } / values.length.to_f
      Math.sqrt(variance) * 100.0 / average
    end

    def positive_number(value)
      number = value&.to_f
      number if number&.positive?
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end

  module ResultIndex
    module_function

    def generate(data_dir)
      results_dir = File.join(data_dir, "results")
      runs = []
      variants = {}

      Dir[File.join(results_dir, "*.json")].sort.each do |path|
        result = JSON.parse(File.read(path))
        variants.merge!(result.fetch("variants"))
        runs << {
          "date" => result.fetch("date"),
          "path" => "results/#{File.basename(path)}",
          "ruby_revision" => result.dig("ruby", "revision"),
          "ruby_committed_at" => result.dig("ruby", "committed_at"),
          "ruby_bench_revision" => result.dig("ruby_bench", "revision"),
          "benchmark_count" => result.fetch("benchmarks").length,
        }
      end

      index = {
        "schema_version" => 1,
        "frequency" => "weekly",
        "plan" => "StickyImmix",
        "generated_at" => Time.now.utc.iso8601,
        "variants" => variants,
        "runs" => runs,
      }
      atomic_write(File.join(data_dir, "index.json"), JSON.pretty_generate(index) + "\n")
      index
    end

    def write_result(data_dir, date, result)
      results_dir = File.join(data_dir, "results")
      require "fileutils"
      FileUtils.mkdir_p(results_dir)
      path = File.join(results_dir, "#{date}.json")
      atomic_write(path, JSON.pretty_generate(result) + "\n")
      path
    end

    def atomic_write(path, contents)
      temporary = "#{path}.tmp-#{Process.pid}"
      File.write(temporary, contents)
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if File.exist?(temporary)
    end
  end
end
