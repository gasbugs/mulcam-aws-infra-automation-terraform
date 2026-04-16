/**
 * D3.js SVG diagram renderer for Terraform infrastructure.
 */

let currentData = null;
let svg, rootG, zoom;
let selectedNode = null;
let expandedNodeIds = new Set();  // nodes with individually expanded hidden resources
let currentNodeMap = {};          // visible nodeId -> node (for code panel links)
let _needsFit = true;             // whether next render should auto-fit

function initDiagram() {
  svg = d3.select('#diagram');
  rootG = svg.append('g').attr('class', 'root');

  // Code panel close button
  document.getElementById('code-panel-close')?.addEventListener('click', () => _clearSelection());

  // Code panel: click on AWS resource reference → select that node + pan to it
  document.getElementById('code-panel-content')?.addEventListener('click', (e) => {
    const ref = e.target.closest('[data-ref]');
    if (!ref) return;
    const resourceId = ref.dataset.ref;
    const node = currentNodeMap[resourceId];
    if (!node) return;
    // Deselect current first so toggleHighlight always re-selects the target
    if (selectedNode && selectedNode !== node.id) {
      selectedNode = null;
      d3.selectAll('.resource-node').classed('highlighted', false).classed('dimmed', false);
      d3.selectAll('.edge-line').classed('highlighted', false).classed('dimmed', false);
    }
    toggleHighlight(node);
    panToNode(node);
  });

  // Defs for arrowheads
  const defs = svg.append('defs');
  ['network', 'iam', 'loadbalancer', 'reference', 'data'].forEach(type => {
    const colors = {
      network: '#147EB3', iam: '#DD344C', loadbalancer: '#8C4FFF',
      reference: '#9ca3af', data: '#6b7280'
    };
    defs.append('marker')
      .attr('id', `arrow-${type}`)
      .attr('viewBox', '0 0 10 10')
      .attr('refX', 9)
      .attr('refY', 5)
      .attr('markerWidth', 6)
      .attr('markerHeight', 6)
      .attr('orient', 'auto-start-reverse')
      .append('path')
      .attr('d', 'M 0 0 L 10 5 L 0 10 z')
      .attr('fill', colors[type] || '#9ca3af');
  });

  // Zoom behavior
  zoom = d3.zoom()
    .scaleExtent([0.1, 3])
    .on('zoom', (event) => {
      rootG.attr('transform', event.transform);
    });

  svg.call(zoom);

  // Background click → deselect (check that click is NOT on a node or badge)
  svg.node().addEventListener('click', (event) => {
    if (!event.target.closest('.resource-node') && !event.target.closest('.expand-badge')) {
      _clearSelection();
    }
  });

  // Code panel resize handle — drag up/down to resize panel height
  const resizeHandle = document.getElementById('code-panel-resize');
  if (resizeHandle) {
    let _resizing = false;
    let _startY = 0;
    let _startH = 0;
    const MIN_H = 80;
    const MAX_H_RATIO = 0.8;

    resizeHandle.addEventListener('mousedown', (e) => {
      e.preventDefault();
      e.stopPropagation();
      _resizing = true;
      _startY = e.clientY;
      const panel = document.getElementById('code-panel');
      // Use getBoundingClientRect for reliable height even with CSS transform
      _startH = panel.getBoundingClientRect().height;
      resizeHandle.classList.add('dragging');
      document.body.style.userSelect = 'none';
      document.body.style.cursor = 'ns-resize';
    });

    document.addEventListener('mousemove', (e) => {
      if (!_resizing) return;
      const panel = document.getElementById('code-panel');
      const delta = _startY - e.clientY;  // drag up = positive delta = increase height
      const maxH = Math.floor(window.innerHeight * MAX_H_RATIO);
      const newH = Math.min(maxH, Math.max(MIN_H, _startH + delta));
      // Disable transition temporarily so resize is instant
      panel.style.transition = 'none';
      panel.style.height = newH + 'px';
    });

    document.addEventListener('mouseup', () => {
      if (_resizing) {
        _resizing = false;
        resizeHandle.classList.remove('dragging');
        document.body.style.userSelect = '';
        document.body.style.cursor = '';
        // Restore transition after resize ends
        const panel = document.getElementById('code-panel');
        panel.style.transition = '';
      }
    });
  }
}


function _clearSelection() {
  selectedNode = null;
  d3.selectAll('.resource-node').classed('highlighted', false).classed('dimmed', false);
  d3.selectAll('.edge-line').classed('highlighted', false).classed('dimmed', false);
  hideCodePanel();
}


/** Called when switching projects — reset per-diagram state. */
function resetExpandState() {
  expandedNodeIds = new Set();
  currentNodeMap = {};
  _needsFit = true;
}

function renderDiagram(data, showDetails = false) {
  currentData = data;
  selectedNode = null;
  rootG.selectAll('*').remove();

  // Pre-compute hidden neighbor sets for +N badges (before layout)
  const hiddenSet = new Set((data.resources || []).filter(r => r.hidden).map(r => r.id));
  const visibleSet = new Set((data.resources || []).filter(r => !r.hidden && !r.structural).map(r => r.id));
  const hiddenNeighborSets = {};
  for (const edge of (data.edges || [])) {
    if (visibleSet.has(edge.from) && hiddenSet.has(edge.to)) {
      if (!hiddenNeighborSets[edge.from]) hiddenNeighborSets[edge.from] = new Set();
      hiddenNeighborSets[edge.from].add(edge.to);
    }
    if (hiddenSet.has(edge.from) && visibleSet.has(edge.to)) {
      if (!hiddenNeighborSets[edge.to]) hiddenNeighborSets[edge.to] = new Set();
      hiddenNeighborSets[edge.to].add(edge.from);
    }
  }

  if (!data.resources.length && !data.registry_modules.length) {
    rootG.append('text')
      .attr('x', 200).attr('y', 150)
      .attr('class', 'node-name')
      .attr('font-size', 16)
      .text('No resources found in this project');
    return;
  }

  // Compute layout (pass expandedNodeIds to reveal per-node hidden resources)
  const layout = computeLayout(data, showDetails, expandedNodeIds);

  // nodeMap is built inside layout now, use it directly
  const nodeMap = layout.nodeMap || {};
  if (!Object.keys(nodeMap).length) {
    layout.nodes.forEach(n => { nodeMap[n.id] = n; });
  }
  currentNodeMap = nodeMap;

  // Draw containers (back to front: VPC first, then zone boxes)
  const containerG = rootG.append('g').attr('class', 'containers');
  // Sort: VPC first (largest, drawn behind everything)
  const sortedContainers = [...layout.containers].sort((a, b) =>
    (b.isVPC ? 1 : 0) - (a.isVPC ? 1 : 0)
  );
  sortedContainers.forEach(c => {
    const cg = containerG.append('g').attr('class', `container container-${c.zone}`);

    const cssClass = c.isVPC ? 'container-vpc' :
      c.zone === 'public' ? 'container-subnet-public' :
      c.zone === 'private' ? 'container-subnet-private' :
      c.zone === 'database' ? 'container-database' :
      c.zone === 'external' ? 'container-external' :
      c.zone === 'side' ? 'container-side' :
      c.zone === 'cicd' ? 'container-cicd' :
      c.zone === 'pipeline' ? 'container-pipeline' :
      'container-subnet-public';

    cg.append('rect')
      .attr('class', cssClass)
      .attr('x', c.x).attr('y', c.y)
      .attr('width', c.width).attr('height', c.height)
      .attr('rx', c.isVPC ? 12 : 8);

    // Zone label with icon indicator
    cg.append('text')
      .attr('class', 'container-label')
      .attr('x', c.x + 16)
      .attr('y', c.y + (c.isVPC ? 34 : 27))
      .text(c.label);
  });

  // Draw module group boxes (behind edges but above zone containers)
  if (layout.moduleGroups && layout.moduleGroups.length) {
    const mgG = rootG.append('g').attr('class', 'module-groups');
    layout.moduleGroups.forEach(mg => {
      const shortName = mg.name.split('.').slice(-1)[0]; // last segment
      const col = mg.color;

      mgG.append('rect')
        .attr('class', 'module-group-box')
        .attr('x', mg.x).attr('y', mg.y)
        .attr('width', mg.width).attr('height', mg.height)
        .attr('rx', 6)
        .style('fill', col + '14')
        .style('stroke', col + '66')
        .style('stroke-width', 1.5)
        .style('stroke-dasharray', '5 3');

      mgG.append('text')
        .attr('class', 'module-group-label')
        .attr('x', mg.x + 6)
        .attr('y', mg.y + 11)
        .style('fill', col)
        .style('font-size', '10px')
        .style('font-weight', '600')
        .style('opacity', '0.8')
        .text(`module.${shortName}`);
    });
  }

  // Draw edges
  const edgePaths = computeEdgePaths(data.edges, nodeMap);
  const edgeG = rootG.append('g').attr('class', 'edges');
  edgeG.selectAll('.edge-line')
    .data(edgePaths)
    .join('path')
    .attr('class', d => `edge-line type-${d.type}`)
    .attr('d', d => d.path)
    .attr('marker-end', d => `url(#arrow-${d.type})`)
    .attr('data-from', d => d.from)
    .attr('data-to', d => d.to);

  // Draw resource nodes
  const nodeG = rootG.append('g').attr('class', 'nodes');
  layout.nodes.forEach(node => {
    const isModule = node.nodeType === 'module';
    const isData = node.nodeType === 'data';
    const isDetail = !!node.isDetail;
    const g = nodeG.append('g')
      .attr('class', `resource-node ${isModule ? 'module-node' : ''} ${isData ? 'data-node' : ''} ${isDetail ? 'node-detail' : ''}`)
      .attr('data-id', node.id)
      .attr('transform', `translate(${node.x}, ${node.y})`)
      .on('mouseenter', (event) => showTooltip(event, node))
      .on('mouseleave', hideTooltip)
      .on('click', () => toggleHighlight(node));

    // Background card
    g.append('rect')
      .attr('class', 'node-bg')
      .attr('width', node.width)
      .attr('height', node.height)
      .attr('rx', 8)
      .style('stroke', isData ? '#6b7280' : undefined)
      .style('stroke-dasharray', isData ? '4 2' : undefined);

    // Icon
    const iconSize = 48;
    const iconX = (node.width - iconSize) / 2;
    const iconG = g.append('g')
      .attr('transform', `translate(${iconX}, 8)`);
    renderIcon(iconG, node.icon || 'generic', iconSize);

    // Resource type label
    const typeLabel = isModule ? 'module' : _shortType(node.type);
    g.append('text')
      .attr('class', 'node-label')
      .attr('x', node.width / 2)
      .attr('y', iconSize + 20)
      .text(typeLabel);

    // Resource name
    const displayName = _shortName(node.name || node.label || node.id);
    g.append('text')
      .attr('class', 'node-name')
      .attr('x', node.width / 2)
      .attr('y', iconSize + 33)
      .text(displayName);

    // Module sub-resources list
    if (isModule && node.sub_resources?.length) {
      node.sub_resources.forEach((sr, i) => {
        if (i < 3) {
          g.append('text')
            .attr('class', 'module-sub-label')
            .attr('x', node.width / 2)
            .attr('y', iconSize + 46 + i * 12)
            .attr('text-anchor', 'middle')
            .text(sr);
        }
      });
    }

    // Count badge
    if (node.count && typeof node.count === 'number' && node.count > 1) {
      const badge = g.append('g').attr('transform', `translate(${node.width - 20}, 4)`);
      badge.append('circle')
        .attr('cx', 10).attr('cy', 10).attr('r', 10)
        .attr('fill', node.color || '#666');
      badge.append('text')
        .attr('class', 'node-count-badge')
        .attr('x', 10).attr('y', 14)
        .attr('text-anchor', 'middle')
        .text(`x${node.count}`);
    }

    // for_each badge
    if (node.for_each) {
      const badge = g.append('g').attr('transform', `translate(${node.width - 24}, 4)`);
      badge.append('rect')
        .attr('width', 20).attr('height', 14).attr('rx', 3)
        .attr('fill', node.color || '#666');
      badge.append('text')
        .attr('class', 'node-count-badge')
        .attr('x', 10).attr('y', 11)
        .attr('text-anchor', 'middle')
        .attr('font-size', 8)
        .text('N');
    }

    // Expand badge (+N): show for nodes with hidden neighbors (only when !showDetails)
    const hiddenNbrs = hiddenNeighborSets[node.id];
    if (!showDetails && hiddenNbrs && hiddenNbrs.size > 0 && !isDetail) {
      const isExpanded = expandedNodeIds.has(node.id);
      const badge = g.append('g')
        .attr('class', 'expand-badge')
        .attr('transform', `translate(4, ${node.height - 20})`)
        .style('cursor', 'pointer')
        .on('click', (event) => {
          event.stopPropagation();
          if (expandedNodeIds.has(node.id)) expandedNodeIds.delete(node.id);
          else expandedNodeIds.add(node.id);
          renderDiagram(currentData, showDetails);
        });

      badge.append('circle')
        .attr('cx', 8).attr('cy', 8).attr('r', 8)
        .attr('fill', isExpanded ? '#3B48CC' : '#9ca3af')
        .attr('stroke', '#fff').attr('stroke-width', 1.5);

      badge.append('text')
        .attr('x', 8).attr('y', 12.5)
        .attr('text-anchor', 'middle')
        .attr('font-size', isExpanded ? 11 : 8)
        .attr('font-weight', '700')
        .attr('fill', '#fff')
        .text(isExpanded ? '−' : `+${hiddenNbrs.size}`);
    }
  });

  // Fit to view (only on first render or project change)
  if (_needsFit) {
    fitToView(layout);
    _needsFit = false;
  }
}


/** Smoothly pan the diagram to center on the given node, preserving current zoom scale. */
function panToNode(node) {
  if (!node) return;
  const svgEl = document.getElementById('diagram');
  const rect = svgEl.getBoundingClientRect();
  const cx = node.x + node.width / 2;
  const cy = node.y + node.height / 2;
  const k = d3.zoomTransform(svg.node()).k;
  // Center the node, but keep code panel height in mind (subtract ~150px from center)
  const tx = rect.width / 2 - cx * k;
  const ty = (rect.height - 150) / 2 - cy * k;
  svg.transition().duration(400).call(
    zoom.transform,
    d3.zoomIdentity.translate(tx, ty).scale(k)
  );
}


function fitToView(layout) {
  if (!layout) return;
  const svgEl = document.getElementById('diagram');
  const rect = svgEl.getBoundingClientRect();
  const padFraction = 0.9;

  const scaleX = (rect.width * padFraction) / layout.width;
  const scaleY = (rect.height * padFraction) / layout.height;
  const scale = Math.min(scaleX, scaleY, 1.5);

  const tx = (rect.width - layout.width * scale) / 2;
  const ty = (rect.height - layout.height * scale) / 2;

  svg.transition().duration(500).call(
    zoom.transform,
    d3.zoomIdentity.translate(tx, ty).scale(scale)
  );
}


function toggleHighlight(node) {
  if (selectedNode === node.id) {
    // Deselect — close panel
    selectedNode = null;
    d3.selectAll('.resource-node').classed('highlighted', false).classed('dimmed', false);
    d3.selectAll('.edge-line').classed('highlighted', false).classed('dimmed', false);
    hideCodePanel();
    return;
  }

  selectedNode = node.id;

  // Find connected edges
  const connectedEdges = currentData.edges.filter(e => e.from === node.id || e.to === node.id);
  const connectedIds = new Set([node.id]);
  connectedEdges.forEach(e => {
    connectedIds.add(e.from);
    connectedIds.add(e.to);
  });

  // Highlight connected, dim others
  d3.selectAll('.resource-node').each(function() {
    const id = d3.select(this).attr('data-id');
    d3.select(this)
      .classed('highlighted', id === node.id)
      .classed('dimmed', !connectedIds.has(id));
  });

  d3.selectAll('.edge-line').each(function() {
    const from = d3.select(this).attr('data-from');
    const to = d3.select(this).attr('data-to');
    const isConnected = from === node.id || to === node.id;
    d3.select(this)
      .classed('highlighted', isConnected)
      .classed('dimmed', !isConnected);
  });

  // Show source code in bottom panel
  fetchAndShowCode(node);
}


async function fetchAndShowCode(node) {
  if (!currentData?.path) return;

  const panel = document.getElementById('code-panel');
  const titleEl = document.getElementById('code-panel-title');
  const fileEl = document.getElementById('code-panel-file');
  const contentEl = document.getElementById('code-panel-content');

  titleEl.textContent = node.id;
  fileEl.textContent = node.file ? `📄 ${node.file}` : '';
  contentEl.innerHTML = '<span class="hcl-comment">Loading…</span>';
  panel.classList.remove('hidden');

  try {
    const repoParam = (typeof currentRepoId !== 'undefined' && currentRepoId)
      ? `&repo_id=${encodeURIComponent(currentRepoId)}` : '';
    const res = await fetch(
      `/api/source?path=${encodeURIComponent(currentData.path)}&id=${encodeURIComponent(node.id)}${repoParam}`
    );
    const data = await res.json();

    if (data.error) {
      contentEl.innerHTML = `<span class="hcl-comment"># ${_escHtml(data.error)}</span>`;
    } else {
      fileEl.textContent = data.file ? `📄 ${data.file}` : '';
      contentEl.innerHTML = _highlightHCL(data.source || '');
      // Mark refs that exist in the current diagram as clickable links
      contentEl.querySelectorAll('[data-ref]').forEach(el => {
        if (currentNodeMap[el.dataset.ref]) el.classList.add('hcl-ref-link');
      });
    }
  } catch (err) {
    contentEl.innerHTML = `<span class="hcl-comment"># Failed to load source</span>`;
  }
}


function hideCodePanel() {
  document.getElementById('code-panel')?.classList.add('hidden');
}


function _escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}


function _highlightHCL(code) {
  // Escape HTML first, then apply token-based highlighting
  const lines = code.split('\n');
  return lines.map(line => {
    // Comments
    if (/^\s*#/.test(line)) return `<span class="hcl-comment">${_escHtml(line)}</span>`;

    // Process token by token using a simple state machine
    let out = '';
    let i = 0;
    const raw = line;

    while (i < raw.length) {
      // String literal
      if (raw[i] === '"') {
        let j = i + 1;
        while (j < raw.length && raw[j] !== '"') {
          if (raw[j] === '\\') j++;
          j++;
        }
        out += `<span class="hcl-string">${_escHtml(raw.slice(i, j + 1))}</span>`;
        i = j + 1;
        continue;
      }

      // Inline comment
      if (raw[i] === '#') {
        out += `<span class="hcl-comment">${_escHtml(raw.slice(i))}</span>`;
        break;
      }

      // Keyword (resource|data|module|variable|output|locals|terraform|provider)
      const kwMatch = raw.slice(i).match(/^(resource|data|module|variable|output|locals|terraform|provider)\b/);
      if (kwMatch) {
        out += `<span class="hcl-keyword">${kwMatch[1]}</span>`;
        i += kwMatch[1].length;
        continue;
      }

      // Attribute key (word followed by optional spaces then = or {)
      const attrMatch = raw.slice(i).match(/^([a-z_][a-z0-9_]*)(\s*=|\s*\{)/);
      if (attrMatch && !/^\s/.test(raw.slice(0, i))) {
        out += `<span class="hcl-attr">${_escHtml(attrMatch[1])}</span>`;
        i += attrMatch[1].length;
        continue;
      }

      // AWS resource references (aws_type.name[.attr])
      const refMatch = raw.slice(i).match(/^(aws_[a-z_]+)\.([a-z_][a-z0-9_]*)(\.[a-z0-9_.]*)?/);
      if (refMatch) {
        const resourceId = `${refMatch[1]}.${refMatch[2]}`;
        const fullRef = refMatch[0];
        out += `<span class="hcl-ref" data-ref="${_escHtml(resourceId)}" title="→ ${_escHtml(resourceId)}">${_escHtml(fullRef)}</span>`;
        i += fullRef.length;
        continue;
      }

      // Number
      const numMatch = raw.slice(i).match(/^(\d+)/);
      if (numMatch && (i === 0 || !/\w/.test(raw[i - 1]))) {
        out += `<span class="hcl-number">${numMatch[1]}</span>`;
        i += numMatch[1].length;
        continue;
      }

      // Default: emit single char
      out += _escHtml(raw[i]);
      i++;
    }
    return out;
  }).join('\n');
}


function showTooltip(event, node) {
  const tooltip = document.getElementById('tooltip');
  const type = node.nodeType === 'module' ? node.source : node.type;
  const name = node.name || node.label;
  const detail = [];

  if (node.category) detail.push(`Category: ${node.category}`);
  if (node.file) detail.push(`File: ${node.file}`);
  if (node.from_module) detail.push(`Module: ${node.from_module}`);
  if (node.count && node.count !== 1) detail.push(`Count: ${node.count}`);
  if (node.for_each) detail.push('Dynamic: for_each');

  tooltip.innerHTML = `
    <div class="tt-type">${type}</div>
    <div class="tt-name">${name}</div>
    ${detail.length ? `<div class="tt-detail">${detail.join(' | ')}</div>` : ''}
  `;

  tooltip.classList.remove('hidden');
  tooltip.style.left = (event.clientX + 12) + 'px';
  tooltip.style.top = (event.clientY - 10) + 'px';
}


function hideTooltip() {
  document.getElementById('tooltip').classList.add('hidden');
}


function exportSVG() {
  const svgEl = document.getElementById('diagram');
  const clone = svgEl.cloneNode(true);
  clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');

  // Inline critical styles
  const style = document.createElement('style');
  style.textContent = `
    .container-vpc { fill: #e8f4fd; stroke: #147EB3; stroke-width: 2; rx: 12; }
    .container-subnet-public { fill: #e6f9ee; stroke: #3F8624; stroke-width: 1.5; stroke-dasharray: 6 3; rx: 8; }
    .container-subnet-private { fill: #fff4e6; stroke: #ED7100; stroke-width: 1.5; stroke-dasharray: 6 3; rx: 8; }
    .container-database { fill: #eef0ff; stroke: #3B48CC; stroke-width: 1.5; stroke-dasharray: 6 3; rx: 8; }
    .node-bg { fill: #fff; stroke: #e5e7eb; stroke-width: 1; rx: 8; }
    .node-label { font-size: 10px; fill: #6b7280; text-anchor: middle; font-family: sans-serif; }
    .node-name { font-size: 11px; fill: #1f2937; font-weight: 600; text-anchor: middle; font-family: sans-serif; }
    .container-label { font-size: 13px; font-weight: 600; fill: #374151; font-family: sans-serif; }
    .edge-line { fill: none; stroke-width: 1.5; opacity: 0.5; }
    .edge-line.type-network { stroke: #147EB3; }
    .edge-line.type-iam { stroke: #DD344C; }
    .edge-line.type-loadbalancer { stroke: #8C4FFF; }
    .edge-line.type-reference { stroke: #9ca3af; }
    .module-node .node-bg { stroke: #7B42BC; stroke-width: 1.5; fill: #f5f0ff; }
  `;
  clone.insertBefore(style, clone.firstChild);

  const blob = new Blob([clone.outerHTML], { type: 'image/svg+xml' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `terraform-${currentData?.path?.replace(/\//g, '-') || 'diagram'}.svg`;
  a.click();
  URL.revokeObjectURL(url);
}


function _shortType(type) {
  if (!type) return '';
  const s = type.replace(/^aws_/, '').replace(/_/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
  return s.length > 14 ? s.substring(0, 13) + '…' : s;
}


function _shortName(name) {
  if (!name) return '';
  // For dot-separated names (module paths), show only the last segment
  const parts = name.split('.');
  const short = parts[parts.length - 1];
  return short.length > 13 ? short.substring(0, 12) + '…' : short;
}
