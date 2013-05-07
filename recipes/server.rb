class Chef::Recipe
  include CAOpenldap
end

include_recipe "ca_openldap::client"

# Install needed packages
package "openldap-servers" do
  action :upgrade
end

# Enable slapd service and stop it in order to complete its configuration
service "slapd" do
  action [:enable, :stop]
end

directory node.ca_openldap.db_dir do
  user "ldap"
  group "ldap"
  mode 0700
  recursive true
end

# TLS certificate and key path configuration
if node.ca_openldap.tls.enable != :no
  ruby_block "tls_path_configuration" do
    block do

      # Update TLS path configuration
      f = Chef::Util::FileEdit.new("#{node.ca_openldap.config_dir}/cn=config.ldif")
      f.search_file_replace_line(/olcTLSCACertificatePath:/, "olcTLSCACertificatePath: #{node.ca_openldap.tls.cacert_path}")
      f.search_file_replace_line(/olcTLSCertificateFile:/, "olcTLSCertificateFile: #{node.ca_openldap.tls.cert_file}")
      f.search_file_replace_line(/olcTLSCertificateKeyFile:/, "olcTLSCertificateKeyFile: #{node.ca_openldap.tls.key_file}")
      f.write_file
    end
  end
end

# TLS connection configuration
case node.ca_openldap.tls.enable
when :no
  use_ldap = "yes"
  use_ldaps = "no"
when :yes
  use_ldap = "yes"
  use_ldaps = "yes"
when :exclusive
  use_ldap = "no"
  use_ldaps = "yes"
else
  raise "unsupported value #{node.ca_openldap.tls.enable} for TLS configuration"
end

ruby_block "tls_connection_configuration" do
  block do
    f = Chef::Util::FileEdit.new("/etc/sysconfig/ldap")
    f.search_file_replace_line(/SLAPD_LDAP=/, "SLAPD_LDAP=#{use_ldap}")
    f.search_file_replace_line(/SLAPD_LDAPS=/, "SLAPD_LDAPS=#{use_ldaps}")
    f.write_file
  end
end

if use_ldaps && node.ca_openldap.use_existing_certs_and_key
  link node.ca_openldap.tls.cert_file do
    to "/etc/pki/tls/certs/#{node['fqdn']}.pem"
  end

  file node.ca_openldap.tls.key_file do
    owner "ldap"
    group "ldap"
    mode  0600
    content File.read "/etc/pki/tls/private/#{node['fqdn']}.key"
  end

  ruby_block "ca_certificate_link" do
    block do
      ca_cert = "/etc/pki/tls/certs/#{node['hostname']}-bundle.crt"
      link_name = File.join(node.ca_openldap.tls.cacert_path, `openssl x509 -hash -noout -in #{ca_cert}` + ".0")
      FileUtils.ln_s(ca_cert, link_name, force: true)
    end
    action :create
  end
end

# Configure the base DN, the root DN and its password
my_root_dn = build_rootdn
ruby_block "bdb_config" do
  block do

    slapd_conf_file = '/etc/openldap/slapd.d/cn=config/olcDatabase={2}bdb.ldif'
    password = LDAPUtils.ssha_password(node.ca_openldap.rootpassword)

    #configure suffix
    f = Chef::Util::FileEdit.new(slapd_conf_file)
    f.search_file_replace_line(/olcDbDirectory:/, "olcDbDirectory: #{node.ca_openldap.db_dir}")
    f.search_file_replace_line(/olcSuffix:/, "olcSuffix: #{node.ca_openldap.basedn}")

    #configure root dn and root password
    f.search_file_replace_line(/olcRootDN:/, "olcRootDN: #{my_root_dn}")
    f.search_file_delete_line(/olcRootPW:/)
    f.insert_line_after_match(/olcRootDN:/, "olcRootPW: #{password}")
    
    #configure log level
    f.search_file_delete_line(/olcLogLevel:/)
    f.insert_line_after_match(/olcRootPW:/, "olcLogLevel: #{node.ca_openldap.ldap_log_level}")
    
    #configure acl
    f.search_file_delete_line(/olcAccess:/)
    index = 0
    acls = node.ca_openldap.acls.inject("") do |acum, acl|
      acum << "olcAccess: {#{index}}#{acl}\n"
      index+= 1
      acum
    end
    f.insert_line_after_match(/olcLogLevel:/, acls)

    f.write_file
  end
  action :create
  notifies :start, "service[slapd]", :immediately
end
