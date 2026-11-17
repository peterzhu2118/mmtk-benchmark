# MMTk Benchmark

A static dashboard comparing Ruby's default GC with MMTk StickyImmix using [ruby-bench](https://github.com/ruby/ruby-bench).

## Run benchmarks

MMTk is built with Rust 1.95 (installed automatically via rustup) and cross-language LTO, which requires the matching `clang-22` (`sudo apt install clang-22`). The run fails rather than silently building MMTk without LTO.

Weekly snapshots are dated on Mondays. Run all ruby-bench headline benchmarks for this week's snapshot (the most recent Monday, using Ruby and ruby-bench commits up to the end of that Monday in UTC):

```sh
bin/benchmark
```

Backfill two headline-only weekly snapshots, ending this week's Monday:

```sh
bin/benchmark --weeks=2
```

Run selected benchmarks or use a shorter smoke-test configuration:

```sh
bin/benchmark liquid-render psych-load
bin/benchmark --quick liquid-render psych-load
```

Each run compares five configurations: Ruby without modular GC, modular Ruby with the default GC, and MMTk StickyImmix with the `dynamic`, `ruby`, and `cpu` heap modes.

Results are written to `data/results/YYYY-MM-DD.json`, and `data/index.json` is updated automatically. Source checkouts and builds are cached in `.cache/`; existing result files are skipped unless `--force` is supplied. See all options with:

```sh
bin/benchmark --help
```

Commit the updated files in `data/` to publish new measurements.

## View the website locally

From the repository root, start Ruby's HTTP server:

```sh
ruby -run -e httpd . -p 8000
```

Open <http://localhost:8000/> in a browser. The history and hardware pages are available at `/benchmarks.html` and `/hardware.html`.
