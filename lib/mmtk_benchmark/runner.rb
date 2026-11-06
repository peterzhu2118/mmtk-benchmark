# frozen_string_literal: true

require "date"
require "etc"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "shellwords"
require "time"
require "yaml"

module MMTkBenchmark
  class CommandError < StandardError; end

  class Options
    Config = Struct.new(
      :date, :weeks, :categories, :benchmarks, :warmup, :iterations,
      :min_time, :jobs, :work_dir, :data_dir, :force, :no_pinning, :reuse_raw,
      keyword_init: true,
    )

    def self.parse(argv)
      root = File.expand_path("../..", __dir__)
      config = Config.new(
        date: Date.today,
        weeks: 1,
        categories: %w[headline],
        benchmarks: [],
        warmup: 15,
        iterations: 10,
        min_time: 10,
        jobs: [Etc.nprocessors - 2, 1].max,
        work_dir: File.join(root, ".cache", "mmtk-benchmark"),
        data_dir: File.join(root, "data"),
        force: false,
        no_pinning: false,
        reuse_raw: false,
      )
      quick = false

      parser = OptionParser.new do |opts|
        opts.banner = <<~USAGE
          Usage: bin/benchmark [options] [BENCHMARK ...]

          Build Ruby directly on this machine and benchmark Ruby's default GC,
          modular Ruby's default GC, and MMTk StickyImmix with dynamic, ruby,
          and cpu heap modes. Results are written to data/results/DATE.json.
          By default, all headline benchmarks are run. Use --category to select
          other benchmark categories.

          Examples:
            bin/benchmark
            bin/benchmark --weeks 2
            bin/benchmark --weeks 2 --category headline liquid-render psych-load
            bin/benchmark --quick --category micro fib object-new
        USAGE
        opts.on("--date=YYYY-MM-DD", "latest weekly cutoff (default: today)") do |value|
          config.date = Date.iso8601(value)
        end
        opts.on("--weeks=N", Integer, "number of weekly points, including --date (default: 1)") do |value|
          config.weeks = value
        end
        opts.on("--category=LIST", Array, "ruby-bench categories (default: headline)") do |value|
          config.categories = value
        end
        opts.on("--warmup=N", Integer, "warmup iterations (default: 15)") do |value|
          config.warmup = value
        end
        opts.on("--iterations=N", Integer, "minimum measured iterations (default: 10)") do |value|
          config.iterations = value
        end
        opts.on("--min-time=SECONDS", Integer, "minimum measured seconds per benchmark (default: 10)") do |value|
          config.min_time = value
        end
        opts.on("--quick", "use 2 warmups, 3 measurements, and no minimum time") do
          quick = true
        end
        opts.on("--jobs=N", Integer, "parallel build jobs (default: CPU count - 2; benchmarks stay serial)") do |value|
          config.jobs = value
        end
        opts.on("--work-dir=PATH", "source/build cache (default: .cache/mmtk-benchmark)") do |value|
          config.work_dir = value
        end
        opts.on("--force", "replace existing weekly result files") do
          config.force = true
        end
        opts.on("--reuse-raw", "resume after an error using an existing cached raw result") do
          config.reuse_raw = true
        end
        opts.on("--no-pinning", "disable ruby-bench's CPU pinning") do
          config.no_pinning = true
        end
        opts.on("-h", "--help", "show this help") do
          puts opts
          exit
        end
      end
      parser.parse!(argv)
      config.benchmarks = argv.dup

      if quick
        config.warmup = 2
        config.iterations = 3
        config.min_time = 0
      end
      config.work_dir = File.expand_path(config.work_dir, root)
      config.data_dir = File.expand_path(config.data_dir, root)
      validate!(config)
      config
    end

    def self.validate!(config)
      raise ArgumentError, "--weeks must be at least 1" if config.weeks < 1
      raise ArgumentError, "--warmup must be nonnegative" if config.warmup < 0
      raise ArgumentError, "--iterations must be at least 1" if config.iterations < 1
      raise ArgumentError, "--min-time must be nonnegative" if config.min_time < 0
      raise ArgumentError, "--jobs must be at least 1" if config.jobs < 1
      raise ArgumentError, "select at least one category" if config.categories.empty?

      config.benchmarks.each do |name|
        next if name.match?(/\A[a-zA-Z0-9_.\/-]+\z/)

        raise ArgumentError, "invalid benchmark name: #{name.inspect}"
      end
    end
  end

  class Runner
    RUBY_REPOSITORY = "https://github.com/ruby/ruby.git"
    RUBY_BENCH_REPOSITORY = "https://github.com/ruby/ruby-bench.git"

    attr_reader :config

    def initialize(config)
      @config = config
      FileUtils.mkdir_p(config.data_dir)
      FileUtils.mkdir_p(config.work_dir)
    end

    def run
      puts "Benchmark cache: #{config.work_dir}"
      puts "MMTk plan: StickyImmix; heap modes: dynamic, ruby, cpu"

      dates.each do |date|
        result_path = File.join(config.data_dir, "results", "#{date}.json")
        if File.exist?(result_path) && !config.force
          puts "\n#{date}: result already exists (use --force to replace it)"
          next
        end

        run_date(date)
      end

      index = ResultIndex.generate(config.data_dir)
      puts "\nUpdated data/index.json with #{index.fetch("runs").length} weekly result(s)."
      puts "Review and commit data/index.json and data/results/*.json to publish the new data."
    end

    private

    def dates
      (0...config.weeks).map { |offset| (config.date - (offset * 7)).iso8601 }.reverse
    end

    def run_date(date)
      puts "\n=== Weekly snapshot #{date} ==="
      ruby_repository = ensure_repository("ruby", RUBY_REPOSITORY)
      ruby_bench_repository = ensure_repository("ruby-bench", RUBY_BENCH_REPOSITORY)

      ruby_revision = revision_before(ruby_repository, date, "master")
      ruby_bench_revision = revision_before(ruby_bench_repository, date, "main")
      ruby_source = checkout(ruby_repository, "ruby", ruby_revision)
      ruby_bench_source = checkout(ruby_bench_repository, "ruby-bench", ruby_bench_revision)

      puts "Ruby:       #{ruby_revision}"
      puts "ruby-bench: #{ruby_bench_revision}"
      rubies = build_rubies(ruby_source, ruby_revision)
      raw_path = execute_benchmarks(date, ruby_bench_source, rubies)
      raw = JSON.parse(File.read(raw_path))
      if raw.fetch("raw_data").values.all?(&:empty?)
        raise CommandError, "no benchmarks completed; see #{raw_path.sub(/\.json\z/, ".txt")}"
      end

      metadata = YAML.safe_load_file(File.join(ruby_bench_source, "benchmarks.yml"))
      result = ResultBuilder.build(
        date: date,
        ruby: revision_metadata(ruby_repository, ruby_revision).merge(
          "mmtk_core_revision" => mmtk_core_revision(ruby_source),
        ),
        ruby_bench: revision_metadata(ruby_bench_repository, ruby_bench_revision),
        benchmark_metadata: metadata,
        raw: raw,
        configuration: configuration_metadata,
        hardware: hardware_metadata,
      )
      path = ResultIndex.write_result(config.data_dir, date, result)
      puts "Wrote #{path} (#{result.fetch("benchmarks").length} benchmarks)."
    end

    def ensure_repository(name, url)
      path = File.join(config.work_dir, "sources", name)
      if File.directory?(File.join(path, ".git"))
        sh("fetch-#{name}", "git", "-C", path, "fetch", "--prune", "origin", allow_failure: true)
      elsif File.exist?(path)
        raise CommandError, "cache path exists but is not a Git checkout: #{path}"
      else
        FileUtils.mkdir_p(File.dirname(path))
        sh("clone-#{name}", "git", "clone", "--filter=blob:none", url, path)
      end
      path
    end

    def revision_before(repository, date, branch)
      revision = capture("git", "-C", repository, "rev-list", "-1", "--before=#{date}T23:59:59Z", "origin/#{branch}").strip
      if revision.empty?
        raise CommandError, "no #{branch} commit found before #{date}"
      end
      revision
    end

    def checkout(repository, name, revision)
      path = File.join(config.work_dir, "checkouts", "#{name}-#{revision[0, 12]}")
      if File.exist?(File.join(path, ".git"))
        actual = capture("git", "-C", path, "rev-parse", "HEAD").strip
        raise CommandError, "unexpected checkout revision in #{path}" unless actual == revision
        return path
      end
      raise CommandError, "incomplete checkout cache: #{path}" if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      sh("checkout-#{name}-#{revision[0, 12]}",
        "git", "-C", repository, "worktree", "add", "--detach", path, revision)
      path
    end

    def revision_metadata(repository, revision)
      fields = capture("git", "-C", repository, "show", "-s", "--format=%cI%n%s", revision).lines.map(&:chomp)
      {
        "revision" => revision,
        "committed_at" => fields[0],
        "subject" => fields[1],
      }
    end

    def mmtk_core_revision(ruby_source)
      cargo = File.read(File.join(ruby_source, "gc", "mmtk", "Cargo.toml"))
      cargo[/^rev = "([0-9a-f]+)"/, 1]
    end

    def build_rubies(source, revision)
      build_root = File.join(config.work_dir, "rubies", revision)
      FileUtils.mkdir_p(build_root)
      unless File.executable?(File.join(source, "configure"))
        sh("autogen-#{revision[0, 12]}", File.join(source, "autogen.sh"), chdir: source)
      end

      baseline = build_ruby(source, build_root, "baseline", modular: false)
      modular, gc_dir = build_ruby(source, build_root, "modular", modular: true)
      build_mmtk(build_root, gc_dir)
      rubies = {
        "baseline" => { "ruby" => baseline, "environment" => {} },
        "modular_default" => { "ruby" => modular, "environment" => {} },
      }
      %w[dynamic ruby cpu].each do |heap_mode|
        rubies["mmtk_#{heap_mode}"] = {
          "ruby" => modular,
          "environment" => {
            "RUBY_GC_LIBRARY" => "mmtk",
            "MMTK_PLAN" => "StickyImmix",
            "MMTK_HEAP_MODE" => heap_mode,
          },
        }
      end
      validate_rubies(rubies)
      rubies
    end

    def build_ruby(source, build_root, name, modular:)
      build_dir = File.join(build_root, "#{name}-build")
      install_dir = File.join(build_root, "#{name}-install")
      gc_dir = File.join(build_root, "modular-gc")
      ruby = File.join(install_dir, "bin", "ruby")
      marker = File.join(build_root, "#{name}-complete.json")
      expected = {
        "revision" => File.basename(build_root),
        "modular" => modular,
        "configure" => [
          "--disable-install-doc",
          "--prefix=#{install_dir}",
          *("--with-modular-gc=#{gc_dir}" if modular),
        ],
      }
      if File.exist?(marker) && File.executable?(ruby) && JSON.parse(File.read(marker)) == expected
        puts "Using cached #{name} Ruby: #{ruby}"
        return modular ? [ruby, gc_dir] : ruby
      end

      FileUtils.mkdir_p(build_dir)
      FileUtils.mkdir_p(gc_dir) if modular
      unless File.exist?(File.join(build_dir, "Makefile"))
        sh("configure-#{name}-#{File.basename(build_root)[0, 12]}",
          File.join(source, "configure"), *expected.fetch("configure"), chdir: build_dir)
      end
      sh("make-#{name}-#{File.basename(build_root)[0, 12]}", "make", "-j#{config.jobs}", chdir: build_dir)
      sh("install-#{name}-#{File.basename(build_root)[0, 12]}", "make", "install", chdir: build_dir)
      raise CommandError, "Ruby install did not produce #{ruby}" unless File.executable?(ruby)

      ResultIndex.atomic_write(marker, JSON.pretty_generate(expected) + "\n")
      modular ? [ruby, gc_dir] : ruby
    end

    def build_mmtk(build_root, gc_dir)
      return if Dir[File.join(gc_dir, "librubygc.mmtk.*")].any?

      puts "Building MMTk separately as a modular GC (release mode)"
      sh("mmtk-#{File.basename(build_root)[0, 12]}",
        "make", "-j#{config.jobs}", "install-modular-gc", "MODULAR_GC=mmtk", "MMTK_BUILD=release",
        chdir: File.join(build_root, "modular-build"),
        env: { "CARGO_HOME" => File.join(config.work_dir, "cargo-home") })
      unless Dir[File.join(gc_dir, "librubygc.mmtk.*")].any?
        raise CommandError, "MMTk build did not install librubygc.mmtk in #{gc_dir}"
      end
    end

    def validate_rubies(rubies)
      program = <<~RUBY
        require "json"
        config = GC.respond_to?(:config) ? GC.config : {}
        print JSON.generate({
          implementation: config[:implementation],
          mmtk_plan: config[:mmtk_plan],
          mmtk_heap_mode: config[:mmtk_heap_mode],
          modular_gc_dir: RbConfig::CONFIG["modular_gc_dir"],
        })
      RUBY

      rubies.each do |name, variant|
        output = capture(variant.fetch("ruby"), "-e", program, env: variant.fetch("environment"))
        actual = JSON.parse(output)
        case name
        when "baseline"
          unless actual.fetch("modular_gc_dir").to_s.empty?
            raise CommandError, "baseline unexpectedly has modular GC enabled"
          end
        when "modular_default"
          if actual.fetch("modular_gc_dir").to_s.empty? || actual["implementation"] != "default"
            raise CommandError, "modular_default is not using modular Ruby's default GC"
          end
        else
          expected_heap = name.delete_prefix("mmtk_")
          valid = actual["implementation"] == "mmtk" &&
            actual["mmtk_plan"] == "StickyImmix" &&
            actual["mmtk_heap_mode"] == expected_heap
          unless valid
            raise CommandError, "#{name} loaded the wrong GC configuration: #{output}"
          end
        end
        puts "Verified #{name}: #{actual.inspect}"
      end
    end

    def execute_benchmarks(date, ruby_bench_source, rubies)
      raw_dir = File.join(config.work_dir, "raw", date)
      FileUtils.mkdir_p(raw_dir)
      output_base = File.join(raw_dir, "output")
      raw_path = "#{output_base}.json"
      if config.reuse_raw && File.exist?(raw_path)
        puts "Reusing cached raw result: #{raw_path}"
        return raw_path
      end
      command = [
        RbConfig.ruby,
        File.join(ruby_bench_source, "run_benchmarks.rb"),
        "--no-sudo",
        "--rss",
        "--interleave",
        "--out_path=#{raw_dir}",
        "--out-name=#{output_base}",
        "--category=#{config.categories.join(",")}",
        "--warmup=#{config.warmup}",
        "--bench=#{config.iterations}",
      ]
      command << "--no-pinning" if config.no_pinning
      rubies.each do |name, variant|
        env_prefix = variant.fetch("environment").map { |key, value| "#{key}=#{value}" }
        executable = (["env", *env_prefix, variant.fetch("ruby")]).shelljoin
        command << "-e" << "#{name}::#{executable}"
      end
      command.concat(config.benchmarks)

      puts "Running benchmarks serially with interleaved configurations"
      success = sh("benchmark-#{date}", *command,
        chdir: ruby_bench_source,
        env: benchmark_environment,
        allow_failure: true)
      unless File.exist?(raw_path)
        raise CommandError, "ruby-bench did not write #{raw_path}"
      end
      warn "ruby-bench reported a failed benchmark; successful results will still be published" unless success
      raw_path
    end

    def benchmark_environment
      environment = clean_environment.merge(
        "CARGO_HOME" => File.join(config.work_dir, "cargo-home"),
        "BUNDLE_USER_HOME" => File.join(config.work_dir, "bundler"),
        "WARMUP_ITRS" => config.warmup.to_s,
        "MIN_BENCH_ITRS" => config.iterations.to_s,
        "MIN_BENCH_TIME" => config.min_time.to_s,
      )
      environment
    end

    def clean_environment
      {
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "RUBY_YJIT_ENABLE" => nil,
        "RUBY_ZJIT_ENABLE" => nil,
        "BUNDLE_GEMFILE" => nil,
      }
    end

    def configuration_metadata
      {
        "frequency" => "weekly",
        "plan" => "StickyImmix",
        "heap_modes" => %w[dynamic ruby cpu],
        "warmup_iterations" => config.warmup,
        "minimum_iterations" => config.iterations,
        "minimum_seconds" => config.min_time,
        "categories" => config.categories,
        "benchmark_filters" => config.benchmarks,
        "interleaved" => true,
        "cpu_pinning" => !config.no_pinning,
        "container" => false,
        "memory_metric" => "Mean RSS samples after warmup; retained and peak RSS are also recorded",
      }
    end

    def hardware_metadata
      cpu_info = read_if_present("/proc/cpuinfo")
      memory_info = read_if_present("/proc/meminfo")
      os_release = read_if_present("/etc/os-release")
      memory_kib = memory_info&.match(/^MemTotal:\s+(\d+) kB/)&.[](1)&.to_i
      uname = Etc.uname
      {
        "operating_system" => os_release&.match(/^PRETTY_NAME="?([^"\n]+)/)&.[](1) || uname[:sysname],
        "kernel" => uname[:release],
        "architecture" => uname[:machine],
        "processor" => cpu_info&.match(/^model name\s+:\s+(.+)$/)&.[](1) || "Unknown",
        "logical_cpus" => Etc.nprocessors,
        "memory_gib" => memory_kib && (memory_kib * 1024.0 / (1024**3)).round(1),
      }
    end

    def read_if_present(path)
      File.read(path) if File.readable?(path)
    rescue SystemCallError
      nil
    end

    def capture(*command, env: {})
      stdout, stderr, status = Open3.capture3(clean_environment.merge(env), *command)
      return stdout if status.success?

      raise CommandError, "command failed (#{status.exitstatus}): #{command.shelljoin}\n#{stderr}"
    end

    def sh(name, *command, chdir: config.work_dir, env: {}, allow_failure: false)
      log_dir = File.join(config.work_dir, "logs")
      FileUtils.mkdir_p(log_dir)
      safe_name = name.gsub(/[^a-zA-Z0-9_.-]/, "_")
      log_path = File.join(log_dir, "#{safe_name}.log")
      printable = command.map(&:to_s).shelljoin
      puts "+ (cd #{chdir} && #{printable})"
      puts "  log: #{log_path}"

      success = File.open(log_path, "a") do |log|
        log.puts("\n$ #{printable}")
        log.flush
        system(clean_environment.merge(env), *command, chdir: chdir, out: log, err: log)
      end
      return true if success || allow_failure

      detail = File.exist?(log_path) ? File.readlines(log_path).last(30).join : ""
      raise CommandError, "command failed: #{printable}\nSee #{log_path}\n#{detail}"
    end
  end
end
