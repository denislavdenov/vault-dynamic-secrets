#!/usr/bin/env bash
set -x
sudo systemctl stop consul
sleep 5
sudo systemctl status consul
DOMAIN=${DOMAIN}
SERVER_COUNT=${SERVER_COUNT}
DCNAME=${DCS}
DC=${DC}
TLS=${TLS}
SOFIA_SERVERS="[\"10.10.56.11\"]"
BTG_SERVERS="[\"10.20.56.11\"]"
JOIN_SERVER="[\"10.${DC}0.56.11\"]"
echo ${TLS}
var2=$(hostname)
mkdir -p /vagrant/logs
mkdir -p /etc/consul.d
rm -fr /tmp/consul

# Function used for unsealing Vault
acl_boostrap () {
    cat << EOF > /etc/consul.d/acl.json
    {
        "acl": {
            "enabled": true,
            "default_policy": "deny",
            "down_policy": "extend-cache"
        }
    }
EOF

    systemctl restart consul.service
    sleep 15
    consul acl bootstrap > /vagrant/keys/master.txt
    export CONSUL_HTTP_TOKEN=`cat /vagrant/keys/master.txt | grep "SecretID:" | cut -c15-`
    consul members
    consul acl policy create  -name "agent-token" -description "Agent Token Policy" -rules @/vagrant/policy/agent-policy.hcl
    consul acl policy create  -name "kv-token" -description "KV token policy" -rules @/vagrant/policy/kv.hcl
    consul acl policy create  -name "snapshot-token" -description "Snapshot token policy" -rules @/vagrant/policy/snapshot.hcl
    consul acl token create -description "Agent Token" -policy-name "agent-token" > /vagrant/keys/agent.txt
    consul acl token create -description "KV Token" -policy-name "kv-token" > /vagrant/keys/kv.txt
    consul acl token create -description "Snapshot Token" -policy-name "snapshot-token" > /vagrant/keys/snapshot.txt

}

change_acl_conf () {
    cat << EOF > /etc/consul.d/acl.json
    {
        "primary_datacenter": "sofia",
        "acl": {
            "enabled": true,
            "default_policy": "deny",
            "down_policy": "extend-cache",
            "tokens": {
                "default": "${AGENT_TOKEN}"
            }
        }
    }
EOF
}

unseal_vault () {
    curl \
        --request PUT \
        --cacert /etc/tls/vault.crt \
        --data "{ \"key\": \"`cat /vagrant/keys.txt | grep \"Unseal Key 1:\" | cut -c15-`\"}" \
        https://10.10.46.11:8200/v1/sys/unseal

    curl \
        --request PUT \
        --cacert /etc/tls/vault.crt \
        --data "{ \"key\": \"`cat /vagrant/keys.txt | grep \"Unseal Key 2:\" | cut -c15-`\"}" \
        https://10.10.46.11:8200/v1/sys/unseal

    curl \
        --request PUT \
        --cacert /etc/tls/vault.crt \
        --data "{ \"key\": \"`cat /vagrant/keys.txt | grep \"Unseal Key 3:\" | cut -c15-`\"}" \
        https://10.10.46.11:8200/v1/sys/unseal
}

# Function used for initialize Consul. Requires 2 arguments: Log level and the hostname assigned by the respective variables.
# If no log level is specified in the Vagrantfile, then default "info" is used.
init_consul () {
    killall consul

    LOG_LEVEL=$1
    if [ -z "$1" ]; then
        LOG_LEVEL="info"
    fi

    if [ -d /vagrant ]; then
    mkdir /vagrant/logs
    LOG="/vagrant/logs/$2.log"
    else
    LOG="vault.log"
    fi

    IP=$(hostname -I | cut -f2 -d' ')

    sudo useradd --system --home /etc/consul.d --shell /bin/false consul
    sudo chown --recursive consul:consul /etc/consul.d
    sudo chmod -R 755 /etc/consul.d/
    sudo mkdir --parents /tmp/consul
    sudo chown --recursive consul:consul /tmp/consul
    mkdir -p /tmp/consul_logs/
    sudo chown --recursive consul:consul /tmp/consul_logs/

    cat << EOF > /etc/systemd/system/consul.service
    [Unit]
    Description="HashiCorp Consul - A service mesh solution"
    Documentation=https://www.consul.io/
    Requires=network-online.target
    After=network-online.target

    [Service]
    User=consul
    Group=consul
    ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
    ExecReload=/usr/local/bin/consul reload
    KillMode=process
    Restart=on-failure
    LimitNOFILE=65536


    [Install]
    WantedBy=multi-user.target

EOF
}

# Function for creating the gossip encryption conf file. Requires 1 argument: the hostname . This function is always executed only once on the 1st server.
create_gossip_conf () {
    if [[ "$1" == "consul-server1-sofia" ]]; then
        encr=`consul keygen`
        cat << EOF > /etc/consul.d/encrypt.json

        {
            "encrypt": "${encr}"
        }
EOF
    fi
}
# Function that requests certificates from Vault. It requires 2 arguments: Datacenter name - DCNAME and DOMAIN
get_vault_certs () {
    CERTS=`curl --cacert /etc/tls/vault.crt --header "X-Vault-Token: \`cat /vagrant/keys.txt | grep "Initial Root Token:" | cut -c21-\`"        --request POST        --data '{"common_name": "'server.$1.$2'", "alt_names": "localhost", "ip_sans": "127.0.0.1", "ttl": "24h"}'       https://10.10.46.11:8200/v1/pki_int/issue/example-dot-com`
    if [ $? -ne 0 ];then
    $echo 'There is no certificates received'
    exit 1
    fi
    echo $CERTS | jq -r .data.issuing_ca > /etc/tls/consul-agent-ca.pem
    echo $CERTS | jq -r .data.certificate > /etc/tls/consul-agent.pem
    echo $CERTS | jq -r .data.private_key > /etc/tls/consul-agent-key.pem
}

# Function that creates the TLS encryption conf file if TLS is enabled in Vagrantfile
create_tls_conf () {
    cat << EOF > /etc/consul.d/tls.json

    {
        "verify_incoming_rpc": true,
        "verify_incoming_https": false,
        "verify_outgoing": true,
        "verify_server_hostname": true,
        "ca_file": "/etc/tls/consul-agent-ca.pem",
        "cert_file": "/etc/tls/consul-agent.pem",
        "key_file": "/etc/tls/consul-agent-key.pem",
        "ports": {
            "http": -1,
            "https": 8501
        }
    }

EOF
}

# Function that creates the conf file for the Consul servers. It requires 8 arguments. All of them are defined in the beginning of the script.
# Arguments 5 and 6 are the SOFIA_SERVERS and BTG_SERVERS and they are twisted depending in which DC you are creating the conf file.
create_server_conf () {
    if [[ ${2} =~ "server1" ]]; then
    cat << EOF > /etc/consul.d/config_${1}.json
    
    {
        
        "server": true,
        "node_name": "${2}",
        "bind_addr": "${3}",
        "client_addr": "0.0.0.0",
        "bootstrap_expect": 1,
        "retry_join": ${5},
        "log_level": "${7}",
        "data_dir": "/tmp/consul",
        "enable_script_checks": true,
        "domain": "${8}",
        "datacenter": "${1}",
        "ui": true,
        "disable_remote_exec": true

    }
EOF
    else
    cat << EOF > /etc/consul.d/config_${1}.json
    
    {
        
        "server": true,
        "node_name": "${2}",
        "bind_addr": "${3}",
        "client_addr": "0.0.0.0",
        "bootstrap_expect": ${4},
        "retry_join": ${5},
        "log_level": "${7}",
        "data_dir": "/tmp/consul",
        "enable_script_checks": true,
        "domain": "${8}",
        "datacenter": "${1}",
        "ui": true,
        "disable_remote_exec": true

    }
EOF
    fi

}

# Function that creates the conf file for Consul clients. It requires 6 arguments and they are defined in the beginning of the script.
# 3rd argument shall be the JOIN_SERVER as it points the client to which server contact for cluster join.
create_client_conf () {
    cat << EOF > /etc/consul.d/consul_client.json

        {
            "node_name": "${1}",
            "bind_addr": "${2}",
            "client_addr": "0.0.0.0",
            "retry_join": ${3},
            "log_level": "${4}",
            "data_dir": "/tmp/consul",
            "enable_script_checks": true,
            "domain": "${5}",
            "datacenter": "${6}",
            "ui": true,
            "disable_remote_exec": true
        }

EOF
}

# if [ ${TLS} = true ]; then
#     mkdir -p /etc/tls
#     sshpass -p 'vagrant' scp -o StrictHostKeyChecking=no vagrant@10.10.46.11:"/etc/vault.d/vault.crt" /etc/tls/
#      # Unsealing vault

#     unseal_vault
# fi

# Starting consul

init_consul ${LOG_LEVEL} ${var2} 

# if [ ${TLS} = true ]; then
#     create_gossip_conf $var2
# fi

if [[ "${var2}" =~ "consul-server" ]]; then
    killall consul
    # if [ ${TLS} = true ]; then
    #     sudo sshpass -p 'vagrant' scp -o StrictHostKeyChecking=no vagrant@10.10.56.11:"/etc/consul.d/encrypt.json" /etc/consul.d/
    #     get_vault_certs ${DCNAME} ${DOMAIN}

    #     create_tls_conf
    # fi
    
   
    if [[ "${var2}" =~ "sofia" ]]; then


    create_server_conf ${DCNAME} ${var2} ${IP} ${SERVER_COUNT} ${SOFIA_SERVERS} ${BTG_SERVERS} ${LOG_LEVEL} ${DOMAIN}


    fi

    if [[ "${var2}" =~ "botevgrad" ]]; then
    
    create_server_conf ${DCNAME} ${var2} ${IP} ${SERVER_COUNT} ${BTG_SERVERS} ${SOFIA_SERVERS} ${LOG_LEVEL} ${DOMAIN}
    fi


    sleep 1
    sudo systemctl enable consul
    sudo systemctl start consul
    journalctl -f -u consul.service > /vagrant/logs/${var2}.log &
    sleep 15
    sudo systemctl status consul

    # if [[ "${var2}" =~ "server1" ]]; then

    # acl_boostrap

    # fi
    # export AGENT_TOKEN=`cat /vagrant/keys/agent.txt | grep "SecretID:" | cut -c15-`
    # change_acl_conf
    systemctl restart consul
    sleep 15

else
    if [[ "${var2}" =~ "client" ]]; then
        killall consul
        # if [ ${TLS} = true ]; then
        #     sudo sshpass -p 'vagrant' scp -o StrictHostKeyChecking=no vagrant@10.10.56.11:"/etc/consul.d/encrypt.json" /etc/consul.d/
        #     get_vault_certs ${DCNAME} ${DOMAIN}

        #     create_tls_conf
        # fi
        create_client_conf ${var2} ${IP} ${JOIN_SERVER} ${LOG_LEVEL} ${DOMAIN} ${DCNAME}
    fi

    sleep 1
    # export AGENT_TOKEN=`cat /vagrant/keys/agent.txt | grep "SecretID:" | cut -c15-`
    # change_acl_conf
    sudo systemctl enable consul
    sudo systemctl start consul
    journalctl -f -u consul.service > /vagrant/logs/${var2}.log &
    sleep 15
    sudo systemctl status consul
    
fi


sleep 5
if [ ${TLS} = true ]; then
    # consul members -ca-file=/etc/tls/consul-agent-ca.pem -client-cert=/etc/tls/consul-agent.pem -client-key=/etc/tls/consul-agent-key.pem -http-addr="https://127.0.0.1:8501"
    # consul members -wan -ca-file=/etc/tls/consul-agent-ca.pem -client-cert=/etc/tls/consul-agent.pem -client-key=/etc/tls/consul-agent-key.pem -http-addr="https://127.0.0.1:8501"
    # curl --cacert /etc/tls/vault.crt --header "X-Vault-Token: `cat /vagrant/keys.txt | grep \"Initial Root Token:\" | cut -c21-`" --request PUT https://10.10.46.11:8200/v1/sys/seal
    sleep 1
else
    consul members
    consul members -wan
fi
set +x