#!/bin/bash

set -euo pipefail

# --- Entrées utilisateur ---
FQDN_NODE="${1:-}"           # ex: vpn01.ori3com.cloud
RR_HOST="${2:-}"             # ex: vpn.ori3com.cloud
CF_TOKEN="${3:-}"            # Cloudflare API Token
NODE_ID="${4:-01}"           # ID du nœud (01, 02, etc.)

CF_API="https://api.cloudflare.com/client/v4"

# --- Vérifications préalables ---
if [[ -z "$FQDN_NODE" || -z "$RR_HOST" || -z "$CF_TOKEN" ]]; then
  echo "❌ Usage : $0 vpn01.ori3com.cloud vpn.ori3com.cloud <CLOUDFLARE_API_TOKEN> [NODE_ID]"
  echo "   Exemple : $0 vpn01.ori3com.cloud vpn.ori3com.cloud abc123token 01"
  exit 1
fi

command -v jq >/dev/null || { echo "❌ jq est requis. Installe-le avec 'sudo apt install jq'"; exit 1; }
command -v docker >/dev/null || { echo "❌ Docker est requis"; exit 1; }

# --- Construction des FQDN Syncthing ---
IFS='.' read -r sub1 sub2 sub3 <<< "$FQDN_NODE"
ROOT_DOMAIN="${sub2}.${sub3}"   # ori3com.cloud

# Remplacer le préfixe vpn par syncthing pour les FQDN
SYNCTHING_NODE_FQDN=$(echo "$FQDN_NODE" | sed 's/vpn/syncthing-/')
SYNCTHING_RR_FQDN=$(echo "$RR_HOST" | sed 's/vpn/syncthing/')

echo "🌐 Domaine racine détecté : $ROOT_DOMAIN"
echo "📌 FQDN NetBird : $FQDN_NODE"
echo "🎯 NetBird Round Robin : $RR_HOST"
echo "📦 FQDN Syncthing : $SYNCTHING_NODE_FQDN"
echo "🔄 Syncthing Round Robin : $SYNCTHING_RR_FQDN"
echo "🆔 Node ID : $NODE_ID"

# --- Obtenir zone ID Cloudflare ---
ZONE_ID=$(curl -s -X GET "$CF_API/zones?name=$ROOT_DOMAIN" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [[ "$ZONE_ID" == "null" || -z "$ZONE_ID" ]]; then
  echo "❌ Zone non trouvée sur Cloudflare"
  exit 1
fi

echo "✅ Zone ID récupéré : $ZONE_ID"

# --- Obtenir IP publique de ce VPS ---
IP=$(curl -s https://api.ipify.org)
echo "📡 IP publique de ce VPS : $IP"

# --- Fonction pour créer/mettre à jour un enregistrement DNS ---
update_dns_record() {
  local fqdn="$1"
  local ip="$2"
  local service_name="$3"
  
  local existing_id=$(curl -s -X GET "$CF_API/zones/$ZONE_ID/dns_records?type=A&name=$fqdn" \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')
  
  if [[ "$existing_id" == "null" || -z "$existing_id" ]]; then
    echo "➕ Création de l'entrée DNS $service_name : $fqdn"
    curl -s -X POST "$CF_API/zones/$ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":300,\"proxied\":false}" > /dev/null
  else
    echo "🔁 Mise à jour de l'entrée DNS $service_name : $fqdn"
    curl -s -X PUT "$CF_API/zones/$ZONE_ID/dns_records/$existing_id" \
      -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":300,\"proxied\":false}" > /dev/null
  fi
}

# --- Fonction pour gérer le round-robin DNS ---
update_rr_record() {
  local rr_fqdn="$1"
  local ip="$2"
  local service_name="$3"
  
  echo "🔍 Vérification du round-robin $service_name : $rr_fqdn"
  local existing_rr=$(curl -s -X GET "$CF_API/zones/$ZONE_ID/dns_records?type=A&name=$rr_fqdn" \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json")
  
  local existing_ips=$(echo "$existing_rr" | jq -r '.result[] | select(.type=="A") | .content')
  local rr_record_ids=$(echo "$existing_rr" | jq -r '.result[] | select(.type=="A") | .id')
  
  local all_ips=$(echo -e "$existing_ips\n$ip" | sort -u | grep -v '^$')
  
  # Supprimer anciens enregistrements
  echo "🧹 Suppression des anciens enregistrements de $rr_fqdn"
  for rid in $rr_record_ids; do
    [[ "$rid" != "null" && -n "$rid" ]] && curl -s -X DELETE "$CF_API/zones/$ZONE_ID/dns_records/$rid" \
      -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" > /dev/null
  done
  
  # Re-créer tous les A records
  for addr in $all_ips; do
    [[ -n "$addr" ]] && echo "➕ Ajout de $addr à $rr_fqdn" && \
    curl -s -X POST "$CF_API/zones/$ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$rr_fqdn\",\"content\":\"$addr\",\"ttl\":300,\"proxied\":false}" > /dev/null
  done
  
  echo "✅ DNS $rr_fqdn mis à jour avec : $all_ips"
}

# --- Mise à jour des enregistrements DNS ---
update_dns_record "$FQDN_NODE" "$IP" "NetBird"
update_dns_record "$SYNCTHING_NODE_FQDN" "$IP" "Syncthing"

update_rr_record "$RR_HOST" "$IP" "NetBird"
update_rr_record "$SYNCTHING_RR_FQDN" "$IP" "Syncthing"

# --- Génération des clés/secrets ---
SETUP_KEY="setup-$(openssl rand -hex 8)"
RELAY_SECRET=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
SYNCTHING_API_KEY=$(openssl rand -hex 32)

echo "🔐 Clés générées pour cette instance"

# --- Déploiement stack ---
mkdir -p ~/netbird-syncthing && cd ~/netbird-syncthing

# Création des répertoires pour Syncthing
mkdir -p syncthing/{config,data}

# Création du Caddyfile
cat <<EOF > Caddyfile
# NetBird Management
$FQDN_NODE {
  # Management API (gRPC)
  reverse_proxy /api/* netbird-mgmt:33073 {
    transport http {
      versions h2c
    }
  }
  
  # Dashboard UI
  reverse_proxy /* netbird-mgmt:80
  
  # Signal server
  reverse_proxy signal.* netbird-signal:10000 {
    transport http {
      versions h2c
    }
  }
}

# NetBird Relay WebSocket
$FQDN_NODE:33080 {
  reverse_proxy netbird-relay:33080
}

# Syncthing Web UI - ACCÈS RESTREINT AUX IPs NETBIRD
$SYNCTHING_NODE_FQDN {
  # Restriction d'accès aux réseaux NetBird (100.64.0.0/10)
  @not_netbird not remote_ip 100.64.0.0/10
  respond @not_netbird "Accès refusé - Connexion VPN NetBird requise" 403
  
  reverse_proxy syncthing:8384 {
    header_up Host {host}
    header_up X-Real-IP {remote}
    header_up X-Forwarded-For {remote}
    header_up X-Forwarded-Proto {scheme}
  }
}

# Round-robin Syncthing - ACCÈS RESTREINT
$SYNCTHING_RR_FQDN {
  # Restriction d'accès aux réseaux NetBird
  @not_netbird not remote_ip 100.64.0.0/10
  respond @not_netbird "Accès refusé - Connexion VPN NetBird requise" 403
  
  redir https://$SYNCTHING_NODE_FQDN{uri} permanent
}
EOF

# Création du fichier management.json pour NetBird
cat <<EOF > management.json
{
  "Stuns": [
    {
      "Proto": "udp",
      "URI": "stun:$FQDN_NODE:3478"
    }
  ],
  "TURNConfig": {
    "Turns": [
      {
        "Proto": "udp",
        "URI": "turn:$FQDN_NODE:3478",
        "Username": "netbird",
        "Password": "$RELAY_SECRET"
      }
    ],
    "CredentialsTTL": "24h",
    "Secret": "$RELAY_SECRET"
  },
  "Relay": {
    "Addresses": ["rel://$FQDN_NODE:33080"],
    "CredentialsTTL": "24h",
    "Secret": "$RELAY_SECRET"
  },
  "StoreConfig": {
    "Engine": "sqlite"
  },
  "HttpConfig": {
    "Address": "0.0.0.0:80"
  },
  "IdpManagerConfig": {
    "ManagerType": "none"
  },
  "DeviceAuthorizationFlow": {
    "Provider": "hosted",
    "ProviderConfig": {
      "Audience": "$FQDN_NODE",
      "Domain": "$FQDN_NODE",
      "ClientID": "netbird-client"
    }
  }
}
EOF

# Configuration Syncthing
cat <<EOF > syncthing/config/config.xml
<configuration version="37">
    <folder id="default" label="Default Folder" path="/var/syncthing/data" type="sendreceive" rescanIntervalS="3600" fsWatcherEnabled="true" fsWatcherDelayS="10" ignorePerms="false" autoNormalize="true">
        <filesystemType>basic</filesystemType>
        <device id="PLACEHOLDER" introducedBy=""></device>
        <minDiskFree unit="%">1</minDiskFree>
        <versioning></versioning>
        <copiers>0</copiers>
        <pullerMaxPendingKiB>0</pullerMaxPendingKiB>
        <hashers>0</hashers>
        <order>random</order>
        <ignoreDelete>false</ignoreDelete>
        <scanProgressIntervalS>0</scanProgressIntervalS>
        <pullerPauseS>0</pullerPauseS>
        <maxConflicts>10</maxConflicts>
        <disableSparseFiles>false</disableSparseFiles>
        <disableTempIndexes>false</disableTempIndexes>
        <paused>false</paused>
        <weakHashThresholdPct>25</weakHashThresholdPct>
        <markerName>.stfolder</markerName>
        <copyOwnershipFromParent>false</copyOwnershipFromParent>
        <modTimeWindowS>0</modTimeWindowS>
        <maxConcurrentWrites>2</maxConcurrentWrites>
        <disableFsync>false</disableFsync>
        <blockPullOrder>standard</blockPullOrder>
        <copyRangeMethod>standard</copyRangeMethod>
        <caseSensitiveFS>true</caseSensitiveFS>
        <junctionsAsDirs>false</junctionsAsDirs>
        <syncOwnership>false</syncOwnership>
        <sendOwnership>false</sendOwnership>
        <syncXattrs>false</syncXattrs>
        <sendXattrs>false</sendXattrs>
    </folder>
    <device id="PLACEHOLDER" name="$SYNCTHING_NODE_FQDN" compression="metadata" introducer="false" skipIntroductionRemovals="false" introducedBy="" paused="false" allowedNetwork="" autoAcceptFolders="false" maxSendKbps="0" maxRecvKbps="0" maxRequestKiB="0" untrusted="false" remoteGUIPort="0">
        <address>dynamic</address>
        <address>tcp://$SYNCTHING_NODE_FQDN:22000</address>
    </device>
    <gui enabled="true" tls="false" debugging="false" insecureAdminAccess="true">
        <address>0.0.0.0:8384</address>
        <apikey>$SYNCTHING_API_KEY</apikey>
        <theme>default</theme>
    </gui>
    <ldap></ldap>
    <options>
        <listenAddress>default</listenAddress>
        <globalAnnounceServer>default</globalAnnounceServer>
        <globalAnnounceEnabled>true</globalAnnounceEnabled>
        <localAnnounceEnabled>true</localAnnounceEnabled>
        <localAnnouncePort>21027</localAnnouncePort>
        <localAnnounceMCAddr>[ff12::8384]:21027</localAnnounceMCAddr>
        <maxSendKbps>0</maxSendKbps>
        <maxRecvKbps>0</maxRecvKbps>
        <reconnectionIntervalS>60</reconnectionIntervalS>
        <relaysEnabled>true</relaysEnabled>
        <relayReconnectIntervalM>10</relayReconnectIntervalM>
        <startBrowser>false</startBrowser>
        <natEnabled>true</natEnabled>
        <natLeaseMinutes>60</natLeaseMinutes>
        <natRenewalMinutes>30</natRenewalMinutes>
        <natTimeoutSeconds>10</natTimeoutSeconds>
        <urAccepted>-1</urAccepted>
        <urSeen>3</urSeen>
        <urUniqueID></urUniqueID>
        <urURL>https://data.syncthing.net/newdata</urURL>
        <urPostInsecurely>false</urPostInsecurely>
        <urInitialDelayS>1800</urInitialDelayS>
        <autoUpgradeIntervalH>12</autoUpgradeIntervalH>
        <upgradeToPreReleases>false</upgradeToPreReleases>
        <keepTemporariesH>24</keepTemporariesH>
        <cacheIgnoredFiles>false</cacheIgnoredFiles>
        <progressUpdateIntervalS>5</progressUpdateIntervalS>
        <limitBandwidthInLan>false</limitBandwidthInLan>
        <minHomeDiskFree unit="%">1</minHomeDiskFree>
        <releasesURL>https://upgrades.syncthing.net/meta.json</releasesURL>
        <overwriteRemoteDeviceNamesOnConnect>false</overwriteRemoteDeviceNamesOnConnect>
        <tempIndexMinBlocks>10</tempIndexMinBlocks>
        <trafficClass>0</trafficClass>
        <setLowPriority>true</setLowPriority>
        <maxFolderConcurrency>0</maxFolderConcurrency>
        <crashReportingURL>https://crash.syncthing.net/newcrash</crashReportingURL>
        <crashReportingEnabled>true</crashReportingEnabled>
        <stunKeepaliveStartS>180</stunKeepaliveStartS>
        <stunKeepaliveMinS>20</stunKeepaliveMinS>
        <stunServer>default</stunServer>
        <databaseTuning>auto</databaseTuning>
        <maxConcurrentIncomingRequestKiB>0</maxConcurrentIncomingRequestKiB>
        <announceLANAddresses>true</announceLANAddresses>
        <sendFullIndexOnUpgrade>false</sendFullIndexOnUpgrade>
        <connectionLimitEnough>0</connectionLimitEnough>
        <connectionLimitMax>0</connectionLimitMax>
        <insecureAllowOldTLSVersions>false</insecureAllowOldTLSVersions>
        <connectionPriorityTcpLan>10</connectionPriorityTcpLan>
        <connectionPriorityQuicLan>20</connectionPriorityQuicLan>
        <connectionPriorityTcpWan>30</connectionPriorityTcpWan>
        <connectionPriorityQuicWan>40</connectionPriorityQuicWan>
        <connectionPriorityRelay>50</connectionPriorityRelay>
        <connectionPriorityUpgradeThreshold>0</connectionPriorityUpgradeThreshold>
    </options>
</configuration>
EOF

# Création du docker-compose.yml
cat <<EOF > docker-compose.yml
version: "3.8"

services:
  # === NETBIRD SERVICES ===
  netbird-mgmt:
    image: netbirdio/management:latest
    container_name: netbird-mgmt
    restart: unless-stopped
    environment:
      - NETBIRD_MGMT_API_PORT=33073
      - NETBIRD_MGMT_HTTP_PORT=80
      - NETBIRD_MGMT_DATADIR=/var/lib/netbird
      - NETBIRD_LOG_LEVEL=info
    volumes:
      - ./management.json:/etc/netbird/management.json
      - netbird-mgmt:/var/lib/netbird
    ports:
      - "33073:33073"  # gRPC API
      - "8080:80"      # HTTP UI
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  netbird-signal:
    image: netbirdio/signal:latest
    container_name: netbird-signal
    restart: unless-stopped
    environment:
      - NETBIRD_LOG_LEVEL=info
    ports:
      - "10000:10000/udp"
    healthcheck:
      test: ["CMD", "netstat", "-ln", "|", "grep", ":10000"]
      interval: 30s
      timeout: 10s
      retries: 3

  netbird-relay:
    image: netbirdio/relay:latest
    container_name: netbird-relay
    restart: unless-stopped
    environment:
      - NB_LOG_LEVEL=info
      - NB_LISTEN_ADDRESS=:33080
      - NB_EXPOSED_ADDRESS=$IP:33080
      - NB_AUTH_SECRET=$RELAY_SECRET
    ports:
      - "33080:33080"
    logging:
      driver: "json-file"
      options:
        max-size: "500m"
        max-file: "2"
    healthcheck:
      test: ["CMD", "netstat", "-ln", "|", "grep", ":33080"]
      interval: 30s
      timeout: 10s
      retries: 3

  # TURN server pour fallback
  coturn:
    image: coturn/coturn:latest
    container_name: netbird-coturn
    restart: unless-stopped
    ports:
      - "3478:3478/udp"
      - "49152-65535:49152-65535/udp"
    environment:
      - TURN_USERNAME=netbird
      - TURN_PASSWORD=$RELAY_SECRET
    command: >
      -n
      --log-file=stdout
      --lt-cred-mech
      --fingerprint
      --no-multicast-peers
      --no-cli
      --no-tlsv1
      --no-tlsv1_1
      --realm=$FQDN_NODE
      --server-name=$FQDN_NODE
      --listening-port=3478
      --min-port=49152
      --max-port=65535
      --user=netbird:$RELAY_SECRET
      --external-ip=$IP

  # === SYNCTHING SERVICE ===
  syncthing:
    image: syncthing/syncthing:latest
    container_name: syncthing
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - STNORESTART=1
      - STNOUPGRADE=1
    volumes:
      - ./syncthing/config:/var/syncthing/config
      - ./syncthing/data:/var/syncthing/data
      - syncthing-db:/var/syncthing
    ports:
      # Web UI uniquement accessible via Caddy (pas d'exposition directe)
      # - "8384:8384"   # SUPPRIMÉ - Web UI uniquement via VPN
      - "22000:22000"   # Sync protocol (TCP) - nécessaire pour la sync
      - "22000:22000/udp" # Sync protocol (UDP) - nécessaire pour la sync
      - "21027:21027/udp" # Local discovery - nécessaire pour la sync
    expose:
      - "8384"  # Web UI accessible uniquement via le réseau Docker interne
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8384/rest/system/status"]
      interval: 30s
      timeout: 10s
      retries: 3
    labels:
      - "syncthing.node.id=$NODE_ID"
      - "syncthing.fqdn=$SYNCTHING_NODE_FQDN"
      - "syncthing.api.key=$SYNCTHING_API_KEY"

  # === REVERSE PROXY ===
  caddy:
    image: caddy:alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"  # HTTP/3 support
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - netbird-mgmt
      - netbird-signal
      - netbird-relay
      - syncthing
    healthcheck:
      test: ["CMD", "caddy", "validate", "--config", "/etc/caddy/Caddyfile"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  netbird-mgmt:
  syncthing-db:
  caddy_data:
  caddy_config:
EOF

# Script de configuration post-déploiement pour Syncthing
cat <<EOF > configure-syncthing.sh
#!/bin/bash
# Script pour configurer automatiquement Syncthing après démarrage

echo "⏳ Attente du démarrage de Syncthing..."
until curl -s -f http://localhost:8384/rest/system/status > /dev/null 2>&1; do
  sleep 5
done

echo "✅ Syncthing démarré, récupération de l'ID du device..."
DEVICE_ID=\$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" http://localhost:8384/rest/system/status | jq -r '.myID')

echo "🆔 Device ID: \$DEVICE_ID"

# Remplacer les placeholders dans la config
sed -i "s/PLACEHOLDER/\$DEVICE_ID/g" syncthing/config/config.xml

# Redémarrer Syncthing pour prendre en compte la config
docker compose restart syncthing

echo "📋 Configuration Syncthing terminée!"
echo "🌐 Interface Web: https://$SYNCTHING_NODE_FQDN"
echo "🔑 API Key: $SYNCTHING_API_KEY"
echo "🆔 Device ID: \$DEVICE_ID"

# Sauvegarder les informations
echo "SYNCTHING_DEVICE_ID=\$DEVICE_ID" >> ../syncthing-info.txt
EOF

chmod +x configure-syncthing.sh

# Démarrage des services
echo "🚀 Démarrage de la stack NetBird + Syncthing..."
docker compose pull
docker compose up -d

# Attendre que les services soient prêts
echo "⏳ Attente du démarrage des services..."
sleep 45

# Configuration automatique de Syncthing
echo "🔧 Configuration automatique de Syncthing..."
./configure-syncthing.sh

# Vérification des services
echo "🔍 Vérification des services..."
docker compose ps

# Récupération du Device ID Syncthing
SYNCTHING_DEVICE_ID=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" http://localhost:8384/rest/system/status 2>/dev/null | jq -r '.myID' 2>/dev/null || echo "N/A")

# Affichage des informations importantes
echo ""
echo "🎉 Déploiement terminé !"
echo "========================================"
echo "🌐 NETBIRD"
echo "----------------------------------------"
echo "📍 FQDN du nœud    : $FQDN_NODE"
echo "🌐 Round-Robin     : $RR_HOST"
echo "🔐 Setup Key       : $SETUP_KEY"
echo "🌍 Interface Web   : https://$FQDN_NODE"
echo "📊 Management API  : https://$FQDN_NODE:33073"
echo ""
echo "📦 SYNCTHING"
echo "----------------------------------------"
echo "📍 FQDN du nœud    : $SYNCTHING_NODE_FQDN"
echo "🌐 Round-Robin     : $SYNCTHING_RR_FQDN"
echo "🆔 Device ID       : $SYNCTHING_DEVICE_ID"
echo "🔑 API Key         : $SYNCTHING_API_KEY"
echo "🌍 Interface Web   : https://$SYNCTHING_NODE_FQDN (VPN REQUIS)"
echo "🔒 Sécurité        : Accès restreint aux clients NetBird uniquement"
echo "========================================"
echo ""
echo "💡 Pour connecter un client NetBird :"
echo "   netbird up --management-url https://$FQDN_NODE:33073 --setup-key $SETUP_KEY"
echo ""
echo "🔗 Pour ajouter ce Syncthing comme peer sur un autre nœud :"
echo "   Device ID: $SYNCTHING_DEVICE_ID"
echo "   Adresse: tcp://$SYNCTHING_NODE_FQDN:22000"
echo ""
echo "🔥 Ports à ouvrir sur le firewall :"
echo "   NetBird: 80,443/tcp + 10000/udp + 33073,33080/tcp + 3478/udp + 49152-65535/udp"
echo "   Syncthing: 22000/tcp + 22000,21027/udp (Web UI accessible uniquement via VPN)"
echo ""
echo "⚠️  SÉCURITÉ: L'interface web Syncthing n'est accessible que via NetBird VPN"
echo "   Connectez-vous d'abord au VPN NetBird avant d'accéder à Syncthing"
echo ""

# Sauvegarde des informations importantes
cat <<EOF > deployment-info.txt
=== DEPLOYMENT INFO - $(date) ===
Node ID: $NODE_ID
IP: $IP

=== NETBIRD ===
FQDN Node: $FQDN_NODE
Round-Robin: $RR_HOST
Setup Key: $SETUP_KEY
Relay Secret: $RELAY_SECRET
JWT Secret: $JWT_SECRET

=== SYNCTHING ===
FQDN Node: $SYNCTHING_NODE_FQDN
Round-Robin: $SYNCTHING_RR_FQDN
Device ID: $SYNCTHING_DEVICE_ID
API Key: $SYNCTHING_API_KEY

=== COMMANDES UTILES ===
Status: docker compose ps
Logs: docker compose logs -f [service]
Stop: docker compose down
Start: docker compose up -d
Syncthing Restart: docker compose restart syncthing

=== PEER CONFIGURATION ===
Pour ajouter ce nœud comme peer Syncthing :
- Device ID: $SYNCTHING_DEVICE_ID
- Addresses: tcp://$SYNCTHING_NODE_FQDN:22000
EOF

echo "📋 Informations sauvegardées dans deployment-info.txt"

# Script d'aide pour la configuration peer
cat <<EOF > add-syncthing-peer.sh
#!/bin/bash
# Script pour ajouter automatiquement un peer Syncthing

PEER_DEVICE_ID="\$1"
PEER_ADDRESS="\$2"
PEER_NAME="\$3"

if [[ -z "\$PEER_DEVICE_ID" || -z "\$PEER_ADDRESS" || -z "\$PEER_NAME" ]]; then
  echo "Usage: \$0 <DEVICE_ID> <ADDRESS> <NAME>"
  echo "Exemple: \$0 ABC123-XYZ789 tcp://syncthing-02.infra.ori3com.cloud:22000 'Node 02'"
  exit 1
fi

echo "🔗 Ajout du peer Syncthing..."
echo "Device ID: \$PEER_DEVICE_ID"
echo "Address: \$PEER_ADDRESS"
echo "Name: \$PEER_NAME"

# Configuration du peer via API
curl -X POST -H "X-API-Key: $SYNCTHING_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d "{
    \"deviceID\": \"\$PEER_DEVICE_ID\",
    \"name\": \"\$PEER_NAME\",
    \"addresses\": [\"dynamic\", \"\$PEER_ADDRESS\"],
    \"compression\": \"metadata\",
    \"introducer\": false,
    \"skipIntroductionRemovals\": false,
    \"paused\": false,
    \"allowedNetwork\": \"\",
    \"autoAcceptFolders\": false
  }" \\
  http://localhost:8384/rest/config/devices

echo "✅ Peer ajouté! Redémarrage de Syncthing..."
docker compose restart syncthing
EOF

chmod +x add-syncthing-peer.sh

echo ""
echo "🛠️  Script d'aide créé : ./add-syncthing-peer.sh"
echo "   Usage: ./add-syncthing-peer.sh <DEVICE_ID> <ADDRESS> <NAME>"
echo "   Exemple: ./add-syncthing-peer.sh ABC123-XYZ789 tcp://syncthing-02.infra.ori3com.cloud:22000 'Node 02'"
