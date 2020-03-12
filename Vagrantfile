# variables
SERVER_COUNT = 1
CONSUL_VER = "1.7.0"
VAULT= "1.2.3"
DOMAIN = "consul"
TLS = false

#The available log levels are "trace", "debug", "info", "warn", and "err". if empty - default is "info"
LOG_LEVEL = "trace" 

Vagrant.configure("2") do |config|
 
  # global settings of VMs
  config.vm.provider "virtualbox" do |v|
    v.memory = 1024
    v.cpus = 2
  end

  
  ["sofia",].to_enum.with_index(1).each do |dcname, dc|

    (1..SERVER_COUNT).each do |i|
      
      config.vm.define "consul-server#{i}-#{dcname}" do |node|
        node.vm.box = "denislavd/xenial64"
        node.vm.hostname = "consul-server#{i}-#{dcname}"
        node.vm.provision :shell, path: "scripts/install_consul.sh", env: {"CONSUL_VER" => CONSUL_VER}
        node.vm.provision :shell, path: "scripts/start_consul.sh", env: {"SERVER_COUNT" => SERVER_COUNT,"LOG_LEVEL" => LOG_LEVEL,"DOMAIN" => DOMAIN,"DCS" => "#{dcname}","DC" => "#{dc}","TLS" => TLS}
        node.vm.network "private_network", ip: "10.#{dc}0.56.1#{i}"
        node.vm.network "forwarded_port", guest: 8500, host: 8500 + i
      end
    end


    config.vm.define "client-vault-server1-#{dcname}" do |vault|
        vault.vm.box = "denislavd/xenial64"
        vault.vm.hostname = "client-vault-server1-#{dcname}"
        vault.vm.provision :shell, path: "scripts/install_consul.sh", env: {"CONSUL_VER" => CONSUL_VER}
        vault.vm.provision :shell, path: "scripts/start_consul.sh", env: {"SERVER_COUNT" => SERVER_COUNT,"LOG_LEVEL" => LOG_LEVEL,"DOMAIN" => DOMAIN,"DCS" => "#{dcname}","DC" => "#{dc}","TLS" => TLS}
        vault.vm.provision :shell, path: "scripts/install_vault.sh", env: {"VAULT" => VAULT,"DOMAIN" => DOMAIN}
        vault.vm.network "private_network", ip: "10.#{dc}0.46.11"
      end
  end
end
