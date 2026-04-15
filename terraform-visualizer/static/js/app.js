/**
 * Main application controller.
 * Handles sidebar, project selection, API calls, and diagram coordination.
 */

let showDetails = false;

document.addEventListener('DOMContentLoaded', () => {
  initDiagram();
  loadProjects();

  document.getElementById('search').addEventListener('input', onSearch);
  document.getElementById('btn-fit').addEventListener('click', () => {
    if (currentData) {
      const layout = computeLayout(currentData, showDetails);
      fitToView(layout);
    }
  });
  document.getElementById('btn-export').addEventListener('click', exportSVG);
  document.getElementById('btn-details').addEventListener('click', () => {
    showDetails = !showDetails;
    const btn = document.getElementById('btn-details');
    const label = document.getElementById('btn-details-label');
    btn.classList.toggle('active', showDetails);
    label.textContent = showDetails ? '간단히 보기' : '상세 보기';
    if (currentData) renderDiagram(currentData, showDetails);
  });
});


async function loadProjects() {
  try {
    const res = await fetch('/api/projects');
    const modules = await res.json();
    renderSidebar(modules);
  } catch (err) {
    console.error('Failed to load projects:', err);
    document.getElementById('project-tree').innerHTML =
      '<div style="padding:20px;color:#f87171;">Failed to load projects</div>';
  }
}


function renderSidebar(modules) {
  const tree = document.getElementById('project-tree');
  tree.innerHTML = '';

  modules.forEach((mod, idx) => {
    const group = document.createElement('div');
    group.className = 'module-group';
    group.dataset.module = mod.module;

    const header = document.createElement('div');
    header.className = 'module-header';
    header.innerHTML = `<span class="arrow">\u25BC</span>${mod.module}`;
    header.addEventListener('click', () => {
      header.classList.toggle('collapsed');
      list.classList.toggle('collapsed');
    });

    const list = document.createElement('div');
    list.className = 'project-list';

    mod.projects.forEach(proj => {
      const item = document.createElement('div');
      item.className = 'project-item';
      item.dataset.path = proj.path;
      item.innerHTML = `
        <span class="project-name">${proj.name}</span>
        ${proj.has_modules ? '<span class="module-badge">M</span>' : ''}
        <span class="tf-count">${proj.tf_files} tf</span>
      `;
      item.addEventListener('click', () => selectProject(proj, item));
      list.appendChild(item);
    });

    // Auto-collapse modules after the 3rd to reduce clutter
    if (idx >= 3) {
      header.classList.add('collapsed');
      list.classList.add('collapsed');
    }

    group.appendChild(header);
    group.appendChild(list);
    tree.appendChild(group);
  });
}


async function selectProject(proj, element) {
  // Update active state
  document.querySelectorAll('.project-item.active').forEach(el =>
    el.classList.remove('active')
  );
  element.classList.add('active');

  // Update toolbar
  document.getElementById('project-name').textContent = proj.path;
  document.getElementById('resource-count').textContent = '';

  // Show loading
  document.getElementById('welcome').classList.add('hidden');
  showLoading(true);

  try {
    const res = await fetch(`/api/project?path=${encodeURIComponent(proj.path)}`);
    const data = await res.json();

    if (data.error) {
      console.error(data.error);
      showLoading(false);
      return;
    }

    // Update resource count badge
    const total = data.stats.total_resources + data.stats.total_modules;
    document.getElementById('resource-count').textContent = `${total} resources`;

    // Update hidden count badge on detail button
    const hiddenCount = (data.resources || []).filter(r => r.hidden).length;
    const countEl = document.getElementById('btn-details-count');
    countEl.textContent = hiddenCount > 0 ? `+${hiddenCount}` : '';

    // Render diagram
    showDetails = false;
    document.getElementById('btn-details').classList.remove('active');
    document.getElementById('btn-details-label').textContent = '상세 보기';
    renderDiagram(data, showDetails);

    // Update legend
    updateLegend(data.stats.categories);

    // Show warnings if any
    if (data.warnings?.length) {
      console.warn('Parser warnings:', data.warnings);
    }
  } catch (err) {
    console.error('Failed to load project:', err);
  } finally {
    showLoading(false);
  }
}


function updateLegend(categories) {
  const legend = document.getElementById('legend');
  const items = document.getElementById('legend-items');

  if (!categories || Object.keys(categories).length === 0) {
    legend.classList.add('hidden');
    return;
  }

  legend.classList.remove('hidden');
  items.innerHTML = '';

  const categoryColors = {
    networking: '#8C4FFF',
    security: '#DD344C',
    compute: '#ED7100',
    loadbalancing: '#8C4FFF',
    database: '#3B48CC',
    storage: '#3F8624',
    cdn: '#8C4FFF',
    serverless: '#ED7100',
    iam: '#DD344C',
    container: '#ED7100',
    cicd: '#3B48CC',
    monitoring: '#E7157B',
    other: '#888888',
  };

  const categoryLabels = {
    networking: 'Networking',
    security: 'Security',
    compute: 'Compute',
    loadbalancing: 'Load Balancing',
    database: 'Database',
    storage: 'Storage',
    cdn: 'CDN & DNS',
    serverless: 'Serverless',
    iam: 'IAM',
    container: 'Containers',
    cicd: 'CI/CD',
    monitoring: 'Monitoring',
    other: 'Other',
  };

  for (const [cat, count] of Object.entries(categories).sort((a, b) => b[1] - a[1])) {
    const div = document.createElement('div');
    div.className = 'legend-item';
    div.innerHTML = `
      <span class="legend-dot" style="background:${categoryColors[cat] || '#888'}"></span>
      <span>${categoryLabels[cat] || cat} (${count})</span>
    `;
    items.appendChild(div);
  }
}


function onSearch(e) {
  const query = e.target.value.toLowerCase().trim();
  document.querySelectorAll('.module-group').forEach(group => {
    let hasVisible = false;
    group.querySelectorAll('.project-item').forEach(item => {
      const name = item.querySelector('.project-name').textContent.toLowerCase();
      const path = (item.dataset.path || '').toLowerCase();
      const match = !query || name.includes(query) || path.includes(query);
      item.style.display = match ? '' : 'none';
      if (match) hasVisible = true;
    });
    group.style.display = hasVisible ? '' : 'none';

    // Auto-expand matching groups
    if (query && hasVisible) {
      group.querySelector('.module-header')?.classList.remove('collapsed');
      group.querySelector('.project-list')?.classList.remove('collapsed');
    }
  });
}


function showLoading(show) {
  let loader = document.querySelector('.loading');
  if (show) {
    if (!loader) {
      loader = document.createElement('div');
      loader.className = 'loading';
      loader.innerHTML = '<div class="spinner"></div>';
      document.getElementById('canvas-container').appendChild(loader);
    }
  } else if (loader) {
    loader.remove();
  }
}
