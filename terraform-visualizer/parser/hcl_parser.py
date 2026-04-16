"""Parse Terraform .tf files using python-hcl2."""

import os
import json
import hcl2


def _strip_quotes(s):
    """Strip surrounding quotes that python-hcl2 adds to identifiers."""
    if isinstance(s, str) and len(s) >= 2 and s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    return s


def parse_tf_directory(directory):
    """Parse all .tf files in a directory and extract resources, data, modules, variables."""
    resources = []
    data_sources = []
    modules = []
    variables = {}
    locals_map = {}
    provider_region_raw = None   # raw region string from provider "aws" block
    warnings = []

    tf_files = sorted([f for f in os.listdir(directory)
                       if f.endswith('.tf') and os.path.isfile(os.path.join(directory, f))])

    for tf_file in tf_files:
        filepath = os.path.join(directory, tf_file)
        try:
            with open(filepath, 'r') as f:
                parsed = hcl2.load(f)
        except Exception as e:
            warnings.append(f"Failed to parse {tf_file}: {str(e)}")
            continue

        # Extract resources
        for res_block in parsed.get('resource', []):
            for res_type_raw, res_map in res_block.items():
                res_type = _strip_quotes(res_type_raw)
                for res_name_raw, res_config in res_map.items():
                    res_name = _strip_quotes(res_name_raw)
                    config = res_config[0] if isinstance(res_config, list) else res_config
                    count_val = _extract_count(config)
                    for_each_val = config.get('for_each')
                    resources.append({
                        "type": res_type,
                        "name": res_name,
                        "id": f"{res_type}.{res_name}",
                        "config": config,
                        "count": count_val,
                        "for_each": for_each_val,
                        "file": tf_file,
                    })

        # Extract data sources
        for data_block in parsed.get('data', []):
            for data_type_raw, data_map in data_block.items():
                data_type = _strip_quotes(data_type_raw)
                for data_name_raw, data_config in data_map.items():
                    data_name = _strip_quotes(data_name_raw)
                    config = data_config[0] if isinstance(data_config, list) else data_config
                    data_sources.append({
                        "type": data_type,
                        "name": data_name,
                        "id": f"data.{data_type}.{data_name}",
                        "config": config,
                        "file": tf_file,
                    })

        # Extract modules
        for mod_block in parsed.get('module', []):
            for mod_name_raw, mod_config in mod_block.items():
                mod_name = _strip_quotes(mod_name_raw)
                config = mod_config[0] if isinstance(mod_config, list) else mod_config
                source = _strip_quotes(config.get('source', ''))
                modules.append({
                    "name": mod_name,
                    "id": f"module.{mod_name}",
                    "source": source,
                    "config": config,
                    "file": tf_file,
                })

        # Extract variables
        for var_block in parsed.get('variable', []):
            for var_name_raw, var_config in var_block.items():
                var_name = _strip_quotes(var_name_raw)
                config = var_config[0] if isinstance(var_config, list) else var_config
                variables[var_name] = {
                    "default": config.get('default'),
                    "type": config.get('type'),
                    "description": _strip_quotes(config.get('description', '')),
                }

        # Extract locals
        for local_block in parsed.get('locals', []):
            if isinstance(local_block, dict):
                locals_map.update(local_block)

        # Extract provider "aws" region
        if provider_region_raw is None:
            for prov_block in parsed.get('provider', []):
                aws_cfg = prov_block.get('aws')
                if aws_cfg:
                    cfg = aws_cfg[0] if isinstance(aws_cfg, list) else aws_cfg
                    raw = cfg.get('region')
                    if raw:
                        provider_region_raw = _strip_quotes(str(raw))

    # Resolve aws_region: provider value, then variable default fallback
    aws_region = _resolve_aws_region(provider_region_raw, variables, locals_map)

    return {
        "resources": resources,
        "data_sources": data_sources,
        "modules": modules,
        "variables": variables,
        "locals": locals_map,
        "warnings": warnings,
        "aws_region": aws_region,
    }


def _resolve_aws_region(provider_region_raw, variables, locals_map):
    """Resolve the AWS region from provider config, with variable default fallback."""
    import re
    if not provider_region_raw:
        # Check variables for a region-like default
        for vname, vinfo in variables.items():
            if 'region' in vname.lower():
                default = vinfo.get('default')
                if default and isinstance(default, str):
                    return _strip_quotes(default)
        return None

    # Literal region string (e.g. "us-east-1")
    if re.match(r'^[a-z]{2}-[a-z]+-\d$', provider_region_raw):
        return provider_region_raw

    # Variable reference: "${var.aws_region}" or "var.aws_region"
    m = re.search(r'var\.(\w+)', provider_region_raw)
    if m:
        var_name = m.group(1)
        vinfo = variables.get(var_name, {})
        default = vinfo.get('default')
        if default and isinstance(default, str):
            return _strip_quotes(default)
        return None

    return None


def _extract_count(config):
    """Extract count value from resource config."""
    count = config.get('count')
    if count is None:
        return None
    if isinstance(count, (int, float)):
        return int(count)
    if isinstance(count, str):
        try:
            return int(count)
        except ValueError:
            return count  # expression string
    return count
