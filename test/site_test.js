'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Site = require('../assets/site.js');

function fixture() {
  return {
    date: '2026-11-05',
    ruby: { revision: 'b'.repeat(40) },
    benchmarks: {
      fib: {
        category: 'headline',
        results: {
          baseline: { time_seconds: 2, mean_rss_bytes: 2 * 1024 * 1024 },
          mmtk_dynamic: { time_seconds: 1, mean_rss_bytes: 4 * 1024 * 1024 }
        }
      },
      'object-new': {
        category: 'micro',
        results: {
          baseline: { time_seconds: 0.25, mean_rss_bytes: 8 * 1024 * 1024 },
          mmtk_dynamic: { time_seconds: 0.5, mean_rss_bytes: 4 * 1024 * 1024 }
        }
      }
    }
  };
}

test('speedup compares every configuration to the non-modular baseline', () => {
  const run = fixture();
  assert.equal(Site.speedup(run, 'fib', 'baseline'), 1);
  assert.equal(Site.speedup(run, 'fib', 'mmtk_dynamic'), 2);
  assert.equal(Site.speedup(run, 'object-new', 'mmtk_dynamic'), 0.5);
});

test('memory ratios lower than one use less memory than baseline', () => {
  const run = fixture();
  assert.equal(Site.relativeMemory(run, 'fib', 'mmtk_dynamic'), 2);
  assert.equal(Site.relativeMemory(run, 'object-new', 'mmtk_dynamic'), 0.5);
  assert.equal(Site.metricValue(run, 'fib', 'baseline', 'memory'), 2);
  assert.equal(Site.metricValue(run, 'fib', 'baseline', 'time'), 2000);
});

test('categories and benchmark lists have stable ordering', () => {
  assert.deepEqual(Site.categories(fixture()), ['headline', 'micro']);
  assert.deepEqual(Site.benchmarksInCategory(fixture(), 'micro'), ['object-new']);
});

test('missing measurements do not become zero or infinite values', () => {
  const run = fixture();
  delete run.benchmarks.fib.results.mmtk_dynamic;
  assert.equal(Site.speedup(run, 'fib', 'mmtk_dynamic'), null);
  assert.equal(Site.metricValue(run, 'fib', 'mmtk_dynamic', 'memory'), null);
});

test('commit links compare adjacent weekly revisions', () => {
  const current = fixture();
  const previous = fixture();
  previous.ruby = { revision: 'a'.repeat(40) };
  assert.equal(
    Site.commitURL(current, previous),
    `https://github.com/ruby/ruby/compare/${'a'.repeat(40)}...${'b'.repeat(40)}`
  );
  assert.equal(
    Site.commitURL(current, null),
    `https://github.com/ruby/ruby/commit/${'b'.repeat(40)}`
  );
});

test('labels and URLs retain ruby-bench benchmark names', () => {
  assert.equal(Site.benchmarkURL('object-new', true), 'benchmarks.html?memory#object-new');
  assert.equal(Site.formatMetric(0.75, 'relativeMemory'), '-25% memory');
  assert.equal(Site.formatMetric(1, 'relativeMemory'), 'same as baseline');
  assert.equal(Site.formatMetric(1.5, 'speedup'), '1.50×');
});
