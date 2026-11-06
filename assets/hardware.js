(function () {
  'use strict';

  const Site = window.MMTkBench;

  function addRow(tbody, label, value) {
    const row = document.createElement('tr');
    const name = document.createElement('td');
    const specification = document.createElement('td');
    name.textContent = label;
    specification.textContent = value === null || value === undefined ? 'Unknown' : String(value);
    row.append(name, specification);
    tbody.appendChild(row);
  }

  function environmentText(variant) {
    const environment = variant.environment || {};
    const entries = Object.entries(environment).map(([key, value]) => `${key}=${value}`);
    return entries.length ? entries.join(' ') : 'No GC runtime overrides';
  }

  async function initialize() {
    try {
      const index = await Site.loadIndex();
      const latest = index.runs[index.runs.length - 1];
      const run = await Site.loadRun(latest);
      const hardware = run.hardware;
      document.getElementById('hardware-intro').textContent = `All displayed results were measured directly on this machine, without a container. Latest snapshot: ${run.date}.`;
      const table = document.getElementById('hardware-list');
      table.replaceChildren();
      addRow(table, 'Operating system', hardware.operating_system);
      addRow(table, 'Kernel', hardware.kernel);
      addRow(table, 'Processor', hardware.processor);
      addRow(table, 'Architecture', hardware.architecture);
      addRow(table, 'Logical CPUs', hardware.logical_cpus);
      addRow(table, 'Memory', hardware.memory_gib ? `${hardware.memory_gib} GiB` : 'Unknown');
      addRow(table, 'Ruby revision', run.ruby.revision);
      addRow(table, 'ruby-bench revision', run.ruby_bench.revision);
      addRow(table, 'MMTk core revision', run.ruby.mmtk_core_revision || 'Recorded by Ruby revision');

      const variants = document.getElementById('variant-list');
      variants.replaceChildren();
      Object.entries(run.variants).forEach(function ([name, variant]) {
        const row = document.createElement('tr');
        const label = document.createElement('td');
        const details = document.createElement('td');
        const description = document.createElement('div');
        const environment = document.createElement('code');
        label.textContent = variant.label;
        description.textContent = variant.description;
        environment.textContent = environmentText(variant);
        details.append(description, document.createElement('br'), environment);
        row.append(label, details);
        variants.appendChild(row);
        row.dataset.variant = name;
      });

      const settings = run.configuration;
      document.getElementById('benchmark-settings').textContent =
        `${settings.warmup_iterations} warmup iterations, at least ${settings.minimum_iterations} measured iterations, ` +
        `and a ${settings.minimum_seconds}s minimum measurement window. Configurations are interleaved per benchmark. ` +
        `${settings.cpu_pinning ? 'CPU pinning is enabled.' : 'CPU pinning is disabled.'} ` +
        'The dashboard memory metric is mean RSS after warmup; raw samples, retained RSS, and peak RSS remain in each result file.';
    } catch (error) {
      const table = document.getElementById('hardware-list');
      table.replaceChildren();
      addRow(table, 'Error', error.message);
    }
  }

  initialize();
})();
