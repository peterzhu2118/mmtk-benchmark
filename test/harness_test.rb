# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/mmtk_benchmark"

class ResultBuilderTest < Minitest::Test
  def test_builds_raw_samples_and_derived_statistics
    raw = {
      "metadata" => { "baseline" => "ruby test" },
      "raw_data" => {
        "baseline" => {
          "psych-load" => {
            "warmup" => [1.0],
            "bench" => [2.0, 4.0],
            "rss_samples" => [1024 * 1024, 3 * 1024 * 1024],
            "rss" => 1024 * 1024,
            "maxrss" => 4 * 1024 * 1024,
          },
        },
        "mmtk_dynamic" => {
          "psych-load" => {
            "warmup" => [0.5],
            "bench" => [1.0, 2.0],
            "rss" => 2 * 1024 * 1024,
          },
        },
      },
    }

    result = MMTkBenchmark::ResultBuilder.build(
      date: "2026-11-05",
      ruby: { "revision" => "a" * 40 },
      ruby_bench: { "revision" => "b" * 40 },
      benchmark_metadata: { "psych-load" => { "category" => "headline", "desc" => "Loads YAML" } },
      raw: raw,
      configuration: { "plan" => "StickyImmix" },
      hardware: { "processor" => "Test CPU" },
    )

    benchmark = result.fetch("benchmarks").fetch("psych-load")
    assert_equal "headline", benchmark.fetch("category")
    assert_equal "Loads YAML", benchmark.fetch("description")
    baseline = benchmark.fetch("results").fetch("baseline")
    assert_equal 3.0, baseline.fetch("time_seconds")
    assert_in_delta 33.33, baseline.fetch("time_stddev_percent"), 0.01
    assert_equal [2.0, 4.0], baseline.fetch("time_samples_seconds")
    assert_equal 2 * 1024 * 1024, baseline.fetch("mean_rss_bytes")
    dynamic = benchmark.fetch("results").fetch("mmtk_dynamic")
    assert_equal 1.5, dynamic.fetch("time_seconds")
    assert_equal 2 * 1024 * 1024, dynamic.fetch("mean_rss_bytes")
    assert_nil dynamic.fetch("max_rss_bytes")
    assert_equal "StickyImmix", result.dig("variants", "mmtk_cpu", "environment", "MMTK_PLAN")
  end

  def test_skips_measurements_without_timed_iterations
    raw = {
      "metadata" => {},
      "raw_data" => {
        "baseline" => { "broken" => { "bench" => [] } },
        "mmtk_dynamic" => { "working" => { "bench" => [0.25] } },
      },
    }
    result = MMTkBenchmark::ResultBuilder.build(
      date: "2026-11-05", ruby: {}, ruby_bench: {}, raw: raw,
      benchmark_metadata: {}, configuration: {}, hardware: {},
    )

    assert_nil result.dig("benchmarks", "broken", "results", "baseline")
    assert_equal 0.25, result.dig("benchmarks", "working", "results", "mmtk_dynamic", "time_seconds")
  end
end

class ResultIndexTest < Minitest::Test
  def test_writes_sorted_index_and_relative_result_paths
    Dir.mktmpdir do |directory|
      %w[2026-11-05 2026-10-29].each do |date|
        result = {
          "date" => date,
          "ruby" => { "revision" => "a" * 40, "committed_at" => "#{date}T00:00:00Z" },
          "ruby_bench" => { "revision" => "b" * 40 },
          "variants" => MMTkBenchmark::VARIANTS,
          "benchmarks" => { "fib" => {} },
        }
        MMTkBenchmark::ResultIndex.write_result(directory, date, result)
      end
      index = MMTkBenchmark::ResultIndex.generate(directory)

      assert_equal %w[2026-10-29 2026-11-05], index.fetch("runs").map { |run| run.fetch("date") }
      assert_equal "results/2026-11-05.json", index.fetch("runs").last.fetch("path")
      assert_equal "weekly", index.fetch("frequency")
      assert_equal 1, index.fetch("runs").last.fetch("benchmark_count")
      assert File.exist?(File.join(directory, "index.json"))
    end
  end
end

class OptionsTest < Minitest::Test
  def test_defaults_to_headline_benchmarks
    assert_equal ["headline"], MMTkBenchmark::Options.parse([]).categories
  end

  def test_quick_sets_short_measurement_window_and_preserves_filters
    options = MMTkBenchmark::Options.parse(["--quick", "--weeks", "2", "fib"])
    assert_equal 2, options.warmup
    assert_equal 3, options.iterations
    assert_equal 0, options.min_time
    assert_equal 2, options.weeks
    assert_equal ["fib"], options.benchmarks
  end

  def test_rejects_invalid_week_count
    assert_raises(ArgumentError) { MMTkBenchmark::Options.parse(["--weeks", "0"]) }
  end
end
