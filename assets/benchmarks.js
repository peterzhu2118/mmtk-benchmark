(function () {
  'use strict';

  const Site = window.MMTkBench;
  const state = { index: null, runs: [], benchmark: null, category: 'headline', metric: 'speedup' };
  const chartElement = document.getElementById('history-chart');
  const statusElement = document.getElementById('history-status');
  const switcher = document.getElementById('category-switcher');
  const benchmarkNav = document.getElementById('benchmark-nav');

  function latestRun() {
    return state.runs[state.runs.length - 1];
  }

  function categoryFor(name) {
    const entry = latestRun().benchmarks[name];
    return entry ? (entry.category || 'other') : state.category;
  }

  function renderCategories() {
    switcher.replaceChildren();
    Site.categories(latestRun()).forEach(function (category) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `category-switch${category === state.category ? ' active' : ''}`;
      button.textContent = Site.shortCategoryLabel(category);
      button.setAttribute('aria-pressed', String(category === state.category));
      button.addEventListener('click', function () {
        state.category = category;
        const names = Site.benchmarksInCategory(latestRun(), category);
        if (!names.includes(state.benchmark)) state.benchmark = names[0];
        renderNavigation();
        renderChart();
        syncURL();
      });
      switcher.appendChild(button);
    });
  }

  function renderNavigation() {
    renderCategories();
    benchmarkNav.replaceChildren();
    Site.benchmarksInCategory(latestRun(), state.category).forEach(function (name) {
      const item = document.createElement('li');
      item.className = 'nav-item';
      const link = document.createElement('a');
      link.href = `#${encodeURIComponent(name)}`;
      link.className = `nav-link${name === state.benchmark ? ' active' : ''}`;
      link.textContent = name;
      if (name === state.benchmark) link.setAttribute('aria-current', 'page');
      link.addEventListener('click', function (event) {
        event.preventDefault();
        state.benchmark = name;
        renderNavigation();
        renderChart();
        syncURL();
      });
      item.appendChild(link);
      benchmarkNav.appendChild(item);
    });
  }

  function point(run, variant) {
    const value = Site.metricValue(run, state.benchmark, variant, state.metric);
    const measurement = Site.measurement(run, state.benchmark, variant);
    return {
      y: value,
      custom: {
        time: measurement ? measurement.time_seconds * 1000 : null,
        stddev: measurement ? measurement.time_stddev_percent : null,
        rss: measurement && measurement.mean_rss_bytes ? measurement.mean_rss_bytes / (1024 * 1024) : null
      }
    };
  }

  function renderChart() {
    const metric = state.metric;
    const names = {
      speedup: 'Speedup (higher is better)',
      time: 'Time (lower is better)',
      memory: 'Memory (lower is better)'
    };
    const units = { speedup: 'times', time: 'ms', memory: 'MiB' };
    const dates = state.runs.map(run => run.date);
    const series = Site.variantIds(state.index).map(function (variant) {
      return {
        id: variant,
        name: state.index.variants[variant].label,
        color: Site.colors[variant] || '#777777',
        data: state.runs.map(run => point(run, variant))
      };
    });
    const hasData = series.some(item => item.data.some(entry => entry.y !== null && Number.isFinite(entry.y)));
    if (!state.benchmark || !hasData) {
      chartElement.hidden = true;
      statusElement.hidden = false;
      statusElement.textContent = 'This benchmark has no historical measurements.';
      return;
    }

    statusElement.hidden = true;
    chartElement.hidden = false;
    Site.drawChart(chartElement, {
      chart: { type: 'line', zoomType: 'x' },
      title: { text: `${state.benchmark} — ${names[metric]}` },
      yAxis: {
        min: 0,
        title: { text: units[metric] },
        plotLines: metric === 'speedup' ? [{
          value: 1,
          color: '#666666',
          dashStyle: 'Dash',
          width: 1,
          label: { text: 'Ruby baseline', style: { color: '#666666' } }
        }] : []
      },
      xAxis: {
        categories: dates,
        title: { text: 'Ruby snapshot week' },
        labels: {
          formatter: function () {
            const url = Site.commitURL(state.runs[this.pos], state.runs[this.pos - 1]);
            return `<a href="${url}">${this.value}</a>`;
          }
        }
      },
      legend: { enabled: true },
      plotOptions: {
        series: {
          cursor: 'pointer',
          connectNulls: true,
          marker: { enabled: true, radius: 4 },
          point: {
            events: {
              click: function () {
                const run = state.runs[this.index];
                window.open(Site.commitURL(run, state.runs[this.index - 1]), '_blank', 'noopener');
              }
            }
          }
        }
      },
      tooltip: {
        useHTML: true,
        formatter: function () {
          const run = state.runs[this.point.index];
          const custom = this.point.options.custom;
          let detail = `<span style="font-size:11px">${run.date} · Ruby ${run.ruby.revision.substring(0, 12)}</span><br>`;
          detail += `<span style="color:${this.color}">●</span> ${this.series.name}: <b>${Site.formatMetric(this.y, metric)}</b>`;
          if (metric === 'speedup' && custom.time !== null) detail += `<br><small>Time: ${Site.formatMetric(custom.time, 'time')}</small>`;
          if (metric === 'time' && custom.stddev !== null) detail += `<br><small>Stddev: ${custom.stddev.toFixed(2)}%</small>`;
          return detail;
        }
      },
      series: series
    });
  }

  function syncURL() {
    const url = new URL(window.location.href);
    if (state.metric === 'memory') url.searchParams.set('memory', '');
    else url.searchParams.delete('memory');
    url.hash = state.benchmark || '';
    history.replaceState(null, '', url);
  }

  async function initialize() {
    try {
      state.index = await Site.loadIndex();
      state.runs = await Promise.all(state.index.runs.map(run => Site.loadRun(run)));
      state.runs.sort((a, b) => a.date.localeCompare(b.date));
      const requestedBenchmark = decodeURIComponent(window.location.hash.substring(1));
      const available = Object.keys(latestRun().benchmarks);
      state.benchmark = available.includes(requestedBenchmark) ? requestedBenchmark : Site.benchmarksInCategory(latestRun(), 'headline')[0] || available[0];
      state.category = categoryFor(state.benchmark);
      if (new URLSearchParams(window.location.search).has('memory')) {
        state.metric = 'memory';
        document.querySelector('input[name="metric_type"][value="memory"]').checked = true;
      }
      renderNavigation();
      renderChart();
      syncURL();
    } catch (error) {
      Site.showError(statusElement, error);
    }
  }

  document.querySelectorAll('input[name="metric_type"]').forEach(function (radio) {
    radio.addEventListener('change', function (event) {
      state.metric = event.target.value;
      if (state.benchmark) {
        renderChart();
        syncURL();
      }
    });
  });
  Site.setupArrowKeys(() => benchmarkNav.querySelectorAll('a'));
  initialize();
})();
