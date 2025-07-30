apt-get update -f
apt -f install git docker-compose-v2
sudo apt install -f jq
chmod +x ./*.sh
./deploy-netbird-syncthing.sh
