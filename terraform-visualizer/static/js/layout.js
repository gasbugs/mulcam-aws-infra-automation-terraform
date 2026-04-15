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
  NODE_W: 116,
  NODE_H: 88,
  NODE_GAP_X: 20,
  NODE_GAP_Y: 16,
  ZONE_PAD_X: 28,
  ZONE_PAD_Y: 24,
  ZONE_HEADER: 26,
  ZONE_GAP: 16,
  VPC_PAD_X: 36,
  VPC_PAD_Y: 28,
  VPC_HEADER: 32,
  EXTERNAL_PAD: 28,
  EXTERNAL_HEADER: 24,
  SIDE_PAD: 20,
  SIDE_GAP: 24,        // gap between VPC and side panel
  CANVAS_PAD: 40,
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
    external: [],   // CloudFront, Route53, S3, WAF, API GW, CI/CD, ACM
    boundary: [],   // IGW (shown at VPC top border)
    public: [],     // ALB, NAT, EIP
    private: [],    // EC2, ASG, ECS, EKS, Lambda, ECR
    database: [],   // RDS, Aurora, DynamoDB, ElastiCache, EFS
    side: [],       // IAM, KMS, Secrets, CloudWatch
  };

  for (const r of leafNodes) {
    const z = _classify(r);
    zones[z].push({ ...r, nodeType: 'resource' });
  }
  for (const s of stubs) {
    const z = _classifyStub(s);
    zones[z].push({ ...s, nodeType: 'module' });
  }
  // Data sources → side
  for (const d of dataSources) {
    zones.side.push({ ...d, nodeType: 'data' });
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

  // ── Step 3: layout external row ──────────────────────────────────
  const extItems = zones.external;
  let extH = 0;
  let extBoxInfo = null;
  if (extItems.length) {
    // Force all external items into one row (or up to 8 cols)
    const cols = Math.min(extItems.length, 8);
    const rows = Math.ceil(extItems.length / cols);
    const innerW = cols * L.NODE_W + (cols - 1) * L.NODE_GAP_X;
    const innerH = rows * L.NODE_H + (rows - 1) * L.NODE_GAP_Y;
    extBoxInfo = { cols, rows, innerW, innerH };
    extH = L.EXTERNAL_HEADER + L.EXTERNAL_PAD * 2 + innerH;
  }

  // ── Step 4: layout side panel ─────────────────────────────────────
  const sideItems = zones.side;
  let sideW = 0;
  let sideH = 0;
  if (sideItems.length) {
    sideW = L.NODE_W + L.SIDE_PAD * 2;
    sideH = sideItems.length * L.NODE_H + (sideItems.length - 1) * L.NODE_GAP_Y + L.SIDE_PAD * 2 + 26;
  }

  // ── Step 5: absolute positions ────────────────────────────────────
  const canvasX = L.CANVAS_PAD;
  const canvasY = L.CANVAS_PAD;

  // External row
  const extX = canvasX;
  const extY = canvasY;
  const extContainerW = Math.max(vpcW, extBoxInfo ? extBoxInfo.innerW + L.EXTERNAL_PAD * 2 : 0);

  // VPC
  const vpcX = canvasX;
  const vpcY = canvasY + (extH > 0 ? extH + L.ZONE_GAP : 0);

  // Side panel
  const sideX = vpcX + vpcW + L.SIDE_GAP;
  const sideY = vpcY;

  // Total canvas
  const totalW = sideW > 0 ? sideX + sideW + L.CANVAS_PAD : vpcX + vpcW + L.CANVAS_PAD;
  const totalH = vpcY + vpcH + L.CANVAS_PAD;

  // ── Step 6: build node positions ──────────────────────────────────
  const allNodes = [];
  const nodeMap = {};

  // External nodes
  if (extItems.length && extBoxInfo) {
    const { cols } = extBoxInfo;
    const totalGridW = extBoxInfo.cols * L.NODE_W + (extBoxInfo.cols - 1) * L.NODE_GAP_X;
    const offsetX = extX + (extContainerW - totalGridW) / 2;
    extItems.forEach((item, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      item.x = offsetX + col * (L.NODE_W + L.NODE_GAP_X);
      item.y = extY + L.EXTERNAL_HEADER + L.EXTERNAL_PAD + row * (L.NODE_H + L.NODE_GAP_Y);
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
      item.y = sideY + 26 + L.SIDE_PAD + i * (L.NODE_H + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = L.NODE_H;
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // ── Step 7: build container list for rendering ─────────────────────
  const containers = [];

  // External
  if (extItems.length) {
    containers.push({
      id: 'zone-external',
      zone: 'external',
      x: extX, y: extY,
      width: extContainerW,
      height: extH,
      label: 'External Services',
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

  // ── Step 8: module groups ──────────────────────────────────────────
  const moduleGroups = _computeModuleGroups(allNodes);

  return { nodes: allNodes, containers, moduleGroups, nodeMap, width: totalW, height: totalH };
}


// ── Helpers ──────────────────────────────────────────────────────────

function _classify(r) {
  const t = r.type;
  // Boundary resources
  if (t === 'aws_internet_gateway') return 'boundary';
  // External
  if (['cdn', 'cicd'].includes(r.category)) return 'external';
  if (['aws_wafv2_web_acl', 'aws_wafv2_web_acl_association'].includes(t)) return 'external';
  if (t === 'aws_acm_certificate' || t === 'aws_acm_certificate_validation') return 'external';
  // S3 that's likely a website (external), otherwise storage
  if (t === 'aws_s3_bucket' && !r.from_module) return 'external';
  if (r.category === 'storage') return 'database'; // EFS, EBS near DB
  // Side: IAM, monitoring, encryption
  if (['iam', 'monitoring'].includes(r.category)) return 'side';
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
  return r.zone || 'private';
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
  return edges.map(edge => {
    const from = nodeMap[edge.from];
    const to = nodeMap[edge.to];
    if (!from || !to) return null;

    const fcx = from.x + from.width / 2;
    const fcy = from.y + from.height / 2;
    const tcx = to.x + to.width / 2;
    const tcy = to.y + to.height / 2;

    const dx = tcx - fcx, dy = tcy - fcy;
    let x1, y1, x2, y2;

    if (Math.abs(dy) >= Math.abs(dx)) {
      if (dy > 0) { x1 = fcx; y1 = from.y + from.height; x2 = tcx; y2 = to.y; }
      else         { x1 = fcx; y1 = from.y;               x2 = tcx; y2 = to.y + to.height; }
    } else {
      if (dx > 0) { x1 = from.x + from.width; y1 = fcy; x2 = to.x;               y2 = tcy; }
      else        { x1 = from.x;              y1 = fcy; x2 = to.x + to.width; y2 = tcy; }
    }

    const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    const path = Math.abs(dy) >= Math.abs(dx)
      ? `M${x1},${y1} C${x1},${my} ${x2},${my} ${x2},${y2}`
      : `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`;

    return { ...edge, path, x1, y1, x2, y2 };
  }).filter(Boolean);
}
