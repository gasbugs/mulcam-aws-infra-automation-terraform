/**
 * Main application controller.
 * Handles sidebar, project selection, API calls, and diagram coordination.
 */

let showDetails = false;
let currentRepoId = '';  // '' = main repo, non-empty = uploaded/github repo

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

  // ZIP upload
  document.getElementById('btn-zip').addEventListener('click', () => {
    document.getElementById('zip-file-input').click();
  });
  document.getElementById('zip-file-input').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    e.target.value = '';  // reset so same file can be re-uploaded
    await loadZipFile(file);
  });

  // GitHub modal
  document.getElementById('btn-github').addEventListener('click', () => {
    document.getElementById('github-modal').classList.remove('hidden');
    document.getElementById('github-url-input').value = '';
    document.getElementById('github-error').classList.add('hidden');
    document.getElementById('github-url-input').focus();
  });
  document.getElementById('github-modal-close').addEventListener('click', closeGithubModal);
  document.getElementById('github-modal-cancel').addEventListener('click', closeGithubModal);
  document.getElementById('github-modal-load').addEventListener('click', loadGithubRepo);
  document.getElementById('github-url-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') loadGithubRepo();
    if (e.key === 'Escape') closeGithubModal();
  });
  document.getElementById('github-modal').addEventListener('click', (e) => {
    if (e.target === e.currentTarget) closeGithubModal();
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
    const repoParam = proj.repo_id ? `&repo_id=${encodeURIComponent(proj.repo_id)}` : '';
    const res = await fetch(`/api/project?path=${encodeURIComponent(proj.path)}${repoParam}`);
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
    hideCodePanel();
    currentRepoId = proj.repo_id || '';
    resetExpandState();
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


function closeGithubModal() {
  document.getElementById('github-modal').classList.add('hidden');
}


async function loadZipFile(file) {
  const formData = new FormData();
  formData.append('file', file);
  showLoading(true);
  try {
    const res = await fetch('/api/upload', { method: 'POST', body: formData });
    const data = await res.json();
    if (data.error) {
      alert(`업로드 실패: ${data.error}`);
      return;
    }
    renderUploadedSection(data.repo_id, data.name || file.name, data.modules);
  } catch (err) {
    alert(`업로드 중 오류: ${err.message}`);
  } finally {
    showLoading(false);
  }
}


async function loadGithubRepo() {
  const url = document.getElementById('github-url-input').value.trim();
  if (!url) return;

  const errEl = document.getElementById('github-error');
  const btn = document.getElementById('github-modal-load');
  errEl.classList.add('hidden');
  btn.disabled = true;
  btn.textContent = '가져오는 중...';

  try {
    const res = await fetch('/api/github', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url }),
    });
    const data = await res.json();
    if (data.error) {
      errEl.textContent = data.error;
      errEl.classList.remove('hidden');
      return;
    }
    closeGithubModal();
    renderUploadedSection(data.repo_id, data.name || url, data.modules);
  } catch (err) {
    errEl.textContent = `연결 오류: ${err.message}`;
    errEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
    btn.textContent = '가져오기';
  }
}


function renderUploadedSection(repoId, name, modules) {
  const tree = document.getElementById('project-tree');

  // Remove existing section with same repoId
  const existing = tree.querySelector(`[data-repo-id="${repoId}"]`);
  if (existing) existing.remove();

  const section = document.createElement('div');
  section.className = 'module-group';
  section.dataset.repoId = repoId;

  const header = document.createElement('div');
  header.className = 'upload-section-header';
  header.innerHTML = `
    <span class="upload-name" title="${name}">📦 ${name}</span>
    <button class="btn-remove-repo" title="제거">✕</button>
  `;
  header.querySelector('.btn-remove-repo').addEventListener('click', async () => {
    await fetch('/api/repo/remove', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repo_id: repoId }),
    });
    section.remove();
  });

  const list = document.createElement('div');
  list.className = 'project-list';

  // Flatten all projects from all modules
  const allProjects = modules.flatMap(m => m.projects.map(p => ({ ...p, repo_id: repoId })));

  if (!allProjects.length) {
    list.innerHTML = '<div style="padding:12px 34px;font-size:12px;color:#6b7280;">Terraform 프로젝트 없음</div>';
  } else {
    allProjects.forEach(proj => {
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
  }

  section.appendChild(header);
  section.appendChild(list);
  tree.appendChild(section);

  // Scroll to new section
  section.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}
