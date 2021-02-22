#!/bin/bash

OPENSTACK_RELEASE=ussuri

#########  PASSWORDS  #########
MYSQL_PASSWD=root
RABBITMQ_PASSWD=openstack
KEYSTONE_ADMIN_PASSWD=keystone
ZION_TENANT_PASSWD=zion
###############################

LOG=/tmp/zion_aio_installation.log
IP_ADDRESS=$(hostname -I | cut -d ' ' -f1)
HOSTNAME=$(hostname)

###### Upgrade System ######
upgrade_system(){
    echo -e "127.0.0.1 \t localhost" > /etc/hosts
    echo -e "$IP_ADDRESS \t $HOSTNAME" >> /etc/hosts
    #ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

    add-apt-repository universe
    apt install software-properties-common -y
    add-apt-repository cloud-archive:$OPENSTACK_RELEASE -y
    apt update

    DEBIAN_FRONTEND=noninteractive apt -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
    unset DEBIAN_FRONTEND
    apt install python3-pip python3-openstackclient git curl -y
}


###### Install Memcached ######
install_memcache_server(){
    apt install memcached python3-memcache -y
    sed -i '/-l 127.0.0.1/c\-l 0.0.0.0' /etc/memcached.conf
    service memcached restart
}


###### Install RabbitMQ ######
install_rabbitmq_server(){
    apt install rabbitmq-server -y
    rabbitmqctl add_user openstack $RABBITMQ_PASSWD
    rabbitmqctl set_user_tags openstack administrator
    rabbitmqctl set_permissions openstack ".*" ".*" ".*"
    rabbitmq-plugins enable rabbitmq_management
}


##### Install Docker #####
install_docker(){
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    apt-key fingerprint 0EBFCD88
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt update
    apt install aufs-tools linux-image-generic apt-transport-https docker-ce ansible ant -y
    pip3 install docker
    docker pull adoptopenjdk/openjdk11:x86_64-ubuntu-jdk11u-nightly
    
    gpasswd -a "$(logname)" docker
    usermod -aG docker swift
}


##### Install Redis #####
install_redis(){
    apt install redis-server -y
    sed -i '/bind 127.0.0.1/c\bind 0.0.0.0' /etc/redis/redis.conf
    service redis restart
}


###### Install MySQL ######
install_mysql_server(){

    export DEBIAN_FRONTEND=noninteractive
    debconf-set-selections <<< "mariadb-server-10.0 mysql-server/root_password password $MYSQL_PASSWD"
    debconf-set-selections <<< "mariadb-server-10.0 mysql-server/root_password_again password $MYSQL_PASSWD"
    apt install mariadb-server python3-pymysql -y
    unset DEBIAN_FRONTEND
    
    mysql -uroot -p$MYSQL_PASSWD -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
    mysql -uroot -p$MYSQL_PASSWD -e "DELETE FROM mysql.user WHERE User=''"
    mysql -uroot -p$MYSQL_PASSWD -e "FLUSH PRIVILEGES"
    
    cat <<-EOF > /etc/mysql/mariadb.conf.d/99-openstack.cnf
    [mysqld]
    bind-address = 0.0.0.0
    default-storage-engine = innodb
    innodb_file_per_table = on
    max_connections = 4096
    collation-server = utf8_general_ci
    character-set-server = utf8
EOF
    
    service mysql restart

}


###### Install Keystone ######
install_openstack_keystone(){
    mysql -uroot -p$MYSQL_PASSWD -e "CREATE DATABASE keystone"
    mysql -uroot -p$MYSQL_PASSWD -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY 'keystone'"
    mysql -uroot -p$MYSQL_PASSWD -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY 'keystone'"
    
    apt install keystone apache2 libapache2-mod-wsgi-py3 -y
    
    sed -i '/connection =/c\connection = mysql+pymysql://keystone:keystone@'$HOSTNAME'/keystone' /etc/keystone/keystone.conf
    sed -i '/#provider = fernet/c\provider = fernet' /etc/keystone/keystone.conf
    
    
    su -s /bin/sh -c "keystone-manage db_sync" keystone
    keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
    keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
    keystone-manage bootstrap --bootstrap-password $KEYSTONE_ADMIN_PASSWD --bootstrap-admin-url http://$HOSTNAME:5000/v3/ --bootstrap-internal-url http://$HOSTNAME:5000/v3/ --bootstrap-public-url http://$IP_ADDRESS:5000/v3/ --bootstrap-region-id RegionOne
    
    echo "ServerName $HOSTNAME" >> /etc/apache2/apache2.conf
    rm -f /var/lib/keystone/keystone.db
    service apache2 restart
        
    cat <<-EOF > admin-openrc
    export OS_USERNAME=admin
    export OS_PASSWORD=$KEYSTONE_ADMIN_PASSWD
    export OS_PROJECT_NAME=admin
    export OS_USER_DOMAIN_NAME=Default
    export OS_PROJECT_DOMAIN_NAME=Default
    export OS_AUTH_URL=http://$HOSTNAME:5000/v3
    export OS_IDENTITY_API_VERSION=3
EOF
    
    source admin-openrc
    openstack role create user
    openstack role create ResellerAdmin
    
    openstack project create --domain default --description "Service Project" service
    openstack project create --domain default --description "Zion Test Project" zion
    
    openstack user create --domain default --password $ZION_TENANT_PASSWD zion
    
    openstack role add --project zion --user zion admin
    openstack role add --project zion --user zion ResellerAdmin
    openstack role add --domain default --user zion ResellerAdmin
    
    cat <<-EOF > zion-openrc
    export OS_USERNAME=zion
    export OS_PASSWORD=$ZION_TENANT_PASSWD
    export OS_PROJECT_NAME=zion
    export OS_USER_DOMAIN_NAME=Default
    export OS_PROJECT_DOMAIN_NAME=Default
    export OS_AUTH_URL=http://$HOSTNAME:5000/v3
    export OS_IDENTITY_API_VERSION=3
EOF
    
    source zion-openrc
    PROJECT_ID=$(openstack token issue | grep -w project_id | awk '{print $4}')
    
    cat <<-EOF >> zion-openrc
    export STORAGE_URL=http://$IP_ADDRESS:8080/v1/AUTH_$PROJECT_ID
    export TOKEN=\$(openstack token issue | grep -w id | awk '{print \$4}')
EOF

}

###### OpenStak Horizon ######
install_openstack_horizon() {

    apt install openstack-dashboard -y
 
    cat <<-EOF >> /etc/openstack-dashboard/local_settings.py
    OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"
    SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
    LOGIN_REDIRECT_URL = WEBROOT + "project/containers/"
    
    OPENSTACK_API_VERSIONS = {
        "identity": 3,
    }
    LANGUAGES = (
        ('en', 'English'),
    )
EOF
    
    sed -i '/OPENSTACK_HOST = "127.0.0.1"/c\OPENSTACK_HOST = "$HOSTNAME"' /etc/openstack-dashboard/local_settings.py
    sed -i 's/\/identity\/v3/:5000\/v3/g' /etc/openstack-dashboard/local_settings.py
    sed -i "/DEFAULT_THEME = 'ubuntu/c\DEFAULT_THEME = 'default'" /etc/openstack-dashboard/local_settings.py
    sed -i 's/127.0.0.1:11211/$HOSTNAME:11211/g' /etc/openstack-dashboard/local_settings.py

    systemctl reload apache2.service

}

###### Install Swift ######
install_openstack_swift_proxy(){

    source admin-openrc
    openstack user create --domain default --password swift swift
    openstack role add --project service --user swift admin
    openstack service create --name swift --description "OpenStack Object Storage" object-store
    
    openstack endpoint create --region RegionOne object-store public http://$IP_ADDRESS:8080/v1/AUTH_%\(tenant_id\)s
    openstack endpoint create --region RegionOne object-store internal http://$HOSTNAME:8080/v1/AUTH_%\(tenant_id\)s
    openstack endpoint create --region RegionOne object-store admin http://$HOSTNAME:8080/v1
    
    apt install swift swift-proxy swift-account swift-container swift-object -y
    apt install python3-swiftclient python3-keystoneclient python3-keystonemiddleware memcached -y
    apt install xfsprogs rsync -y
        
    gpasswd -a "$(logname)" swift
    usermod -aG swift "$(logname)"
    
    mkdir /etc/swift

    curl -o /etc/swift/proxy-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/proxy-server.conf-sample
    curl -o /etc/swift/account-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/account-server.conf-sample
    curl -o /etc/swift/container-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/container-server.conf-sample
    curl -o /etc/swift/object-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/object-server.conf-sample
    curl -o /etc/swift/swift.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/swift.conf-sample
    
    cp /etc/swift/proxy-server.conf /etc/swift/zion-proxy-server.conf
    sed -i '/^pipeline =/ d' /etc/swift/zion-proxy-server.conf
    sed -i '/\[pipeline:main\]/a pipeline = proxy-logging cache slo proxy-logging proxy-server' /etc/swift/zion-proxy-server.conf
    
    chown -R swift:swift /etc/swift
    find /etc/swift -type d -exec chmod 775 {} \;
    find /etc/swift -type f -exec chmod 664 {} \;
 
    sed -i '/pipeline = catch_errors gatekeeper healthcheck proxy-logging cache listing_formats container_sync bulk tempurl ratelimit tempauth copy container-quotas account-quotas slo dlo versioned_writes symlink proxy-logging proxy-server/c\# pipeline = catch_errors gatekeeper healthcheck proxy-logging cache listing_formats container_sync bulk tempurl ratelimit tempauth copy container-quotas account-quotas slo dlo versioned_writes symlink proxy-logging proxy-server' /etc/swift/proxy-server.conf
    sed -i '/#pipeline = catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk tempurl ratelimit authtoken keystoneauth copy container-quotas account-quotas slo dlo versioned_writes symlink proxy-logging proxy-server/c\pipeline = catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk tempurl ratelimit authtoken keystoneauth copy container-quotas account-quotas slo dlo versioned_writes symlink proxy-logging proxy-server' /etc/swift/proxy-server.conf

    sed -i '/# account_autocreate = false/c\account_autocreate = True' /etc/swift/proxy-server.conf
    sed -i '/# memcache_servers = 127.0.0.1:11211/c\memcache_servers = '$HOSTNAME':11211' /etc/swift/proxy-server.conf
 
    sed -i '/# \[filter:authtoken]/c\[filter:authtoken]' /etc/swift/proxy-server.conf
    sed -i '/# paste.filter_factory = keystonemiddleware.auth_token:filter_factory/c\paste.filter_factory = keystonemiddleware.auth_token:filter_factory' /etc/swift/proxy-server.conf
    sed -i '/# www_authenticate_uri = http:\/\/keystonehost:5000/c\www_authenticate_uri = http:\/\/'$HOSTNAME':5000' /etc/swift/proxy-server.conf
    sed -i '/# auth_url = http:\/\/keystonehost:5000/c\auth_url = http://'$HOSTNAME':5000' /etc/swift/proxy-server.conf
    sed -i '/# auth_plugin = password/c\auth_type = password' /etc/swift/proxy-server.conf
    sed -i '/# project_domain_id = default/c\project_domain_name = default' /etc/swift/proxy-server.conf
    sed -i '/# user_domain_id = default/c\user_domain_name = default' /etc/swift/proxy-server.conf
    sed -i '/# project_name = service/c\project_name = service' /etc/swift/proxy-server.conf
    sed -i '/# username = swift/c\username = swift' /etc/swift/proxy-server.conf
    sed -i '/# password = password/c\password = swift \nservice_token_roles_required = True' /etc/swift/proxy-server.conf
    sed -i '/# delay_auth_decision = False/c\delay_auth_decision = True' /etc/swift/proxy-server.conf

    sed -i '/# \[filter:keystoneauth]/c\[filter:keystoneauth]' /etc/swift/proxy-server.conf
    sed -i '/# use = egg:swift#keystoneauth/c\use = egg:swift#keystoneauth' /etc/swift/proxy-server.conf
    sed -i '/# operator_roles = admin, swiftoperator/c\operator_roles = admin, swiftoperator' /etc/swift/proxy-server.conf
    
    sed -i '/# workers = auto/c\workers = 1' /etc/swift/proxy-server.conf
 
    sed -i '/name = Policy-0/c\name = AiO' /etc/swift/swift.conf

    swift-init all stop

}

###### Install Swift SN ######
install_openstack_swift_sn(){

    apt install swift swift-account swift-container swift-object -y
    apt install python3-swiftclient python3-keystoneclient python3-keystonemiddleware memcached -y
    apt install xfsprogs rsync -y
        
    gpasswd -a "$(logname)" swift
    usermod -aG swift "$(logname)"
    
    mkdir /etc/swift
    
    curl -o /etc/swift/zion-proxy-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/proxy-server.conf-sample
    curl -o /etc/swift/account-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/account-server.conf-sample
    curl -o /etc/swift/container-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/container-server.conf-sample
    curl -o /etc/swift/object-server.conf https://opendev.org/openstack/swift/raw/branch/stable/$OPENSTACK_RELEASE/etc/object-server.conf-sample
    
    sed -i '/^pipeline =/ d' /etc/swift/zion-proxy-server.conf
    sed -i '/\[pipeline:main\]/a pipeline = proxy-logging cache slo proxy-logging proxy-server' /etc/swift/zion-proxy-server.conf
    
    mkdir -p /var/cache/swift
    chown -R root:swift /var/cache/swift
    chmod -R 775 /var/cache/swift
    chown -R swift:swift /srv/node

    chown -R swift:swift /etc/swift
    find /etc/swift -type d -exec chmod 775 {} \;
    find /etc/swift -type f -exec chmod 664 {} \;
 
    sed -i '/# workers = auto/c\workers = 1' /etc/swift/object-server.conf

    systemctl stop swift-account-auditor swift-account-reaper swift-account-replicator swift-container-auditor swift-container-replicator swift-container-sync swift-container-updater swift-object-auditor swift-object-reconstructor swift-object-replicator swift-object-updater
    systemctl disable swift-account-auditor swift-account-reaper swift-account-replicator swift-container-auditor swift-container-replicator swift-container-sync swift-container-updater swift-object-auditor swift-object-reconstructor swift-object-replicator swift-object-updater
    swift-init all stop

}

#### Install Swift AiO installation with rings #####
initialize_aio_swift(){

    sed -i '/# mount_check = true/c\mount_check = false' /etc/swift/account-server.conf
    sed -i '/# mount_check = true/c\mount_check = false' /etc/swift/container-server.conf
    sed -i '/# mount_check = true/c\mount_check = false' /etc/swift/object-server.con

    cd /etc/swift
    swift-ring-builder account.builder create 10 1 1
    swift-ring-builder account.builder add --region 1 --zone 1 --ip $HOSTNAME --port 6202 --device sda1 --weight 100
    swift-ring-builder account.builder
    swift-ring-builder account.builder rebalance
    
    swift-ring-builder container.builder create 10 1 1
    swift-ring-builder container.builder add --region 1 --zone 1 --ip $HOSTNAME --port 6201 --device sda1 --weight 100
    swift-ring-builder container.builder
    swift-ring-builder container.builder rebalance
    
    swift-ring-builder object.builder create 10 1 1
    swift-ring-builder object.builder add --region 1 --zone 1 --ip $HOSTNAME --port 6200 --device sda1 --weight 100
    swift-ring-builder object.builder
    swift-ring-builder object.builder rebalance
    cd ~
    
    chown -R swift:swift /etc/swift
    find /etc/swift -type d -exec chmod 775 {} \;
    find /etc/swift -type f -exec chmod 664 {} \;

}


#### Install Zion Proxy #####
install_zion_middleware_proxy(){
    
    git clone https://github.com/JosepSampe/storage-functions
    pip3 install -U storage-functions/Engine/swift/middleware
    pip3 install -U psutil redis
    
    cat <<-EOF >> /etc/swift/proxy-server.conf
    
    [filter:storage_functions]
    use = egg:swift-zion#zion_handler
    execution_server = proxy
    redis_host = $IP_ADDRESS
    disaggregated_compute = false
EOF

    sed -i '/^pipeline =/ d' /etc/swift/proxy-server.conf
    sed -i '/\[pipeline:main\]/a pipeline = catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk tempurl ratelimit authtoken keystoneauth copy container-quotas account-quotas storage_functions slo dlo versioned_writes symlink proxy-logging proxy-server' /etc/swift/proxy-server.conf

    rm -rf storage-functions
 
 }

#### Install Zion SN #####
install_zion_middleware_sn(){
    
    git clone https://github.com/JosepSampe/storage-functions
    pip3 install -U storage-functions/Engine/swift/middleware
    pip3 install -U psutil redis
    
    cat <<-EOF >> /etc/swift/object-server.conf
    
    [filter:storage_functions]
    use = egg:swift-zion#zion_handler
    execution_server = object
    redis_host = $IP_ADDRESS
    disaggregated_compute = false
EOF

    sed -i '/^pipeline =/ d' /etc/swift/object-server.conf
    sed -i '/\[pipeline:main\]/a pipeline = healthcheck recon storage_functions object-server' /etc/swift/object-server.conf
    
    mkdir -p /opt/zion/runtime/java/lib
    
    cp storage-functions/Engine/compute/runtime/java/bin/ZionDockerDaemon-1.0.jar /opt/zion/runtime/java
    cp storage-functions/Engine/compute/runtime/java/start_daemon.sh /opt/zion/runtime/java
    cp storage-functions/Engine/compute/runtime/java/logback.xml /opt/zion/runtime/java
    cp storage-functions/Engine/compute/runtime/worker.config /opt/zion/runtime/java
 
    cp -R storage-functions/Engine/compute/runtime/java/lib/* /opt/zion/runtime/java/lib
    cp storage-functions/Engine/bus/DockerJavaFacade/bin/SBusJavaFacade.jar /opt/zion/runtime/java/lib
    cp storage-functions/Engine/bus/DockerJavaFacade/bin/libjbus.so /opt/zion/runtime/java/lib
    cp storage-functions/Engine/bus/TransportLayer/bin/bus.so /opt/zion/runtime/java/lib
    
    sed -i "/host_ip=127.0.0.1/c\host_ip=$IP_ADDRESS" /opt/zion/runtime/java/worker.config
        
    mkdir -p /opt/zion/service
    cp storage-functions/Engine/compute/service/zion_service.py /opt/zion/service
    
    chown -R swift:swift /opt/zion
    
    find /opt/zion -type d -exec chmod 775 {} \;
    find /opt/zion -type f -exec chmod 664 {} \;
    chmod 777 /opt/zion/runtime/java/start_daemon.sh
    
    rm -rf storage-functions
}


install_zion_aio(){
    printf "\nStarting Zion Storage Functions AiO Installation.\n"
    printf "The script takes long to complete, be patient!\n"
    printf "See the full log at $LOG\n\n"
    
    printf "Upgrading Server System\t\t ... \t1%%"
    upgrade_system >> $LOG 2>&1; printf "\tDone!\n"
    
    printf "Installing Memcache Server\t ... \t5%%"
    install_memcache_server >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing RabbitMQ Server\t ... \t10%%"
    install_rabbitmq_server >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing Docker server\t ... \t15%%"
    install_docker >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing Redis Server\t\t ... \t20%%"
    install_redis >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing MySQL Srever\t\t ... \t25%%"
    install_mysql_server >> $LOG 2>&1; printf "\tDone!\n"
    
    printf "Installing OpenStack Keystone\t ... \t40%%"
    install_openstack_keystone >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing OpenStack Horizon\t ... \t60%%"
    install_openstack_horizon >> $LOG 2>&1; printf "\tDone!\n"
    
    printf "Installing OpenStack Swift\t ... \t80%%"
    install_openstack_swift_proxy >> $LOG 2>&1;
    install_openstack_swift_sn >> $LOG 2>&1;
    initialize_aio_swift $LOG 2>&1;
    printf "\tDone!\n"
    
    printf "Installing Zion Middleware\t ... \t90%%"
    install_zion_middleware_proxy >> $LOG 2>&1;
    install_zion_middleware_sn >> $LOG 2>&1;
    printf "\tDone!\n"


    printf "Zion Functions installation\t ... \t100%%\tCompleted!\n\n"
    printf "Access the Dashboard with the following URL: http://$IP_ADDRESS/horizon\n"
    printf "Login with user: zion | password: $ZION_TENANT_PASSWD\n\n"
}

install_zion_proxy(){
    printf "\nStarting Zion Storage Functions Proxy Installation.\n"
    printf "The script takes long to complete, be patient!\n"
    printf "See the full log at $LOG\n\n"
    
    printf "Upgrading Server System\t\t ... \t1%%"
    upgrade_system >> $LOG 2>&1; printf "\tDone!\n"
    
    printf "Installing Memcache Server\t ... \t5%%"
    install_memcache_server >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing RabbitMQ Server\t ... \t10%%"
    install_rabbitmq_server >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing Docker server\t ... \t15%%"
    install_docker >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing Redis Server\t\t ... \t20%%"
    install_redis >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing MySQL Srever\t\t ... \t25%%"
    install_mysql_server >> $LOG 2>&1; printf "\tDone!\n"
    
    printf "Installing OpenStack Keystone\t ... \t40%%"
    install_openstack_keystone >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing OpenStack Horizon\t ... \t60%%"
    install_openstack_horizon >> $LOG 2>&1; printf "\tDone!\n"
    printf "Installing OpenStack Swift\t ... \t80%%"
    install_openstack_swift_proxy >> $LOG 2>&1;printf "\tDone!\n"
    printf "Installing Zion Middleware\t ... \t90%%"
    install_zion_middleware_proxy >> $LOG 2>&1;printf "\tDone!\n"

    printf "Zion Functions installation\t ... \t100%%\tCompleted!\n\n"
    printf "Access the Dashboard with the following URL: http://$IP_ADDRESS/horizon\n"
    printf "Login with user: zion | password: $ZION_TENANT_PASSWD\n\n"
}

install_zion_sn(){
    printf "\nStarting Zion Storage Functions Storage Node Installation.\n"
    printf "The script takes long to complete, be patient!\n"
    printf "See the full log at $LOG\n\n"
    
    printf "Upgrading Server System\t\t ... \t1%%"
    upgrade_system >> $LOG 2>&1; printf "\tDone!\n"

    printf "Installing OpenStack Swift\t ... \t80%%"
    install_openstack_swift_sn >> $LOG 2>&1;printf "\tDone!\n"
    printf "Installing Zion Middleware\t ... \t90%%"
    install_zion_middleware_sn >> $LOG 2>&1;printf "\tDone!\n"

    printf "Zion Functions installation\t ... \t100%%\tCompleted!\n\n"
    printf "Access the Dashboard with the following URL: http://$IP_ADDRESS/horizon\n"
    printf "Login with user: zion | password: $ZION_TENANT_PASSWD\n\n"
}


update_zion_aio(){
    printf "Updating Zion Storage Functions Installation.\n"
    printf "See the full log at $LOG\n\n"

    printf "Installing Swift middleware\t ... \t20%%"
    git clone https://github.com/JosepSampe/storage-functions >> $LOG 2>&1;
    pip3 install -U storage-functions/Engine/swift/middleware >> $LOG 2>&1;
    pip3 install -U psutil >> $LOG 2>&1;
    printf "\tDone!\n"
    
    printf "Installing Libraries\t\t ... \t75%%"
    mkdir -p /opt/zion/runtime/java/lib
    
    cp storage-functions/Engine/compute/runtime/java/bin/ZionDockerDaemon-1.0.jar /opt/zion/runtime/java
    cp storage-functions/Engine/compute/runtime/java/start_daemon.sh /opt/zion/runtime/java
    cp storage-functions/Engine/compute/runtime/java/logback.xml /opt/zion/runtime/java
    cp storage-functions/Engine/compute/runtime/worker.config /opt/zion/runtime/java
 
    cp -R storage-functions/Engine/compute/runtime/java/lib/* /opt/zion/runtime/java/lib
    cp storage-functions/Engine/bus/DockerJavaFacade/bin/SBusJavaFacade.jar /opt/zion/runtime/java/lib
    cp storage-functions/Engine/bus/DockerJavaFacade/bin/libjbus.so /opt/zion/runtime/java/lib
    cp storage-functions/Engine/bus/TransportLayer/bin/bus.so /opt/zion/runtime/java/lib
    
    sed -i "/host_ip=127.0.0.1/c\host_ip=$IP_ADDRESS" /opt/zion/runtime/java/worker.config
 
    mkdir -p /opt/zion/service
    cp storage-functions/Engine/compute/service/zion_service.py /opt/zion/service
    
    chown -R swift:swift /opt/zion
    
    find /opt/zion -type d -exec chmod 775 {} \;
    find /opt/zion -type f -exec chmod 664 {} \;
    chmod 777 /opt/zion/runtime/java/start_daemon.sh
    
    rm -rf storage-functions
    
    printf "\tDone!\n"

    printf "Restarting services\t\t ... \t90%%"
    swift-init main restart >> $LOG 2>&1; printf "\tDone!\n"
    printf "Updating Zion AiO\t ... \t100%%\tCompleted!\n\n"
}

update_zion_proxy(){
    printf "Updating Zion Storage Functions Installation.\n"
    printf "See the full log at $LOG\n\n"

    printf "Installing Swift middleware\t ... \t50%%"
    git clone https://github.com/JosepSampe/storage-functions >> $LOG 2>&1;
    pip3 install -U storage-functions/Engine/swift/middleware >> $LOG 2>&1;
    pip3 install -U psutil redis >> $LOG 2>&1;
    printf "\tDone!\n"

    printf "Restarting services\t\t ... \t90%%"
    swift-init main restart >> $LOG 2>&1; printf "\tDone!\n"
    printf "Updating Zion AiO\t ... \t100%%\tCompleted!\n\n"
}

usage(){
    echo "Usage: sudo ./aio_u20_ussuri.sh install|update aio|proxy|sn"
    exit 1
}


COMMAND="$1"
NODE="$2"

main(){
    if [[ `lsb_release -rs` == "20.04" ]]
    then
        case $COMMAND in
          "install" )
            case $NODE in
                "aio" )
                 install_zion_aio
                ;;
                "proxy" )
                 install_zion_proxy
                ;;
                "sn" )
                 install_zion_sn
                ;;
            esac
          ;;  
          
          "update" )
            case $NODE in
                "aio" )
                 update_zion_aio
                ;;
                "proxy" )
                 update_zion_proxy
                ;;
                "sn" )
                 update_zion_aio
                ;;
            esac
           ;;
           * )
            usage
        esac
    else
        echo "Wrong ubuntu version, you must use Ubuntu 20.04"
    fi
    
}

main
