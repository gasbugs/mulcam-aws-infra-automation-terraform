/**
 * Layout engine — AWS Architecture Diagram style.
 *
 * Structure (top → bottom):
 *   [External row]  CloudFront, Route53, S3, WAF, CI/CD, API GW
 *       ↓
 *   [VPC box]                               [Side panel]
 *     [IGW] at VPC top border                IAM Roles
 *     ┌─ Public Subnet ──────────────┐       KMS
 *     │  ALB   NAT GW   EIP         │       Secrets
 *     └──────────────────────────────┘       CloudWatch
 *     ┌─ Private Subnet ─────────────┐
 *     │  EC2  ASG  ECS  EKS  Lambda  │
 *     └──────────────────────────────┘
 *     ┌─ Database ────────────────────┐
 *     │  RDS  Aurora  DynamoDB  Cache │
 *     └──────────────────────────────┘
 *
 * Module groups: a thin colored outline behind resources from the same module.
 */

const L = {
  NODE_W: 120,
  NODE_H: 116,
  NODE_GAP_X: 32,
  NODE_GAP_Y: 32,
  ZONE_PAD_X: 40,
  ZONE_PAD_Y: 44,     // top/bottom padding inside zone (below label)
  ZONE_HEADER: 44,    // height reserved for zone label text
  ZONE_GAP: 32,       // vertical gap between zone boxes
  VPC_PAD_X: 52,
  VPC_PAD_Y: 32,      // extra padding below VPC header label
  VPC_HEADER: 52,     // height reserved for VPC label
  EXTERNAL_PAD: 28,
  EXTERNAL_HEADER: 44,
  SIDE_PAD: 28,
  SIDE_GAP: 40,       // gap between VPC and side panels
  CANVAS_PAD: 48,
};

// Types that are visual containers, not leaf nodes
const STRUCTURAL = new Set(['aws_vpc', 'aws_subnet']);
// Types that belong at VPC boundary (not inside a subnet zone)
const VPC_BOUNDARY = new Set(['aws_internet_gateway', 'aws_nat_gateway']);


/**
 * Main entry point.
 * Returns { nodes, containers, moduleGroups, width, height }
 * @param {object} data - API response
 * @param {boolean} showDetails - if true, include hidden/plumbing nodes
 */
function computeLayout(data, showDetails = false) {
  const allResources = data.resources || [];
  const stubs = data.registry_modules || [];
  const dataSources = data.data_sources || [];

  // Primary leaf nodes: non-hidden, non-structural
  // When showDetails=true, also include hidden nodes (marked isDetail=true)
  const leafNodes = allResources.filter(r => !r.structural && (!r.hidden || showDetails))
    .map(r => r.hidden ? { ...r, isDetail: true } : r);
  const hasVPC = allResources.some(r =>
    r.type === 'aws_vpc' ||
    (r.category === 'networking' && !r.hidden)
  ) || stubs.some(m => m.source?.includes('vpc'));

  // Classify into zones
  const zones = {
    external: [],   // CloudFront, Route53, S3, WAF, API GW, ACM
    boundary: [],   // IGW (shown at VPC top border)
    public: [],     // ALB, NAT, EIP
    private: [],    // EC2, ASG, ECS, EKS, Lambda, ECR
    database: [],   // RDS, Aurora, DynamoDB, ElastiCache, EFS
    side: [],       // IAM, KMS, Secrets, CloudWatch
    cicd: [],       // CI/CD pipeline resources
  };

  for (const r of leafNodes) {
    const z = _classify(r);
    zones[z].push({ ...r, nodeType: 'resource' });
  }
  for (const s of stubs) {
    const z = _classifyStub(s);
    zones[z].push({ ...s, nodeType: 'module' });
  }
  // Data sources → side (only in detail view; they're reference lookups, not infra resources)
  if (showDetails) {
    for (const d of dataSources) {
      zones.side.push({ ...d, nodeType: 'data', isDetail: true });
    }
  }

  // ── Step 1: layout each vpc-internal zone ──────────────────────────
  const vpcInternalZones = ['public', 'private', 'database'];
  const zoneBoxes = {}; // zone → { items, innerW, innerH, cols, rows }
  let maxInnerW = 0;

  for (const zName of vpcInternalZones) {
    const items = zones[zName];
    if (!items.length) continue;
    const { cols, rows, innerW, innerH } = _gridSize(items);
    zoneBoxes[zName] = { items, cols, rows, innerW, innerH };
    maxInnerW = Math.max(maxInnerW, innerW);
  }

  // Boundary items (IGW etc.) at VPC top
  const boundaryItems = zones.boundary;
  if (boundaryItems.length) {
    const { innerW } = _gridSize(boundaryItems);
    maxInnerW = Math.max(maxInnerW, innerW);
  }

  // Zone container width = maxInnerW + padding on both sides
  const zoneW = maxInnerW + L.ZONE_PAD_X * 2;

  // ── Step 2: position zone containers inside VPC ──────────────────
  let vpcInnerY = L.VPC_HEADER + L.VPC_PAD_Y;

  // IGW / boundary at very top of VPC content
  let boundaryH = 0;
  if (boundaryItems.length) {
    const { innerH } = _gridSize(boundaryItems);
    boundaryH = innerH + L.ZONE_GAP;
    vpcInnerY += boundaryH;
  }

  const zoneContainers = [];
  let vpcInnerH = L.VPC_HEADER + L.VPC_PAD_Y + boundaryH;

  for (const zName of vpcInternalZones) {
    const box = zoneBoxes[zName];
    if (!box) continue;
    const containerH = L.ZONE_HEADER + L.ZONE_PAD_Y * 2 + box.innerH;
    zoneContainers.push({
      id: `zone-${zName}`,
      zone: zName,
      relY: vpcInnerY,           // relative to VPC top-left
      width: zoneW,
      height: containerH,
      label: _zoneLabel(zName),
      box,
    });
    vpcInnerY += containerH + L.ZONE_GAP;
    vpcInnerH += containerH + L.ZONE_GAP;
  }
  vpcInnerH += L.VPC_PAD_Y;

  // VPC container dimensions
  const vpcW = zoneW + L.VPC_PAD_X * 2;
  const vpcH = vpcInnerH;

  // ── Step 3: layout external left panel (CDN, S3 static, WAF — user-facing) ──
  const extItems = zones.external;
  let extPanelW = 0;
  let extPanelH = 0;
  let extGridInfo = null;
  if (extItems.length) {
    // Single column panel on the left (mirrors side panel style)
    const cols = 1;
    const rows = extItems.length;
    const innerW = L.NODE_W;
    const innerH = rows * L.NODE_H + (rows - 1) * L.NODE_GAP_Y;
    extGridInfo = { cols, rows, innerW, innerH };
    extPanelW = L.NODE_W + L.SIDE_PAD * 2;
    extPanelH = innerH + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER;
  }

  // ── Step 4: layout right side panel (IAM, monitoring, security) ──
  const sideItems = zones.side;
  let sideW = 0;
  let sideH = 0;
  if (sideItems.length) {
    sideW = L.NODE_W + L.SIDE_PAD * 2;
    sideH = sideItems.length * L.NODE_H + (sideItems.length - 1) * L.NODE_GAP_Y + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER;
  }

  // ── Step 4b: CI/CD panel (below side panel) ───────────────────────
  // If aws_codepipeline exists, it becomes the visual container for other CI/CD resources.
  const cicdItemsAll = zones.cicd;
  const cicdPipeline = cicdItemsAll.find(r => r.type === 'aws_codepipeline');
  const cicdChildren = cicdPipeline
    ? cicdItemsAll.filter(r => r.type !== 'aws_codepipeline')
    : cicdItemsAll;
  // Leaf items to lay out (children if pipeline exists, all if not)
  const cicdLeafs = cicdChildren;

  let cicdW = 0, cicdH = 0;
  let cicdPipeW = 0, cicdPipeH = 0;  // inner CodePipeline box dimensions

  if (cicdItemsAll.length) {
    if (cicdPipeline && cicdChildren.length > 0) {
      // Grid of children inside CodePipeline container
      const { innerW: cInW, innerH: cInH } = _gridSize(cicdChildren);
      cicdPipeW = cInW + L.ZONE_PAD_X * 2;
      cicdPipeH = L.ZONE_HEADER + L.ZONE_PAD_Y + cInH + L.ZONE_PAD_Y;
      cicdW = cicdPipeW + L.SIDE_PAD * 2;
      cicdH = cicdPipeH + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER;
    } else {
      // Flat list (no pipeline or pipeline is the only item)
      const leafCount = cicdLeafs.length || 1;
      cicdW = L.NODE_W + L.SIDE_PAD * 2;
      cicdH = leafCount * L.NODE_H + (leafCount - 1) * L.NODE_GAP_Y + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER;
    }
  }

  // ── Step 5: absolute positions ────────────────────────────────────
  const canvasX = L.CANVAS_PAD;
  const canvasY = L.CANVAS_PAD;

  // External left panel
  const extX = canvasX;
  const extY = canvasY;

  // VPC — offset right of external panel
  const vpcX = canvasX + (extPanelW > 0 ? extPanelW + L.SIDE_GAP : 0);
  const vpcY = canvasY;

  // Right side panel (IAM & Config)
  const sideX = vpcX + vpcW + L.SIDE_GAP;
  const sideY = vpcY;

  // CI/CD panel (below side panel)
  const cicdX = sideX;
  const cicdY = sideY + sideH + (sideH > 0 && cicdH > 0 ? L.SIDE_GAP : 0);

  // Total canvas
  const rightPanelW = Math.max(sideW, cicdW);
  const rightBottom = Math.max(sideY + sideH, cicdY + cicdH);
  const totalW = rightPanelW > 0 ? sideX + rightPanelW + L.CANVAS_PAD : vpcX + vpcW + L.CANVAS_PAD;
  const totalH = Math.max(vpcY + vpcH, rightBottom) + L.CANVAS_PAD;

  // ── Step 6: build node positions ──────────────────────────────────
  const allNodes = [];
  const nodeMap = {};

  // External nodes — left panel, single column
  if (extItems.length && extGridInfo) {
    const nodeX = extX + L.SIDE_PAD;
    extItems.forEach((item, i) => {
      item.x = nodeX;
      item.y = extY + L.EXTERNAL_HEADER + L.SIDE_PAD + i * (L.NODE_H + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = L.NODE_H;
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // Boundary (IGW) — centered at VPC top
  if (boundaryItems.length) {
    const { cols, innerW } = _gridSize(boundaryItems);
    const bOffsetX = vpcX + L.VPC_PAD_X + (zoneW - innerW) / 2;
    const bOffsetY = vpcY + L.VPC_HEADER + L.VPC_PAD_Y / 2;
    boundaryItems.forEach((item, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      item.x = bOffsetX + col * (L.NODE_W + L.NODE_GAP_X);
      item.y = bOffsetY + row * (L.NODE_H + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = L.NODE_H;
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // Zone nodes
  for (const zc of zoneContainers) {
    const { box } = zc;
    const zAbsX = vpcX + L.VPC_PAD_X;
    const zAbsY = vpcY + zc.relY;
    const { cols, innerW } = box;
    const nodeStartX = zAbsX + L.ZONE_PAD_X + (box.innerW < zoneW - L.ZONE_PAD_X * 2
      ? (zoneW - L.ZONE_PAD_X * 2 - innerW) / 2
      : 0);
    const nodeStartY = zAbsY + L.ZONE_HEADER + L.ZONE_PAD_Y;

    box.items.forEach((item, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      item.x = nodeStartX + col * (L.NODE_W + L.NODE_GAP_X);
      item.y = nodeStartY + row * (L.NODE_H + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = L.NODE_H;
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // Side nodes
  if (sideItems.length) {
    const nodeX = sideX + L.SIDE_PAD;
    sideItems.forEach((item, i) => {
      item.x = nodeX;
      item.y = sideY + L.EXTERNAL_HEADER + L.SIDE_PAD + i * (L.NODE_H + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = L.NODE_H;
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // CI/CD nodes
  if (cicdItemsAll.length) {
    if (cicdPipeline && cicdChildren.length > 0) {
      // Children go inside the CodePipeline container box
      const { cols } = _gridSize(cicdChildren);
      const pipeAbsX = cicdX + L.SIDE_PAD;
      const pipeAbsY = cicdY + L.EXTERNAL_HEADER + L.SIDE_PAD;
      const childStartX = pipeAbsX + L.ZONE_PAD_X;
      const childStartY = pipeAbsY + L.ZONE_HEADER + L.ZONE_PAD_Y;

      cicdChildren.forEach((item, i) => {
        const col = i % cols;
        const row = Math.floor(i / cols);
        item.x = childStartX + col * (L.NODE_W + L.NODE_GAP_X);
        item.y = childStartY + row * (L.NODE_H + L.NODE_GAP_Y);
        item.width = L.NODE_W;
        item.height = L.NODE_H;
        allNodes.push(item);
        nodeMap[item.id] = item;
      });

      // CodePipeline itself: in nodeMap as the container box for edge routing
      cicdPipeline.x = pipeAbsX;
      cicdPipeline.y = pipeAbsY;
      cicdPipeline.width = cicdPipeW;
      cicdPipeline.height = cicdPipeH;
      nodeMap[cicdPipeline.id] = cicdPipeline;
      // Not added to allNodes — rendered as a container, not a leaf icon
    } else {
      // Flat list (pipeline only, or no pipeline)
      const items = cicdLeafs.length ? cicdLeafs : cicdItemsAll;
      const nodeX = cicdX + L.SIDE_PAD;
      items.forEach((item, i) => {
        item.x = nodeX;
        item.y = cicdY + L.EXTERNAL_HEADER + L.SIDE_PAD + i * (L.NODE_H + L.NODE_GAP_Y);
        item.width = L.NODE_W;
        item.height = L.NODE_H;
        allNodes.push(item);
        nodeMap[item.id] = item;
      });
    }
  }

  // ── Step 7: build container list for rendering ─────────────────────
  const containers = [];

  // External left panel
  if (extItems.length) {
    const panelH = Math.max(extPanelH, vpcH); // match VPC height
    containers.push({
      id: 'zone-external',
      zone: 'external',
      x: extX, y: extY,
      width: extPanelW,
      height: panelH,
      label: 'External',
    });
  }

  // VPC
  if (hasVPC) {
    containers.push({
      id: 'vpc-container',
      zone: 'vpc',
      x: vpcX, y: vpcY,
      width: vpcW, height: vpcH,
      label: 'VPC',
      isVPC: true,
    });
  }

  // Zone containers (absolute positions)
  for (const zc of zoneContainers) {
    containers.push({
      id: zc.id,
      zone: zc.zone,
      x: vpcX + L.VPC_PAD_X,
      y: vpcY + zc.relY,
      width: zoneW,
      height: zc.height,
      label: zc.label,
    });
  }

  // Side panel
  if (sideItems.length) {
    containers.push({
      id: 'zone-side',
      zone: 'side',
      x: sideX, y: sideY,
      width: sideW, height: sideH,
      label: 'IAM & Config',
    });
  }

  // CI/CD panel
  if (cicdItemsAll.length) {
    // Outer panel box
    containers.push({
      id: 'zone-cicd',
      zone: 'cicd',
      x: cicdX, y: cicdY,
      width: cicdW, height: cicdH,
      label: 'CI/CD',
    });

    // Inner CodePipeline container box (if pipeline wraps children)
    if (cicdPipeline && cicdChildren.length > 0) {
      containers.push({
        id: 'container-pipeline',
        zone: 'pipeline',
        x: cicdX + L.SIDE_PAD,
        y: cicdY + L.EXTERNAL_HEADER + L.SIDE_PAD,
        width: cicdPipeW,
        height: cicdPipeH,
        label: `aws_codepipeline  "${cicdPipeline.name}"`,
        isPipeline: true,
      });
    }
  }

  // ── Step 8: module groups ──────────────────────────────────────────
  const moduleGroups = _computeModuleGroups(allNodes);

  return { nodes: allNodes, containers, moduleGroups, nodeMap, width: totalW, height: totalH };
}


// ── Helpers ──────────────────────────────────────────────────────────

const VALID_ZONES = new Set(['external', 'boundary', 'public', 'private', 'database', 'side', 'cicd']);

function _classify(r) {
  const t = r.type;
  // Boundary resources
  if (t === 'aws_internet_gateway') return 'boundary';
  // External: CDN, DNS, WAF, ACM (user-facing front door)
  if (r.category === 'cdn') return 'external';
  if (['aws_wafv2_web_acl', 'aws_wafv2_web_acl_association'].includes(t)) return 'external';
  if (t === 'aws_acm_certificate' || t === 'aws_acm_certificate_validation') return 'external';
  // S3 that's likely a website (external), otherwise storage
  if (t === 'aws_s3_bucket' && !r.from_module) return 'external';
  if (r.category === 'storage') return 'database'; // EFS, EBS near DB
  // Side: IAM, monitoring, encryption, CI/CD (support services — not traffic path)
  if (['iam', 'monitoring', 'security'].includes(r.category)) return 'side';
  if (r.category === 'cicd') return 'cicd';
  if (['aws_kms_key', 'aws_kms_alias', 'aws_secretsmanager_secret',
       'aws_secretsmanager_secret_version'].includes(t)) return 'side';
  // Public: LB, NAT
  if (r.category === 'loadbalancing') return 'public';
  if (t === 'aws_nat_gateway' || t === 'aws_eip') return 'public';
  // Database
  if (r.category === 'database') return 'database';
  // Private: compute, containers, serverless
  if (['compute', 'container', 'serverless'].includes(r.category)) return 'private';
  // Networking that's not structural → private
  if (r.category === 'networking') return 'private';
  // Fallback: use catalog zone if valid, else private
  return VALID_ZONES.has(r.zone) ? r.zone : 'private';
}

function _classifyStub(m) {
  const s = (m.source || '').toLowerCase();
  if (s.includes('vpc')) return 'boundary';
  if (s.includes('eks') || s.includes('ecs')) return 'private';
  if (s.includes('iam')) return 'side';
  if (s.includes('s3')) return 'external';
  return 'private';
}

function _gridSize(items) {
  const n = items.length;
  const cols = Math.min(n, Math.max(1, Math.ceil(Math.sqrt(n * 1.8))));
  const rows = Math.ceil(n / cols);
  const innerW = cols * L.NODE_W + (cols - 1) * L.NODE_GAP_X;
  const innerH = rows * L.NODE_H + (rows - 1) * L.NODE_GAP_Y;
  return { cols, rows, innerW, innerH };
}

function _zoneLabel(zone) {
  return {
    external: 'External Services',
    public: 'Public Subnet',
    private: 'Private / Compute',
    database: 'Database / Storage',
    side: 'IAM & Config',
    cicd: 'CI/CD Pipeline',
  }[zone] || zone;
}

const MODULE_COLORS = [
  '#7B42BC', '#147EB3', '#3F8624', '#ED7100',
  '#DD344C', '#3B48CC', '#E7157B', '#546E7A',
];

function _moduleColorIndex(name) {
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) & 0xffff;
  return h % MODULE_COLORS.length;
}

function _computeModuleGroups(nodes) {
  const groups = {};
  for (const n of nodes) {
    if (!n.from_module) continue;
    const key = n.from_module;
    if (!groups[key]) groups[key] = { name: key, nodes: [] };
    groups[key].nodes.push(n);
  }

  return Object.values(groups).map(g => {
    const PAD = 8;
    const xs = g.nodes.map(n => n.x);
    const ys = g.nodes.map(n => n.y);
    const x2 = g.nodes.map(n => n.x + n.width);
    const y2 = g.nodes.map(n => n.y + n.height);
    const bx = Math.min(...xs) - PAD;
    const by = Math.min(...ys) - PAD - 14; // room for label
    const bw = Math.max(...x2) - Math.min(...xs) + PAD * 2;
    const bh = Math.max(...y2) - Math.min(...ys) + PAD * 2 + 14;
    const color = MODULE_COLORS[_moduleColorIndex(g.name)];
    return { name: g.name, x: bx, y: by, width: bw, height: bh, color };
  });
}


/**
 * Compute edge paths between visible nodes.
 * Skips edges where either endpoint is not in nodeMap.
 */
function computeEdgePaths(edges, nodeMap) {
  const validEdges = edges.filter(e => nodeMap[e.from] && nodeMap[e.to]);

  // Count how many edges leave/enter each node to compute spread offsets
  const outCount = {}, inCount = {};
  validEdges.forEach(e => {
    outCount[e.from] = (outCount[e.from] || 0) + 1;
    inCount[e.to]   = (inCount[e.to]   || 0) + 1;
  });

  const outIdx = {}, inIdx = {};

  return validEdges.map(edge => {
    const from = nodeMap[edge.from];
    const to   = nodeMap[edge.to];

    // Running index for this source / target
    const oi = outIdx[edge.from] ?? 0; outIdx[edge.from] = oi + 1;
    const ii = inIdx[edge.to]   ?? 0; inIdx[edge.to]   = ii + 1;

    const fcx = from.x + from.width  / 2;
    const fcy = from.y + from.height / 2;
    const tcx = to.x   + to.width    / 2;
    const tcy = to.y   + to.height   / 2;

    const dx = tcx - fcx, dy = tcy - fcy;
    let x1, y1, x2, y2;

    if (Math.abs(dy) >= Math.abs(dx)) {
      // Vertical-dominant: spread exit/entry points along the horizontal edge
      const fOff = _edgeSpread(oi, outCount[edge.from], from.width  * 0.3);
      const tOff = _edgeSpread(ii, inCount[edge.to],    to.width    * 0.3);
      if (dy > 0) { x1 = fcx + fOff; y1 = from.y + from.height; x2 = tcx + tOff; y2 = to.y; }
      else         { x1 = fcx + fOff; y1 = from.y;               x2 = tcx + tOff; y2 = to.y + to.height; }
    } else {
      // Horizontal-dominant: spread exit/entry points along the vertical edge
      const fOff = _edgeSpread(oi, outCount[edge.from], from.height * 0.3);
      const tOff = _edgeSpread(ii, inCount[edge.to],    to.height   * 0.3);
      if (dx > 0) { x1 = from.x + from.width; y1 = fcy + fOff; x2 = to.x;               y2 = tcy + tOff; }
      else        { x1 = from.x;              y1 = fcy + fOff; x2 = to.x + to.width;    y2 = tcy + tOff; }
    }

    const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    const path = Math.abs(dy) >= Math.abs(dx)
      ? `M${x1},${y1} C${x1},${my} ${x2},${my} ${x2},${y2}`
      : `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`;

    return { ...edge, path, x1, y1, x2, y2 };
  });
}

/**
 * Spread offset: distribute `total` connection points evenly within ±maxHalfRange.
 * Caps each step at 14px to avoid extreme spreading on high-degree nodes.
 */
function _edgeSpread(index, total, maxHalfRange) {
  if (total <= 1) return 0;
  const step = Math.min((maxHalfRange * 2) / (total - 1), 14);
  return (index - (total - 1) / 2) * step;
}
