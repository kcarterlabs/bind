#!/usr/bin/env python3
import yaml
import sys
from datetime import datetime

yaml_file = sys.argv[1]
zone_file = sys.argv[2]

with open(yaml_file) as f:
    data = yaml.safe_load(f)

zone = data['zone']
soa = data['soa']
records = data['records']

serial = soa.get('serial', int(datetime.now().strftime("%Y%m%d%H")))

zone_content = f"""; BIND zone file generated from YAML
$TTL {soa.get('minimum', 86400)}
@ IN SOA {soa['primary_ns']} {soa['admin_email']} (
    {serial} ; serial
    {soa['refresh']}
    {soa['retry']}
    {soa['expire']}
    {soa['minimum']}
)
    NS {soa['primary_ns']}

"""

for r in records:
    ttl = r.get('ttl', soa.get('minimum', 86400))
    zone_content += f"{r['name']} {ttl} IN {r['type']} {r['value']}\n"

with open(zone_file, 'w') as f:
    f.write(zone_content)
