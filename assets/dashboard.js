(function () {
  'use strict';

  const Site = window.MMTkBench;
  const state = { index: null, run: null, category: 'headline', metric: 'speed' };
  const runCache = new Map();
  const chartElement = document.getElementById('dashboard-chart');
  const statusElement = document.getElementById('dashboard-status');
  const switcher = document.getElementById('category-switcher');
  const weekSelect = document.getElementById('week-select');

  function populateWeeks() {
    const requestedDate = new URLSearchParams(window.location.search).get('date');
    const runs = state.index.runs.slice().reverse();
    runs.forEach(function (run) {
      const option = document.createElement('option');
      option.value = run.date;
      option.textContent = run.date;
      weekSelect.appendChild(option);
    });
    weekSelect.value = state.index.runs.some(run => run.date === requestedDate) ? requestedDate : runs[0].date;
  }

  async function loadSelectedRun() {
    const metadata = state.index.runs.find(run => run.date === weekSelect.value);
    if (!runCache.has(metadata.date)) runCache.set(metadata.date, Site.loadRun(metadata));
    state.run = await runCache.get(metadata.date);
    const categories = Site.categories(state.run);
    if (!categories.includes(state.category)) state.category = categories[0];
    renderCategories();
    renderHeader();
    renderBenchmarkTable();
    renderChart();
    syncURL();
  }

  function renderHeader() {
    document.getElementById('benchmark-date').textContent = state.run.date;
    const revision = state.run.ruby.revision;
    const link = document.getElementById('benchmark-revision');
    link.textContent = `Ruby ${revision.substring(0, 12)}`;
    link.href = `https://github.com/ruby/ruby/commit/${revision}`;
  }

  function renderCategories() {
    switcher.replaceChildren();
    Site.categories(state.run).forEach(function (category) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `category-switch${category === state.category ? ' active' : ''}`;
      button.dataset.category = category;
      button.textContent = Site.shortCategoryLabel(category);
      button.setAttribute('aria-pressed', String(category === state.category));
      button.addEventListener('click', function () {
        state.category = category;
        renderCategories();
        renderChart();
        syncURL();
      });
      switcher.appendChild(button);
    });
  }

  function renderChart() {
    const names = Site.benchmarksInCategory(state.run, state.category);
    const memory = state.metric === 'memory';
    const metric = memory ? 'relativeMemory' : 'speed';
    const series = Site.seriesFor(state.index, metric, names, state.run);
    const hasData = series.some(item => item.data.some(value => value !== null));
    if (!hasData) {
      chartElement.hidden = true;
      statusElement.hidden = false;
      statusElement.textContent = 'No measurements are available for this category.';
      return;
    }

    statusElement.hidden = true;
    chartElement.hidden = false;
    Site.drawChart(chartElement, {
      chart: { zoomType: 'xy', type: 'column' },
      title: { text: memory ? 'Memory (lower is better)' : 'Speed (higher is better)' },
      yAxis: {
        min: 0,
        maxPadding: 0.05,
        title: { text: memory ? 'relative to Ruby baseline' : 'times faster than Ruby baseline' },
        plotLines: [{
          value: 1,
          color: '#666666',
          dashStyle: 'Dash',
          width: 1,
          zIndex: 2,
          label: { text: 'baseline', style: { color: '#666666' } }
        }]
      },
      xAxis: {
        categories: names,
        labels: {
          rotation: names.length > 6 ? -35 : 0,
          formatter: function () {
            return `<a href="${Site.benchmarkURL(this.value, memory)}">${this.value}</a>`;
          }
        }
      },
      tooltip: {
        formatter: function () {
          return `<span style="font-size:11px">${this.x}</span><br>` +
            `<span style="color:${this.color}">●</span> ${this.series.name}: ` +
            `<b>${Site.formatMetric(this.y, metric)}</b>`;
        }
      },
      series: series
    });
  }

  function renderBenchmarkTable() {
    const tbody = document.getElementById('benchmark-list');
    tbody.replaceChildren();
    Site.categories(state.run).forEach(function (category) {
      const row = document.createElement('tr');
      const heading = document.createElement('td');
      heading.textContent = Site.categoryLabel(category);
      const links = document.createElement('td');
      links.className = 'margined-links';
      Site.benchmarksInCategory(state.run, category).forEach(function (name) {
        const link = document.createElement('a');
        link.href = Site.benchmarkURL(name, state.metric === 'memory');
        link.textContent = name;
        links.appendChild(link);
      });
      row.append(heading, links);
      tbody.appendChild(row);
    });
  }

  function syncURL() {
    const url = new URL(window.location.href);
    if (state.metric === 'memory') url.searchParams.set('memory', '');
    else url.searchParams.delete('memory');
    if (state.run.date !== state.index.runs[state.index.runs.length - 1].date) url.searchParams.set('date', state.run.date);
    else url.searchParams.delete('date');
    url.hash = state.category;
    history.replaceState(null, '', url);
  }

  async function initialize() {
    try {
      state.index = await Site.loadIndex();
      if (new URLSearchParams(window.location.search).has('memory')) {
        state.metric = 'memory';
        document.querySelector('input[name="metric_type"][value="memory"]').checked = true;
      }
      const requestedCategory = decodeURIComponent(window.location.hash.substring(1));
      if (requestedCategory) state.category = requestedCategory;
      populateWeeks();
      await loadSelectedRun();
    } catch (error) {
      Site.showError(statusElement, error);
    }
  }

  weekSelect.addEventListener('change', function () {
    loadSelectedRun().catch(error => Site.showError(statusElement, error));
  });
  document.querySelectorAll('input[name="metric_type"]').forEach(function (radio) {
    radio.addEventListener('change', function (event) {
      state.metric = event.target.value;
      if (!state.run) return;
      renderChart();
      renderBenchmarkTable();
      syncURL();
    });
  });
  Site.setupArrowKeys(() => switcher.querySelectorAll('button'));
  initialize();
})();
