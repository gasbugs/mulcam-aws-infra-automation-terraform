/**
 * AWS Architecture Icons - Inline SVG registry
 * Simplified iconic representations for each AWS service.
 */
const AWS_ICONS = {
  // ===== Networking =====
  vpc: {
    color: '#8C4FFF',
    path: `<rect x="4" y="4" width="40" height="40" rx="4" fill="#8C4FFF" opacity="0.1"/>
      <path d="M24 8v6m0 20v6m-12-20H6m36 0h-6" stroke="#8C4FFF" stroke-width="2"/>
      <circle cx="24" cy="24" r="8" fill="none" stroke="#8C4FFF" stroke-width="2.5"/>
      <circle cx="24" cy="24" r="3" fill="#8C4FFF"/>`,
  },
  subnet: {
    color: '#8C4FFF',
    path: `<rect x="6" y="6" width="36" height="36" rx="3" fill="#8C4FFF" opacity="0.08" stroke="#8C4FFF" stroke-width="1.5" stroke-dasharray="4 2"/>
      <path d="M16 20h16M16 28h16" stroke="#8C4FFF" stroke-width="2"/>`,
  },
  igw: {
    color: '#8C4FFF',
    path: `<circle cx="24" cy="24" r="16" fill="#8C4FFF" opacity="0.1"/>
      <path d="M16 24h16M24 16v16" stroke="#8C4FFF" stroke-width="2.5"/>
      <circle cx="24" cy="24" r="6" fill="none" stroke="#8C4FFF" stroke-width="2"/>`,
  },
  nat: {
    color: '#8C4FFF',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#8C4FFF" opacity="0.1"/>
      <path d="M18 30l6-12 6 12" fill="none" stroke="#8C4FFF" stroke-width="2.5"/>
      <path d="M14 18h20" stroke="#8C4FFF" stroke-width="2"/>`,
  },
  route_table: {
    color: '#8C4FFF',
    path: `<rect x="8" y="10" width="32" height="28" rx="3" fill="#8C4FFF" opacity="0.1" stroke="#8C4FFF" stroke-width="1.5"/>
      <path d="M14 18h20M14 24h20M14 30h20" stroke="#8C4FFF" stroke-width="1.5"/>`,
  },
  eip: {
    color: '#8C4FFF',
    path: `<circle cx="24" cy="24" r="14" fill="#8C4FFF" opacity="0.15"/>
      <text x="24" y="29" text-anchor="middle" fill="#8C4FFF" font-size="16" font-weight="bold">IP</text>`,
  },

  // ===== Security =====
  security_group: {
    color: '#DD344C',
    path: `<path d="M24 6L40 14v12c0 8-6.5 13.5-16 18-9.5-4.5-16-10-16-18V14L24 6z" fill="#DD344C" opacity="0.1" stroke="#DD344C" stroke-width="2"/>
      <path d="M20 24l4 4 8-8" stroke="#DD344C" stroke-width="2.5" fill="none"/>`,
  },
  waf: {
    color: '#DD344C',
    path: `<path d="M24 6L40 14v12c0 8-6.5 13.5-16 18-9.5-4.5-16-10-16-18V14L24 6z" fill="#DD344C" opacity="0.15" stroke="#DD344C" stroke-width="2"/>
      <text x="24" y="28" text-anchor="middle" fill="#DD344C" font-size="11" font-weight="bold">WAF</text>`,
  },

  // ===== Compute =====
  ec2: {
    color: '#ED7100',
    path: `<rect x="6" y="6" width="36" height="36" rx="4" fill="#ED7100" opacity="0.12"/>
      <rect x="14" y="12" width="20" height="24" rx="2" fill="none" stroke="#ED7100" stroke-width="2"/>
      <circle cx="24" cy="20" r="3" fill="#ED7100"/>
      <path d="M18 30h12" stroke="#ED7100" stroke-width="2"/>`,
  },
  asg: {
    color: '#ED7100',
    path: `<rect x="4" y="8" width="24" height="18" rx="3" fill="#ED7100" opacity="0.1" stroke="#ED7100" stroke-width="1.5"/>
      <rect x="12" y="14" width="24" height="18" rx="3" fill="#ED7100" opacity="0.1" stroke="#ED7100" stroke-width="1.5"/>
      <rect x="20" y="20" width="24" height="18" rx="3" fill="#ED7100" opacity="0.15" stroke="#ED7100" stroke-width="1.5"/>`,
  },
  key_pair: {
    color: '#ED7100',
    path: `<circle cx="20" cy="20" r="8" fill="none" stroke="#ED7100" stroke-width="2"/>
      <path d="M26 26l12 12M32 32l4-4M34 36l4-4" stroke="#ED7100" stroke-width="2"/>`,
  },

  // ===== Load Balancing =====
  alb: {
    color: '#8C4FFF',
    path: `<circle cx="24" cy="24" r="18" fill="#8C4FFF" opacity="0.1"/>
      <path d="M12 24h8m8 0h8" stroke="#8C4FFF" stroke-width="2"/>
      <circle cx="24" cy="24" r="5" fill="#8C4FFF"/>
      <circle cx="24" cy="14" r="3" fill="#8C4FFF" opacity="0.5"/>
      <circle cx="24" cy="34" r="3" fill="#8C4FFF" opacity="0.5"/>`,
  },

  // ===== Database =====
  rds: {
    color: '#3B48CC',
    path: `<ellipse cx="24" cy="14" rx="16" ry="6" fill="#3B48CC" opacity="0.15" stroke="#3B48CC" stroke-width="1.5"/>
      <path d="M8 14v20c0 3.3 7.2 6 16 6s16-2.7 16-6V14" fill="none" stroke="#3B48CC" stroke-width="1.5"/>
      <path d="M8 24c0 3.3 7.2 6 16 6s16-2.7 16-6" fill="none" stroke="#3B48CC" stroke-width="1" opacity="0.5"/>`,
  },
  aurora: {
    color: '#3B48CC',
    path: `<ellipse cx="24" cy="14" rx="16" ry="6" fill="#3B48CC" opacity="0.2" stroke="#3B48CC" stroke-width="2"/>
      <path d="M8 14v20c0 3.3 7.2 6 16 6s16-2.7 16-6V14" fill="none" stroke="#3B48CC" stroke-width="2"/>
      <circle cx="24" cy="26" r="5" fill="#3B48CC" opacity="0.3"/>`,
  },
  dynamodb: {
    color: '#3B48CC',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#3B48CC" opacity="0.1"/>
      <path d="M14 16h20M14 24h20M14 32h20" stroke="#3B48CC" stroke-width="2"/>
      <path d="M20 12v28M28 12v28" stroke="#3B48CC" stroke-width="1" opacity="0.3"/>`,
  },
  elasticache: {
    color: '#3B48CC',
    path: `<rect x="6" y="6" width="36" height="36" rx="4" fill="#3B48CC" opacity="0.1"/>
      <path d="M16 18l8 6-8 6" fill="none" stroke="#3B48CC" stroke-width="2.5"/>
      <path d="M30 18v12" stroke="#3B48CC" stroke-width="2.5"/>`,
  },

  // ===== Storage =====
  s3: {
    color: '#3F8624',
    path: `<path d="M24 6L42 16v16L24 42 6 32V16L24 6z" fill="#3F8624" opacity="0.12" stroke="#3F8624" stroke-width="1.5"/>
      <text x="24" y="28" text-anchor="middle" fill="#3F8624" font-size="13" font-weight="bold">S3</text>`,
  },
  efs: {
    color: '#3F8624',
    path: `<rect x="6" y="12" width="36" height="24" rx="3" fill="#3F8624" opacity="0.1" stroke="#3F8624" stroke-width="1.5"/>
      <path d="M14 20h20M14 28h14" stroke="#3F8624" stroke-width="2"/>`,
  },
  ebs: {
    color: '#3F8624',
    path: `<rect x="10" y="6" width="28" height="36" rx="3" fill="#3F8624" opacity="0.12" stroke="#3F8624" stroke-width="1.5"/>
      <path d="M18 16h12M18 24h12M18 32h8" stroke="#3F8624" stroke-width="1.5"/>`,
  },
  backup: {
    color: '#3F8624',
    path: `<rect x="8" y="10" width="32" height="28" rx="3" fill="#3F8624" opacity="0.1" stroke="#3F8624" stroke-width="1.5"/>
      <path d="M24 18v8l5 3" fill="none" stroke="#3F8624" stroke-width="2"/>
      <circle cx="24" cy="24" r="8" fill="none" stroke="#3F8624" stroke-width="1.5"/>`,
  },

  // ===== CDN & DNS =====
  cloudfront: {
    color: '#8C4FFF',
    path: `<circle cx="24" cy="24" r="16" fill="#8C4FFF" opacity="0.1"/>
      <circle cx="24" cy="24" r="10" fill="none" stroke="#8C4FFF" stroke-width="1.5"/>
      <path d="M14 24h20M24 14v20" stroke="#8C4FFF" stroke-width="1" opacity="0.5"/>
      <circle cx="24" cy="24" r="4" fill="#8C4FFF"/>`,
  },
  route53: {
    color: '#8C4FFF',
    path: `<circle cx="24" cy="24" r="16" fill="#8C4FFF" opacity="0.1" stroke="#8C4FFF" stroke-width="1.5"/>
      <text x="24" y="28" text-anchor="middle" fill="#8C4FFF" font-size="11" font-weight="bold">R53</text>`,
  },
  acm: {
    color: '#DD344C',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#DD344C" opacity="0.1"/>
      <path d="M24 14v6m0 4v2" stroke="#DD344C" stroke-width="2"/>
      <rect x="16" y="22" width="16" height="12" rx="2" fill="none" stroke="#DD344C" stroke-width="2"/>`,
  },

  // ===== Serverless =====
  lambda_fn: {
    color: '#ED7100',
    path: `<rect x="6" y="6" width="36" height="36" rx="4" fill="#ED7100" opacity="0.12"/>
      <text x="24" y="30" text-anchor="middle" fill="#ED7100" font-size="20" font-weight="bold">\u03BB</text>`,
  },
  api_gw: {
    color: '#ED7100',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#ED7100" opacity="0.1" stroke="#ED7100" stroke-width="1.5"/>
      <path d="M16 18h6l4 6-4 6h-6" fill="none" stroke="#ED7100" stroke-width="2"/>
      <path d="M32 18h-6l-4 6 4 6h6" fill="none" stroke="#ED7100" stroke-width="2"/>`,
  },
  sqs: {
    color: '#ED7100',
    path: `<rect x="6" y="12" width="36" height="24" rx="4" fill="#ED7100" opacity="0.1" stroke="#ED7100" stroke-width="1.5"/>
      <path d="M14 20h20M14 28h14" stroke="#ED7100" stroke-width="2"/>
      <path d="M30 20l4 4-4 4" fill="none" stroke="#ED7100" stroke-width="2"/>`,
  },
  sns: {
    color: '#DD344C',
    path: `<circle cx="24" cy="24" r="16" fill="#DD344C" opacity="0.1"/>
      <path d="M16 20h16v10H16z" fill="none" stroke="#DD344C" stroke-width="1.5"/>
      <path d="M16 20l8 6 8-6" fill="none" stroke="#DD344C" stroke-width="1.5"/>`,
  },

  // ===== IAM =====
  iam_role: {
    color: '#DD344C',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#DD344C" opacity="0.1"/>
      <circle cx="24" cy="18" r="5" fill="none" stroke="#DD344C" stroke-width="2"/>
      <path d="M14 34c0-5.5 4.5-10 10-10s10 4.5 10 10" fill="none" stroke="#DD344C" stroke-width="2"/>`,
  },
  iam_policy: {
    color: '#DD344C',
    path: `<rect x="10" y="6" width="28" height="36" rx="3" fill="#DD344C" opacity="0.1" stroke="#DD344C" stroke-width="1.5"/>
      <path d="M16 16h16M16 22h12M16 28h16M16 34h8" stroke="#DD344C" stroke-width="1.5"/>`,
  },
  iam_user: {
    color: '#DD344C',
    path: `<circle cx="24" cy="16" r="7" fill="#DD344C" opacity="0.15" stroke="#DD344C" stroke-width="1.5"/>
      <path d="M12 38c0-6.6 5.4-12 12-12s12 5.4 12 38" fill="none" stroke="#DD344C" stroke-width="1.5"/>`,
  },
  kms: {
    color: '#DD344C',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#DD344C" opacity="0.1"/>
      <circle cx="20" cy="24" r="6" fill="none" stroke="#DD344C" stroke-width="2"/>
      <path d="M26 24h12M34 20v8M30 22v4" stroke="#DD344C" stroke-width="2"/>`,
  },
  secrets_manager: {
    color: '#DD344C',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#DD344C" opacity="0.1"/>
      <rect x="14" y="20" width="20" height="14" rx="2" fill="none" stroke="#DD344C" stroke-width="2"/>
      <circle cx="24" cy="16" r="6" fill="none" stroke="#DD344C" stroke-width="2"/>
      <circle cx="24" cy="27" r="2" fill="#DD344C"/>`,
  },

  // ===== Containers =====
  ecs: {
    color: '#ED7100',
    path: `<rect x="6" y="6" width="36" height="36" rx="4" fill="#ED7100" opacity="0.12"/>
      <circle cx="18" cy="18" r="4" fill="none" stroke="#ED7100" stroke-width="2"/>
      <circle cx="30" cy="18" r="4" fill="none" stroke="#ED7100" stroke-width="2"/>
      <circle cx="24" cy="30" r="4" fill="none" stroke="#ED7100" stroke-width="2"/>
      <path d="M20 21l2 5M28 21l-2 5" stroke="#ED7100" stroke-width="1.5"/>`,
  },
  ecr: {
    color: '#ED7100',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#ED7100" opacity="0.1" stroke="#ED7100" stroke-width="1.5"/>
      <rect x="14" y="16" width="20" height="16" rx="2" fill="none" stroke="#ED7100" stroke-width="2"/>
      <path d="M22 20v8M26 20v8M18 24h12" stroke="#ED7100" stroke-width="1.5"/>`,
  },
  eks: {
    color: '#ED7100',
    path: `<rect x="6" y="6" width="36" height="36" rx="4" fill="#ED7100" opacity="0.12"/>
      <circle cx="24" cy="24" r="10" fill="none" stroke="#ED7100" stroke-width="2"/>
      <path d="M24 14v4M24 30v4M14 24h4M30 24h4M17 17l3 3M28 28l3 3M17 31l3-3M28 20l3-3" stroke="#ED7100" stroke-width="1.5"/>`,
  },
  fargate: {
    color: '#ED7100',
    path: `<rect x="6" y="6" width="36" height="36" rx="4" fill="#ED7100" opacity="0.1"/>
      <path d="M16 16h16v16H16z" fill="none" stroke="#ED7100" stroke-width="2"/>
      <path d="M12 12h4v4M32 12h4v4M12 32h4v4M32 32h4v4" stroke="#ED7100" stroke-width="1.5"/>`,
  },

  // ===== CI/CD =====
  codebuild: {
    color: '#3B48CC',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#3B48CC" opacity="0.1"/>
      <path d="M16 20l4 4-4 4M26 20h8M26 28h6" stroke="#3B48CC" stroke-width="2"/>`,
  },
  codepipeline: {
    color: '#3B48CC',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#3B48CC" opacity="0.1"/>
      <circle cx="16" cy="24" r="3" fill="#3B48CC"/>
      <circle cx="24" cy="24" r="3" fill="#3B48CC" opacity="0.6"/>
      <circle cx="32" cy="24" r="3" fill="#3B48CC" opacity="0.3"/>
      <path d="M19 24h2M27 24h2" stroke="#3B48CC" stroke-width="2"/>`,
  },
  codecommit: {
    color: '#3B48CC',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#3B48CC" opacity="0.1"/>
      <circle cx="20" cy="20" r="3" fill="#3B48CC"/>
      <circle cx="28" cy="20" r="3" fill="#3B48CC"/>
      <circle cx="24" cy="30" r="3" fill="#3B48CC"/>
      <path d="M21 23l2 4M27 23l-2 4" stroke="#3B48CC" stroke-width="1.5"/>`,
  },

  // ===== Monitoring =====
  cloudwatch: {
    color: '#E7157B',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#E7157B" opacity="0.1"/>
      <path d="M14 28l5-8 4 4 6-10 5 6" fill="none" stroke="#E7157B" stroke-width="2"/>`,
  },

  // ===== Module / Generic =====
  module: {
    color: '#7B42BC',
    path: `<rect x="4" y="4" width="40" height="40" rx="6" fill="#7B42BC" opacity="0.1" stroke="#7B42BC" stroke-width="2"/>
      <path d="M12 16l12 8-12 8V16z" fill="#7B42BC" opacity="0.4"/>
      <path d="M28 16v16" stroke="#7B42BC" stroke-width="3"/>`,
  },
  generic: {
    color: '#888888',
    path: `<rect x="8" y="8" width="32" height="32" rx="4" fill="#888" opacity="0.1" stroke="#888" stroke-width="1.5"/>
      <text x="24" y="28" text-anchor="middle" fill="#888" font-size="11" font-weight="bold">AWS</text>`,
  },
};

/**
 * Render an AWS icon SVG inside a given container element.
 */
function renderIcon(container, iconKey, size = 48) {
  const icon = AWS_ICONS[iconKey] || AWS_ICONS.generic;
  const scale = size / 48;
  const g = container.append('g')
    .attr('class', 'aws-icon')
    .attr('transform', `scale(${scale})`);
  g.html(icon.path);
  return icon.color;
}

/**
 * Get icon color for a resource type.
 */
function getIconColor(iconKey) {
  const icon = AWS_ICONS[iconKey] || AWS_ICONS.generic;
  return icon.color;
}
