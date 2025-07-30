uuid=$(uuidgen)
setupkey="nbtk-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)"
created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sqlite3 /var/lib/docker/volumes/netbird-syncthing_netbird-mgmt/_data/store.db <<EOF
INSERT INTO setup_keys (
  id, account_id, key, key_secret, name, type,
  created_at, expires_at, updated_at,
  revoked, used_times, last_used,
  auto_groups, usage_limit, ephemeral, allow_extra_dns_labels
)
VALUES (
  '$uuid',
  (SELECT id FROM accounts LIMIT 1),
  '$setupkey',
  '',
  'manual-cli',
  'reusable',
  '$created',
  NULL,
  '$created',
  0,
  0,
  NULL,
  '',
  0,
  0,
  0
);
EOF

echo "✅ Setup key créée :"
echo "$setupkey"
