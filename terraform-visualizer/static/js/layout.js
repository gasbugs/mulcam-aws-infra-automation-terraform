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
function computeLayout(data, showDetails = false, expandedNodeIds = new Set()) {
  const allResources = data.resources || [];
  const stubs = data.registry_modules || [];
  const dataSources = data.data_sources || [];

  // Compute which hidden resources are individually revealed via expandedNodeIds
  const revealedHiddenIds = new Set();
  if (expandedNodeIds.size > 0) {
    const hiddenSet = new Set(allResources.filter(r => r.hidden).map(r => r.id));
    for (const edge of (data.edges || [])) {
      if (expandedNodeIds.has(edge.from) && hiddenSet.has(edge.to)) revealedHiddenIds.add(edge.to);
      if (expandedNodeIds.has(edge.to) && hiddenSet.has(edge.from)) revealedHiddenIds.add(edge.from);
    }
  }

  // Primary leaf nodes: non-hidden, non-structural
  // Include hidden nodes if: global showDetails, OR individually revealed, OR in detail view
  const leafNodes = allResources.filter(r =>
    !r.structural && (!r.hidden || showDetails || revealedHiddenIds.has(r.id))
  ).map(r => r.hidden ? { ...r, isDetail: true } : r);
  const hasVPC = allResources.some(r =>
    r.type === 'aws_vpc' ||
    (r.category === 'networking' && !r.hidden)
  ) || stubs.some(m => m.source?.includes('vpc'));

  // Detect "default VPC" scenario: no VPC declared, but VPC-internal resources exist
  const vpcInternalTypes = new Set(['compute', 'database', 'container', 'loadbalancing', 'security']);
  const hasVpcInternalResources = allResources.some(r =>
    !r.hidden && vpcInternalTypes.has(r.category)
  );
  const isDefaultVPC = !hasVPC && hasVpcInternalResources;

  // Classify into zones
  const zones = {
    external: [],   // CloudFront, Route53, S3, WAF, ACM
    boundary: [],   // IGW (shown at VPC top border)
    public: [],     // ALB, NAT, EIP — public subnet resources
    private: [],    // EC2, ECS, EKS, Lambda, SQS — private subnet resources
    database: [],   // RDS, Aurora, DynamoDB, ElastiCache, EFS
    sg_orphan: [],  // Security groups not attached to any resource
    side: [],       // IAM, KMS, Secrets, CloudWatch
    cicd: [],       // CI/CD pipeline resources
    registry: [],   // ECR, AMI — artifact/image registry
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

  // Sort external zone by service family so related resources cluster together
  const _extOrder = (r) => {
    const t = r.type || '';
    if (t.startsWith('aws_cloudfront') || t.startsWith('aws_waf')) return 0;
    if (t.startsWith('aws_s3')) return 1;
    if (t.startsWith('aws_route53')) return 2;
    if (t.startsWith('aws_acm')) return 3;
    return 4;
  };
  zones.external.sort((a, b) => _extOrder(a) - _extOrder(b));

  // ── Step 1: layout each vpc-internal zone ──────────────────────────
  const vpcInternalZones = ['public', 'private', 'database', 'sg_orphan'];
  const zoneBoxes = {}; // zone → { items, innerW, innerH, cols, rows }
  let maxInnerW = 0;

  for (const zName of vpcInternalZones) {
    const items = zones[zName];
    if (!items.length) continue;
    const { cols, rows, innerW, innerH, rowH } = _gridSize(items);
    zoneBoxes[zName] = { items, cols, rows, innerW, innerH, rowH };
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
    const { cols, rows, innerW, innerH, rowH } = _gridSize(extItems);
    extGridInfo = { cols, rows, innerW, innerH, rowH };
    extPanelW = innerW + L.SIDE_PAD * 2;
    extPanelH = innerH + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER;
  }

  // ── Step 4: layout right side panel (IAM in columns, others below) ──
  const sideItems = zones.side;

  // IAM resources (user/role/policy) get a 3-column layout; others stack below
  const IAM_COL_TYPES = ['aws_iam_user', 'aws_iam_role', 'aws_iam_policy'];
  const iamColItems = [
    sideItems.filter(r => r.type === 'aws_iam_user'),
    sideItems.filter(r => r.type === 'aws_iam_role'),
    sideItems.filter(r => r.type === 'aws_iam_policy'),
  ].filter(col => col.length > 0);  // only non-empty columns
  const otherSideItems = sideItems.filter(r => !IAM_COL_TYPES.includes(r.type));

  // Sort each IAM column by name for stable ordering
  iamColItems.forEach(col => col.sort((a, b) => a.name.localeCompare(b.name)));

  const iamColCount = iamColItems.length;
  const iamRowCount = iamColCount > 0 ? Math.max(...iamColItems.map(c => c.length)) : 0;
  const iamGridW = iamColCount > 0
    ? iamColCount * L.NODE_W + (iamColCount - 1) * L.NODE_GAP_X
    : 0;
  const iamGridH = iamRowCount > 0
    ? iamRowCount * L.NODE_H + (iamRowCount - 1) * L.NODE_GAP_Y
    : 0;
  const iamPanelH = iamColCount > 0
    ? iamGridH + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER
    : 0;

  // Split other side items into 3 semantic sub-panels
  const SECRETS_TYPES = new Set([
    'aws_kms_key', 'aws_kms_alias',
    'aws_secretsmanager_secret', 'aws_secretsmanager_secret_version',
  ]);
  const MONITORING_TYPES = new Set([
    'aws_cloudwatch_log_group', 'aws_cloudwatch_metric_alarm',
    'aws_cloudwatch_dashboard', 'aws_cloudwatch_event_rule',
    'aws_cloudwatch_event_target', 'aws_cloudwatch_event_bus',
  ]);
  const secretsItems    = otherSideItems.filter(r => SECRETS_TYPES.has(r.type));
  const monitoringItems = otherSideItems.filter(r => MONITORING_TYPES.has(r.type));
  const configItems     = otherSideItems.filter(r =>
    !SECRETS_TYPES.has(r.type) && !MONITORING_TYPES.has(r.type));

  const _subPanelH = (items) => items.length
    ? items.reduce((acc, r) => acc + _nodeHeight(r) + L.NODE_GAP_Y, 0)
        - L.NODE_GAP_Y + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER
    : 0;
  const secretsPanelH    = _subPanelH(secretsItems);
  const monitoringPanelH = _subPanelH(monitoringItems);
  const configPanelH     = _subPanelH(configItems);

  const subPanelHeights = [secretsPanelH, monitoringPanelH, configPanelH].filter(h => h > 0);
  const subPanelTotalH = subPanelHeights.length
    ? subPanelHeights.reduce((a, b) => a + b, 0) + (subPanelHeights.length - 1) * L.ZONE_GAP
    : 0;
  const sideGap = iamColCount > 0 && subPanelTotalH > 0 ? L.ZONE_GAP : 0;

  let sideW = 0;
  let sideH = 0;
  if (sideItems.length) {
    sideW = Math.max(iamGridW, L.NODE_W) + L.SIDE_PAD * 2;
    sideH = iamPanelH + sideGap + subPanelTotalH;
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
      const flatItems = cicdLeafs.length ? cicdLeafs : cicdItemsAll;
      const totalItemH = flatItems.reduce((sum, r) => sum + _nodeHeight(r), 0) || L.NODE_H;
      const gapsH = Math.max(0, flatItems.length - 1) * L.NODE_GAP_Y;
      cicdW = L.NODE_W + L.SIDE_PAD * 2;
      cicdH = totalItemH + gapsH + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER;
    }
  }

  // ── Step 4c: Registry panel (ECR, AMI — artifact/image store) ────
  const registryItems = zones.registry;
  let registryW = 0, registryH = 0;
  let registryGridInfo = null;
  if (registryItems.length) {
    const { cols, rows, innerW, innerH, rowH } = _gridSize(registryItems);
    registryGridInfo = { cols, rows, innerW, innerH, rowH };
    registryW = innerW + L.SIDE_PAD * 2;
    registryH = innerH + L.SIDE_PAD * 2 + L.EXTERNAL_HEADER;
  }

  // ── Step 5: absolute positions ────────────────────────────────────
  const canvasX = L.CANVAS_PAD;
  const canvasY = L.CANVAS_PAD;

  // External left panel
  const extX = canvasX;
  const extY = canvasY;

  // CI/CD panel — below External on the left column
  const cicdX = extX;
  const cicdY = extY + extPanelH + (extPanelH > 0 && cicdH > 0 ? L.SIDE_GAP : 0);

  // Registry panel — below CI/CD (or External if no CI/CD) on the left column
  const registryX = extX;
  const _leftStackBottom = Math.max(extY + extPanelH, cicdY + cicdH);
  const registryY = _leftStackBottom + (_leftStackBottom > canvasY && registryH > 0 ? L.SIDE_GAP : 0);

  // VPC — offset right of left column (external + CI/CD + registry stacked)
  const leftColW = Math.max(extPanelW, cicdW, registryW);
  const vpcX = canvasX + (leftColW > 0 ? leftColW + L.SIDE_GAP : 0);
  const vpcY = canvasY;

  // Right side panel (IAM & Config)
  const sideX = vpcX + vpcW + L.SIDE_GAP;
  const sideY = vpcY;

  // Total canvas
  const leftColBottom = Math.max(extY + extPanelH, cicdY + cicdH, registryY + registryH);
  const rightBottom = sideY + sideH;
  const totalH = Math.max(vpcY + vpcH, leftColBottom, rightBottom) + L.CANVAS_PAD;
  const totalW = sideW > 0 ? sideX + sideW + L.CANVAS_PAD : vpcX + vpcW + L.CANVAS_PAD;

  // ── Step 6: build node positions ──────────────────────────────────
  const allNodes = [];
  const nodeMap = {};

  // External nodes — grid layout (auto columns, sorted by service family)
  if (extItems.length && extGridInfo) {
    const { cols, rowH: extRowH } = extGridInfo;
    const nodeStartX = extX + L.SIDE_PAD;
    const nodeStartY = extY + L.EXTERNAL_HEADER + L.SIDE_PAD;
    extItems.forEach((item, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      item.x = nodeStartX + col * (L.NODE_W + L.NODE_GAP_X);
      item.y = nodeStartY + row * ((extRowH || L.NODE_H) + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = _nodeHeight(item);
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // Boundary (IGW) — centered at VPC top
  if (boundaryItems.length) {
    const { cols, innerW, rowH: bRowH } = _gridSize(boundaryItems);
    const bOffsetX = vpcX + L.VPC_PAD_X + (zoneW - innerW) / 2;
    const bOffsetY = vpcY + L.VPC_HEADER + L.VPC_PAD_Y / 2;
    boundaryItems.forEach((item, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      item.x = bOffsetX + col * (L.NODE_W + L.NODE_GAP_X);
      item.y = bOffsetY + row * ((bRowH || L.NODE_H) + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = _nodeHeight(item);
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

    const rowH = box.rowH || L.NODE_H;
    box.items.forEach((item, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      item.x = nodeStartX + col * (L.NODE_W + L.NODE_GAP_X);
      item.y = nodeStartY + row * (rowH + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = _nodeHeight(item);
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // Side nodes — IAM in 3 columns (user|role|policy), others stacked below
  if (sideItems.length) {
    // IAM columns: users → col 0, roles → col 1, policies → col 2
    if (iamColCount > 0) {
      iamColItems.forEach((col, ci) => {
        col.forEach((item, ri) => {
          item.x = sideX + L.SIDE_PAD + ci * (L.NODE_W + L.NODE_GAP_X);
          item.y = sideY + L.EXTERNAL_HEADER + L.SIDE_PAD + ri * (L.NODE_H + L.NODE_GAP_Y);
          item.width = L.NODE_W;
          item.height = _nodeHeight(item);
          allNodes.push(item);
          nodeMap[item.id] = item;
        });
      });
    }
    // Sub-panels: Secrets → Monitoring → Config, stacked below IAM
    let subPanelTopY = sideY + iamPanelH + sideGap;
    for (const [items, panelH] of [
      [secretsItems, secretsPanelH],
      [monitoringItems, monitoringPanelH],
      [configItems, configPanelH],
    ]) {
      if (!items.length) continue;
      let nodeY = subPanelTopY + L.EXTERNAL_HEADER + L.SIDE_PAD;
      items.forEach((item) => {
        item.x = sideX + L.SIDE_PAD;
        item.y = nodeY;
        item.width = L.NODE_W;
        item.height = _nodeHeight(item);
        nodeY += item.height + L.NODE_GAP_Y;
        allNodes.push(item);
        nodeMap[item.id] = item;
      });
      subPanelTopY += panelH + L.ZONE_GAP;
    }
  }

  // Registry nodes (ECR, AMI)
  if (registryItems.length && registryGridInfo) {
    const { cols, rowH: regRowH } = registryGridInfo;
    const nodeStartX = registryX + L.SIDE_PAD;
    const nodeStartY = registryY + L.EXTERNAL_HEADER + L.SIDE_PAD;
    registryItems.forEach((item, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      item.x = nodeStartX + col * (L.NODE_W + L.NODE_GAP_X);
      item.y = nodeStartY + row * ((regRowH || L.NODE_H) + L.NODE_GAP_Y);
      item.width = L.NODE_W;
      item.height = _nodeHeight(item);
      allNodes.push(item);
      nodeMap[item.id] = item;
    });
  }

  // CI/CD nodes
  if (cicdItemsAll.length) {
    if (cicdPipeline && cicdChildren.length > 0) {
      // Children go inside the CodePipeline container box
      const { cols, rowH: cicdRowH } = _gridSize(cicdChildren);
      const pipeAbsX = cicdX + L.SIDE_PAD;
      const pipeAbsY = cicdY + L.EXTERNAL_HEADER + L.SIDE_PAD;
      const childStartX = pipeAbsX + L.ZONE_PAD_X;
      const childStartY = pipeAbsY + L.ZONE_HEADER + L.ZONE_PAD_Y;

      cicdChildren.forEach((item, i) => {
        const col = i % cols;
        const row = Math.floor(i / cols);
        item.x = childStartX + col * (L.NODE_W + L.NODE_GAP_X);
        item.y = childStartY + row * ((cicdRowH || L.NODE_H) + L.NODE_GAP_Y);
        item.width = L.NODE_W;
        item.height = _nodeHeight(item);
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
      let flatY = cicdY + L.EXTERNAL_HEADER + L.SIDE_PAD;
      items.forEach((item) => {
        item.x = nodeX;
        item.y = flatY;
        item.width = L.NODE_W;
        item.height = _nodeHeight(item);
        flatY += item.height + L.NODE_GAP_Y;
        allNodes.push(item);
        nodeMap[item.id] = item;
      });
    }
  }

  // ── Step 7: build container list for rendering ─────────────────────
  const containers = [];

  // External left panel — label based on content
  if (extItems.length) {
    const hasCloudFront = extItems.some(r => (r.type || '').startsWith('aws_cloudfront'));
    const hasRoute53 = extItems.some(r => (r.type || '').startsWith('aws_route53'));
    const hasS3 = extItems.some(r => (r.type || '').startsWith('aws_s3'));
    const extLabel = hasCloudFront && hasRoute53 ? 'Edge & DNS'
      : hasCloudFront ? 'Edge / CDN'
      : hasRoute53 ? 'DNS & Certificates'
      : hasS3 ? 'Global Storage'
      : 'Global Services';
    containers.push({
      id: 'zone-external',
      zone: 'external',
      x: extX, y: extY,
      width: extPanelW,
      height: extPanelH,
      label: extLabel,
    });
  }

  // VPC
  if (hasVPC || isDefaultVPC) {
    containers.push({
      id: 'vpc-container',
      zone: 'vpc',
      x: vpcX, y: vpcY,
      width: vpcW, height: vpcH,
      label: isDefaultVPC ? 'VPC (Default)' : 'VPC',
      isVPC: true,
      isDefaultVPC,
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

  // Side panel — two separate boxes: IAM (3-col) and Config & Monitoring
  if (iamColCount > 0) {
    containers.push({
      id: 'zone-iam',
      zone: 'side',
      x: sideX, y: sideY,
      width: sideW, height: iamPanelH,
      label: 'IAM',
    });
  }
  // Sub-panels: Secrets & KMS / Monitoring / Config
  {
    let subY = sideY + iamPanelH + sideGap;
    for (const [items, panelH, id, label] of [
      [secretsItems,    secretsPanelH,    'zone-secrets',    'Secrets & KMS'],
      [monitoringItems, monitoringPanelH, 'zone-monitoring', 'Monitoring'],
      [configItems,     configPanelH,     'zone-config',     'Config'],
    ]) {
      if (!items.length) continue;
      containers.push({ id, zone: 'side', x: sideX, y: subY, width: sideW, height: panelH, label });
      subY += panelH + L.ZONE_GAP;
    }
  }

  // Registry panel (ECR, AMI)
  if (registryItems.length) {
    containers.push({
      id: 'zone-registry',
      zone: 'registry',
      x: registryX, y: registryY,
      width: registryW, height: registryH,
      label: 'Image Registry',
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
  const moduleGroups = _computeModuleGroups(allNodes, containers);

  return { nodes: allNodes, containers, moduleGroups, nodeMap, width: totalW, height: totalH };
}


// ── Helpers ──────────────────────────────────────────────────────────

const VALID_ZONES = new Set(['external', 'boundary', 'public', 'private', 'database', 'sg_orphan', 'side', 'cicd', 'registry']);

function _classify(r) {
  const t = r.type;
  // Orphan security groups (not attached to any resource) get their own section
  if (r.sg_orphan) return 'sg_orphan';
  // Boundary resources
  if (t === 'aws_internet_gateway') return 'boundary';
  // External: CDN, DNS, WAF, ACM (user-facing front door)
  if (r.category === 'cdn') return 'external';
  if (['aws_wafv2_web_acl', 'aws_wafv2_web_acl_association'].includes(t)) return 'external';
  if (t === 'aws_acm_certificate' || t === 'aws_acm_certificate_validation') return 'external';
  // S3: context-aware placement based on actual usage role
  if (t === 'aws_s3_bucket') {
    const role = r.s3_role;
    if (role === 'artifact') return 'cicd';       // CI/CD 아티팩트 → 파이프라인 옆
    if (role === 'lambda' || role === 'api') return 'serverless'; // Lambda/API 코드 → serverless 존
    if (role === 'log') return 'side';             // 로그 저장소 → 모니터링 옆
    return 'external';                             // cdn/general → 외부 서비스 패널
  }
  // VPC-mounted storage (EFS, EBS, Backup) stays near the database zone
  if (['aws_efs_file_system', 'aws_ebs_volume', 'aws_volume_attachment',
       'aws_backup_plan', 'aws_backup_vault', 'aws_backup_selection'].includes(t)) return 'database';
  if (r.category === 'storage') return 'external'; // other storage → external
  // Side: IAM, monitoring, encryption, CI/CD (support services — not traffic path)
  if (['iam', 'monitoring', 'security'].includes(r.category)) return 'side';
  if (r.category === 'cicd') return 'cicd';
  // Registry: ECR (container image store) and AMI (machine image store)
  if (['aws_ecr_repository', 'aws_ecr_lifecycle_policy', 'aws_ecr_pull_through_cache_rule'].includes(t)) return 'registry';
  if (['aws_ami', 'aws_ami_from_instance'].includes(t)) return 'registry';
  if (['aws_kms_key', 'aws_kms_alias', 'aws_secretsmanager_secret',
       'aws_secretsmanager_secret_version'].includes(t)) return 'side';
  // Public: LB, NAT
  if (r.category === 'loadbalancing') return 'public';
  if (t === 'aws_nat_gateway' || t === 'aws_eip') return 'public';
  // Database
  if (r.category === 'database') return 'database';
  // VPC-internal resources: subnet_placement drives public vs private
  if (['compute', 'container', 'serverless', 'networking'].includes(r.category)) {
    if (r.subnet_placement === 'public') return 'public';
    return 'private';
  }
  // Fallback
  return VALID_ZONES.has(r.zone) ? r.zone : 'private';
}

function _classifyStub(m) {
  const s = (m.source || '').toLowerCase();
  if (s.includes('vpc')) return 'boundary';
  if (s.includes('eks') || s.includes('ecs') || s.includes('lambda')) return 'private';
  if (s.includes('iam')) return 'side';
  if (s.includes('s3')) return 'external';
  return 'private';
}

/** Compute dynamic node height: extends base height to fit attached SG badges.
 *  SG section starts at NODE_H (fixed), then:
 *    separator (2px), label (≈10px gap), first badge starts at +12, each badge=22px, badge height=18px.
 *  Last badge end = NODE_H + 12 + (n-1)*22 + 18 = NODE_H + n*22 + 8.
 *  Add 6px bottom padding → total = NODE_H + n*22 + 14.
 */
function _nodeHeight(r) {
  const sgCount  = (r.attached_sgs || []).length;
  const ebsCount = (r.attached_ebs || []).length;
  const badgeCount = sgCount + ebsCount;
  if (!badgeCount) return L.NODE_H;
  const ROW_H = 22;
  const BOTTOM = 14;
  return L.NODE_H + badgeCount * ROW_H + BOTTOM;
}

function _gridSize(items) {
  const n = items.length;
  const cols = Math.min(n, Math.max(1, Math.ceil(Math.sqrt(n * 1.8))));
  const rows = Math.ceil(n / cols);
  // Use the tallest node height in the set as the uniform row height
  const rowH = items.length ? Math.max(...items.map(r => _nodeHeight(r))) : L.NODE_H;
  const innerW = cols * L.NODE_W + (cols - 1) * L.NODE_GAP_X;
  const innerH = rows * rowH + (rows - 1) * L.NODE_GAP_Y;
  return { cols, rows, innerW, innerH, rowH };
}

function _zoneLabel(zone) {
  return {
    external: 'External Services',
    public: 'Public Subnet',
    private: 'Private Subnet',
    database: 'Database / Storage',
    sg_orphan: 'Unattached Security Groups',
    side: 'IAM & Config',
    cicd: 'CI/CD Pipeline',
    registry: 'Image Registry',
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

function _computeModuleGroups(nodes, containers) {
  // Assign each node to the container that contains it
  function _nodeContainer(n) {
    for (const c of (containers || [])) {
      if (n.x >= c.x && n.y >= c.y &&
          n.x + n.width  <= c.x + c.width + 4 &&
          n.y + n.height <= c.y + c.height + 4) {
        return c.id;
      }
    }
    return '__canvas__';
  }

  const groups = {};
  for (const n of nodes) {
    if (!n.from_module) continue;
    const key = n.from_module;
    if (!groups[key]) groups[key] = { name: key, nodes: [] };
    groups[key].nodes.push(n);
  }

  const result = [];
  for (const g of Object.values(groups)) {
    // Split by container — avoid cross-panel mega-boxes
    const byContainer = {};
    for (const n of g.nodes) {
      const cid = _nodeContainer(n);
      if (!byContainer[cid]) byContainer[cid] = [];
      byContainer[cid].push(n);
    }
    for (const cnodes of Object.values(byContainer)) {
      // Skip single-node groups — a lone node needs no module outline, and it
      // prevents adjacent module boxes from touching when nodes are stacked.
      if (cnodes.length < 2) continue;
      const PAD = 8;
      const xs = cnodes.map(n => n.x);
      const ys = cnodes.map(n => n.y);
      const x2 = cnodes.map(n => n.x + n.width);
      const y2 = cnodes.map(n => n.y + n.height);
      const bx = Math.min(...xs) - PAD;
      const by = Math.min(...ys) - PAD - 14; // room for label
      const bw = Math.max(...x2) - Math.min(...xs) + PAD * 2;
      const bh = Math.max(...y2) - Math.min(...ys) + PAD * 2 + 14;
      const color = MODULE_COLORS[_moduleColorIndex(g.name)];
      result.push({ name: g.name, x: bx, y: by, width: bw, height: bh, color });
    }
  }
  return result;
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
