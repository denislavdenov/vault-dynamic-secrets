#!/usr/bin/env bash

#search consul

which unzip curl socat jq route dig vim sshpass || {
apt-get update -y
apt-get install unzip socat jq dnsutils net-tools vim curl sshpass -y 
}
# Install consul\
CONSUL_VER=${CONSUL_VER}
which consul || {
echo "Determining Consul version to install ..."

CHECKPOINT_URL="https://checkpoint-api.hashicorp.com/v1/check"
if [ -z "$CURRENT_VER" ]; then
    CURRENT_VER=$(curl -s "${CHECKPOINT_URL}"/consul | jq .current_version | tr -d '"')
fi


if  ! [ "$CONSUL_VER" == "$CURRENT_VER" ]; then
    echo "THERE IS NEWER VERSION OF CONSUL: ${CURRENT_VER}"
    echo "Install is going to proceed with the older version: ${CONSUL_VER}"
fi

if [ -f "/vagrant/pkg/consul_${CONSUL_VER}_linux_amd64.zip" ]; then
		echo "Found Consul in /vagrant/pkg"
else
    echo "Fetching Consul version ${CONSUL_VER} ..."
    mkdir -p /vagrant/pkg/
    curl -s https://releases.hashicorp.com/consul/${CONSUL_VER}/consul_${CONSUL_VER}_linux_amd64.zip -o /vagrant/pkg/consul_${CONSUL_VER}_linux_amd64.zip
    if [ $? -ne 0 ]; then
        echo "Download failed! Exiting."
        exit 1
    fi
fi

echo "Installing Consul version ${CONSUL_VER} ..."
pushd /tmp
unzip /vagrant/pkg/consul_${CONSUL_VER}_linux_amd64.zip 
sudo chmod +x consul
sudo mv consul /usr/local/bin/consul

}