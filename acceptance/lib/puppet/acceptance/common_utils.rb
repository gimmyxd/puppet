module Puppet
  module Acceptance
    module BeakerUtils
      # TODO: This should be added to Beaker
      def assert_matching_arrays(expected, actual, message = "")
        assert_equal(expected.sort, actual.sort, message)
      end

      # TODO: Remove the wrappers to user_present
      # and user_absent if Beaker::Host's user_present
      # and user_absent functions are fixed to work with
      # Arista (EOS).

      def user_present(host, username)
        case host['platform']
        when /eos/
          on(host, "useradd #{username}")
        else
          host.user_present(username)
        end
      end

      def user_absent(host, username)
        case host['platform']
        when /eos/
          on(host, "userdel #{username}", acceptable_exit_codes: [0, 1])
        else
          host.user_absent(username)
        end
      end
    end

    module CronUtils
      def clean(agent, o={})
        o = {:user => 'tstuser'}.merge(o)
        run_cron_on(agent, :remove, o[:user])
        apply_manifest_on(agent, %[user { '%s': ensure => absent, managehome => false }] % o[:user])
      end

      def setup(agent, o={})
        o = {:user => 'tstuser'}.merge(o)
        apply_manifest_on(agent, %[user { '%s': ensure => present, managehome => false }] % o[:user])
        apply_manifest_on(agent, %[case $operatingsystem {
                                     centos, redhat, fedora: {$cron = 'cronie'}
                                     solaris: { $cron = 'core-os' }
                                     default: {$cron ='cron'} }
                                     package {'cron': name=> $cron, ensure=>present, }])
      end

      # Returns all of the lines that correspond to crontab entries
      # on the agent. For simplicity, these are any lines that do
      # not begin with '#'.
      def crontab_entries_of(host, username)
        crontab_contents = run_cron_on(host, :list, username).stdout.strip
        crontab_contents.lines.map(&:chomp).reject { |line| line =~ /^#/ }
      end
    end

    module CAUtils

      def initialize_ssl
        hostname = on(master, 'facter hostname').stdout.strip
        fqdn = on(master, 'facter fqdn').stdout.strip

        if master.use_service_scripts?
          step "Ensure puppet is stopped"
          # Passenger, in particular, must be shutdown for the cert setup steps to work,
          # but any running puppet master will interfere with webrick starting up and
          # potentially ignore the puppet.conf changes.
          on(master, puppet('resource', 'service', master['puppetservice'], "ensure=stopped"))
        end

        step "Clear SSL on all hosts"
        hosts.each do |host|
          ssldir = on(host, puppet('agent --configprint ssldir')).stdout.chomp
          on(host, "rm -rf '#{ssldir}'")
        end

        step "Master: Start Puppet Master" do
          master_opts = {
            :main => {
              :dns_alt_names => "puppet,#{hostname},#{fqdn}",
            },
            :__service_args__ => {
              # apache2 service scripts can't restart if we've removed the ssl dir
              :bypass_service_script => true,
            },
          }
          with_puppet_running_on(master, master_opts) do

            hosts.each do |host|
              next if host['roles'].include? 'master'

              step "Agents: Run agent --test first time to gen CSR"
              on host, puppet("agent --test --server #{master}"), :acceptable_exit_codes => [1]
            end

            # Sign all waiting certs
            step "Master: sign all certs"
            on master, puppet("cert --sign --all"), :acceptable_exit_codes => [0,24]

            step "Agents: Run agent --test second time to obtain signed cert"
            on agents, puppet("agent --test --server #{master}"), :acceptable_exit_codes => [0,2]
          end
        end
      end

      def clean_cert(host, cn, check = true)
        if host == master && master[:is_puppetserver]
            on master, puppet_resource("service", master['puppetservice'], "ensure=stopped")
        end

        on(host, puppet('cert', 'clean', cn), :acceptable_exit_codes => check ? [0] : [0, 24])
        if check
          assert_match(/remov.*Certificate.*#{cn}/i, stdout, "Should see a log message that certificate request was removed.")
          on(host, puppet('cert', 'list', '--all'))
          assert_no_match(/#{cn}/, stdout, "Should not see certificate in list anymore.")
        end
      end

      def clear_agent_ssl
        return if master.is_pe?
        step "All: Clear agent only ssl settings (do not clear master)"
        hosts.each do |host|
          next if host == master
          ssldir = on(host, puppet('agent --configprint ssldir')).stdout.chomp
          (host[:platform] =~ /cisco_nexus/) ? on(host, "rm -rf #{ssldir}") : on(host, host_command("rm -rf '#{ssldir}'"))
        end
      end

      def reset_agent_ssl(resign = true)
        return if master.is_pe?
        clear_agent_ssl

        hostname = master.execute('facter hostname')
        fqdn = master.execute('facter fqdn')

        step "Clear old agent certificates from master" do
          agents.each do |agent|
            next if agent == master && agent.is_using_passenger?
            agent_cn = on(agent, puppet('agent --configprint certname')).stdout.chomp
            clean_cert(master, agent_cn, false) if agent_cn
          end
        end

        if resign
          step "Master: Ensure the master is listening and autosigning"
          with_puppet_running_on(master,
                                  :master => {
                                    :dns_alt_names => "puppet,#{hostname},#{fqdn}",
                                    :autosign => true,
                                  }
                                ) do

            agents.each do |agent|
              next if agent == master && agent.is_using_passenger?
              step "Agents: Run agent --test once to obtain auto-signed cert" do
                on agent, puppet('agent', "--test --server #{master}"), :acceptable_exit_codes => [0,2]
              end
            end
          end
        end
      end
    end

    module CommandUtils
      def ruby_command(host)
        "env PATH=\"#{host['privatebindir']}:${PATH}\" ruby"
      end
      module_function :ruby_command

      def gem_command(host, type='aio')
        if type == 'aio'
          if host['platform'] =~ /windows/
            "env PATH=\"#{host['privatebindir']}:${PATH}\" cmd /c gem"
          else
            "env PATH=\"#{host['privatebindir']}:${PATH}\" gem"
          end
        else
          on(host, 'which gem').stdout.chomp
        end
      end
      module_function :gem_command
    end

    module ManifestUtils
      def resource_manifest(resource, title, params = {})
        params_str = params.map do |param, value|
          # This is not quite correct for all parameter values,
          # but it is good enough for most purposes.
          value_str = value.to_s
          value_str = "\"#{value_str}\"" if value.is_a?(String)

          "  #{param} => #{value_str}"
        end.join(",\n")

        <<-MANIFEST
#{resource} { '#{title}':
  #{params_str}
}
MANIFEST
      end

      def file_manifest(path, params = {})
        resource_manifest('file', path, params)
      end

      def cron_manifest(entry_name, params = {})
        resource_manifest('cron', entry_name, params)
      end

      def user_manifest(username, params = {})
        resource_manifest('user', username, params)
      end
    end
  end
end
