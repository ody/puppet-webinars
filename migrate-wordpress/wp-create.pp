#----------------------------------------------------------
# ____ ____ ____ ____ _    ____    ____ _    ____ _  _ ___  
# | __ |  | |  | | __ |    |___    |    |    |  | |  | |  \ 
# |__] |__| |__| |__] |___ |___    |___ |___ |__| |__| |__/ 
#
# Live migration of Wordpress to Google Cloud Platform

#-----
# Credentials & privileges

gauth_credential { 'cred':
  provider => serviceaccount,
  path     => '/opt/admin/my_account.json',
  scopes   => [
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/sqlservice.admin',
  ],
}

$legacy_server = '13.59.50.69'

#-----
# Infrastructure dependencies

gcompute_region { 'us-central1':
  project    => 'graphite-demo-puppet-webinar1',
  credential => 'cred',
}

gcompute_zone { 'us-central1-c':
  project    => 'graphite-demo-puppet-webinar1',
  credential => 'cred',
}

gcompute_machine_type { 'n1-standard-2':
  zone       => 'us-central1-c',
  project    => 'graphite-demo-puppet-webinar1',
  credential => 'cred',
}

gcompute_network { 'default':
  ensure     => present,
  project    => 'graphite-demo-puppet-webinar1',
  credential => 'cred',
}

if $facts['machine_name'] == undef {
  fail('Fact "machine_name" has to be defined')
}

#-----
# Static IP address for the Wordpress server

gcompute_address { $facts['machine_name']:
  ensure     => present,
  region     => 'us-central1',
  project    => 'graphite-demo-puppet-webinar1',
  credential => 'cred',
}

# Fetch the IP address of the VM
$fn_auth = gauth_credential_for_function(
  'serviceaccount', '/opt/admin/my_account.json',
  ['https://www.googleapis.com/auth/cloud-platform']
)

$wp_address = gcompute_address_ip($facts['machine_name'], 'us-central1',
                                  'graphite-demo-puppet-webinar1', $fn_auth)

if ! $wp_address {
  warning("Skipping SQL setup because IP address is just allocated. Run again.")
} else {
  info("Wordpress server @ ${wp_address}")

  #-----
  # MySQL database to host all Wordpress data

  gsql_instance { $facts['machine_name']:
    ensure           => present,
    database_version => 'MYSQL_5_7',
    settings         => {
      ip_configuration => {
        authorized_networks => [
          {
            name  => 'Admin workstation',
            value => '104.197.210.80/32',
          },
          {
            name  => 'Current server',
            value => "${wp_address}/32",
          },
          {
            name  => 'Legacy server',
            value => "${legacy_server}/32",
          },
        ],
      },
      tier             => 'db-n1-standard-1',
    },
    region           => 'us-central1',
    project          => 'graphite-demo-puppet-webinar1',
    credential       => 'cred',
  }

  #-----
  # SQL user with privileges to migrate the Wordpress data

  gsql_user { 'migration':
    ensure     => present,
    password   => 'super-secret-password',
    host       => '%',
    instance   => $facts['machine_name'],
    project    => 'graphite-demo-puppet-webinar1',
    credential => 'cred',
  }
}

#-----
# An Ubuntu 16.04 system image to use as Wordpress server

gcompute_disk { $facts['machine_name']:
  ensure       => present,
  size_gb      => 50,
  source_image => gcompute_image_family('ubuntu-1604-lts', 'ubuntu-os-cloud'),
  zone         => 'us-central1-c',
  project      => 'graphite-demo-puppet-webinar1',
  credential   => 'cred',
}

# Fetch the IP address of the SQL database
$wp_db_address = gsql_instance_ip($facts['machine_name'],
                                  'graphite-demo-puppet-webinar1', $fn_auth)

if ! $wp_db_address {
  warning("Skipping server because SQL instance is just allocated. Run again.")
} else {
  info("Wordpress database @ ${wp_db_address}")

  $master_server = 'puppet-enterprise.c.graphite-demo-puppet-webinar1.internal'
  info("Puppet Master @ ${master_server}")

  #-----
  # Virtual machine to run Wordpress server

  gcompute_instance { $facts['machine_name']:
    ensure             => present,
    machine_type       => 'n1-standard-2',
    disks              => [
      {
        boot        => true,
        source      => $facts['machine_name'],
        auto_delete => true,
      },
    ],
    metadata           => [
      {
        # A startup script that installs the CA certificate, Google Cloud
        # Logging, and defer to Puppet Agent installer script.
        'startup-script-url'     =>
          'gs://graphite-demo-puppet-webinar1/bootstrap.sh',
        # The URL of the Puppet Agent installer
        'puppet-agent-installer' =>
          "https://${master_server}:8140/packages/current/install.bash",
        # A trusted location where to fetch CA certificate (if not publicly
        # trusted, or trusted by the image being deployed already).
        'puppet-ca-cert'         =>
          'gs://graphite-demo-puppet-webinar1/puppet-ca-cert.pem',
        # The IP address of the SQL database, accessible from the server.
        'database-ip-address'    => $wp_db_address,
      },
    ],
    network_interfaces => [
      {
        network        => 'default',
        access_configs => [
          {
            # Associates the static IP for inbound network (from the Internet).
            name   => 'External NAT',
            nat_ip => $facts['machine_name'],
            type   => 'ONE_TO_ONE_NAT',
          },
        ],
      },
    ],
    service_accounts   => {
      scopes => [
        # Enable Cloud Storage so we can access the bootstrap.sh startup script.
        'https://www.googleapis.com/auth/devstorage.read_only',

        # Enable Stackdriver Logging API access
        'https://www.googleapis.com/auth/logging.write',
      ],
    },
    # In a future release tags will be replaced to be a straight array instead
    # of tags { items [ .... ] }
    tags               => {
      items => [
        # Default firewall rule only allows HTTP access to machines with
        # http-server tag attached to them.
        'http-server',
      ],
    },
    zone               => 'us-central1-c',
    project            => 'graphite-demo-puppet-webinar1',
    credential         => 'cred',
  }
}

#-----
# The DNS zone that serves eclipsecorner.org.

gdns_managed_zone { 'eclipsecorner-org':
  ensure     => present,
  dns_name   => 'eclipsecorner.org.',
  project    => 'graphite-demo-puppet-webinar1',
  credential => 'cred',
}

if ! $wp_address {
  warning("Skipping DNS setup because IP address is just allocated. Run again.")
} else {
  if $facts['staging'] {
    warning('Setting up the staging DNS record: staging.eclipsecorner.org.')
    $dns_rr_name = 'staging'
  } else {
    $dns_rr_name = 'www'
  }

  info("${dns_rr_name}.eclipsecorner.org @ ${wp_address}")

  #-----
  # Update our DNS records to point to the new Wordpress server
  #
  # Depending on $facts['staging'] it will update either
  # staging.eclipsecorner.org or www.eclipsecorner.org.

  gdns_resource_record_set { "${dns_rr_name}.eclipsecorner.org.":
    ensure       => present,
    managed_zone => 'eclipsecorner-org',
    type         => 'A',
    target       => $wp_address,
    ttl          => 5,
    project      => 'graphite-demo-puppet-webinar1',
    credential   => 'cred',
  }
}
