(function (global) {
  'use strict';

  const COLORS = {
    baseline: '#3285e1',
    modular_default: '#8d6bad',
    mmtk_dynamic: '#489d32',
    mmtk_ruby: '#e2c13e',
    mmtk_cpu: '#d05a4e'
  };
  const CATEGORY_ORDER = ['headline', 'other', 'micro', 'gc'];
  const CATEGORY_LABELS = {
    headline: 'Headline Benchmarks',
    other: 'Other Benchmarks',
    micro: 'MicroBenchmarks',
    gc: 'GC Benchmarks'
  };
  let indexUrl = null;

  async function fetchJSON(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status} while loading ${url}`);
    return response.json();
  }

  async function loadIndex() {
    indexUrl = new URL('data/index.json', global.location.href);
    const index = await fetchJSON(indexUrl);
    if (!Array.isArray(index.runs) || index.runs.length === 0) {
      throw new Error('No benchmark results have been published yet.');
    }
    return index;
  }

  function loadRun(run) {
    if (!indexUrl) throw new Error('Load data/index.json before loading a result.');
    return fetchJSON(new URL(run.path, indexUrl));
  }

  function variantIds(index) {
    return Object.keys(index.variants);
  }

  function seriesFor(index, metric, names, run) {
    return variantIds(index).map(function (id) {
      return {
        id: id,
        name: index.variants[id].label,
        color: COLORS[id] || '#777777',
        data: names.map(name => metricValue(run, name, id, metric))
      };
    });
  }

  function measurement(run, benchmark, variant) {
    const entry = run.benchmarks[benchmark];
    return entry && entry.results ? entry.results[variant] : null;
  }

  function speedup(run, benchmark, variant) {
    const value = measurement(run, benchmark, variant);
    const baseline = measurement(run, benchmark, 'baseline');
    if (!value || !baseline || !(value.time_seconds > 0) || !(baseline.time_seconds > 0)) return null;
    return baseline.time_seconds / value.time_seconds;
  }

  function relativeMemory(run, benchmark, variant) {
    const value = measurement(run, benchmark, variant);
    const baseline = measurement(run, benchmark, 'baseline');
    if (!value || !baseline || !(value.mean_rss_bytes > 0) || !(baseline.mean_rss_bytes > 0)) return null;
    return value.mean_rss_bytes / baseline.mean_rss_bytes;
  }

  function metricValue(run, benchmark, variant, metric) {
    if (metric === 'speed' || metric === 'speedup') return speedup(run, benchmark, variant);
    if (metric === 'relativeMemory') return relativeMemory(run, benchmark, variant);
    const value = measurement(run, benchmark, variant);
    if (!value) return null;
    if (metric === 'time') return value.time_seconds * 1000;
    if (metric === 'memory') return value.mean_rss_bytes / (1024 * 1024);
    return null;
  }

  function categories(run) {
    const available = new Set(Object.values(run.benchmarks).map(entry => entry.category || 'other'));
    return CATEGORY_ORDER.filter(category => available.has(category)).concat(
      Array.from(available).filter(category => !CATEGORY_ORDER.includes(category)).sort()
    );
  }

  function benchmarksInCategory(run, category) {
    return Object.keys(run.benchmarks).filter(function (name) {
      return (run.benchmarks[name].category || 'other') === category;
    }).sort();
  }

  function benchmarkURL(name, memory) {
    return `benchmarks.html${memory ? '?memory' : ''}#${encodeURIComponent(name)}`;
  }

  function categoryLabel(category) {
    return CATEGORY_LABELS[category] || category.charAt(0).toUpperCase() + category.slice(1);
  }

  function shortCategoryLabel(category) {
    return { headline: 'Headline', other: 'Other', micro: 'Micro', gc: 'GC' }[category] || categoryLabel(category);
  }

  function commitURL(run, previousRun) {
    const revision = run.ruby.revision;
    if (previousRun && previousRun.ruby.revision !== revision) {
      return `https://github.com/ruby/ruby/compare/${previousRun.ruby.revision}...${revision}`;
    }
    return `https://github.com/ruby/ruby/commit/${revision}`;
  }

  function formatMetric(value, metric) {
    if (value === null || !Number.isFinite(value)) return 'not measured';
    if (metric === 'speed' || metric === 'speedup') return `${value.toFixed(2)}×`;
    if (metric === 'relativeMemory') {
      const percent = Math.round((value - 1) * 100);
      if (Math.abs(value - 1) < 0.005) return 'same as baseline';
      return `${percent > 0 ? '+' : ''}${percent}% memory`;
    }
    if (metric === 'time') return `${value >= 100 ? value.toFixed(0) : value.toFixed(2)} ms`;
    if (metric === 'memory') return `${value.toFixed(1)} MiB`;
    return String(value);
  }

  function drawChart(element, config) {
    if (typeof global.Highcharts === 'undefined') {
      throw new Error('Highcharts could not be loaded. Check your network connection and reload.');
    }
    global.Highcharts.setOptions({ lang: { thousandsSep: '' } });
    if (element._mmtkChart) element._mmtkChart.destroy();
    element.innerHTML = '';
    element._mmtkChart = global.Highcharts.chart(element, Object.assign({
      chart: { zoomType: 'x', animation: false },
      title: { text: '' },
      credits: { enabled: true },
      plotOptions: { series: { animation: { duration: 200 } } }
    }, config));
    return element._mmtkChart;
  }

  function showError(element, error) {
    element.hidden = false;
    element.className = 'chart-status error';
    element.textContent = error.message;
  }

  function setupArrowKeys(getButtons) {
    document.addEventListener('keydown', function (event) {
      if (!['ArrowLeft', 'ArrowRight'].includes(event.key) || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
      if (event.target.closest('input, textarea, select, [contenteditable="true"]')) return;
      const buttons = Array.from(getButtons()).filter(button => !button.hidden && button.offsetParent !== null);
      const active = buttons.findIndex(button => button.classList.contains('active'));
      const next = active + (event.key === 'ArrowRight' ? 1 : -1);
      if (active < 0 || !buttons[next]) return;
      event.preventDefault();
      buttons[next].click();
    });
  }

  const api = {
    loadIndex: loadIndex,
    loadRun: loadRun,
    fetchJSON: fetchJSON,
    variantIds: variantIds,
    measurement: measurement,
    speedup: speedup,
    relativeMemory: relativeMemory,
    metricValue: metricValue,
    seriesFor: seriesFor,
    categories: categories,
    benchmarksInCategory: benchmarksInCategory,
    benchmarkURL: benchmarkURL,
    categoryLabel: categoryLabel,
    shortCategoryLabel: shortCategoryLabel,
    commitURL: commitURL,
    formatMetric: formatMetric,
    drawChart: drawChart,
    showError: showError,
    setupArrowKeys: setupArrowKeys,
    colors: COLORS
  };
  global.MMTkBench = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
