require 'puppet/acceptance/common_utils'

module Puppet
  module Acceptance
    module WindowsUtils
      require 'puppet/acceptance/windows_utils/service.rb'
      require 'puppet/acceptance/windows_utils/package_installer.rb'

      JA_DATE_FORMAT = '%y/%m/%d'.freeze
      FR_DATE_FORMAT = '%d/%m/%y'.freeze
      DATE_FORMAT    = '%m/%d/%y'.freeze

      def profile_base(agent)
        ruby = Puppet::Acceptance::CommandUtils.ruby_command(agent)
        getbasedir = <<'END'
require 'win32/dir'
puts Dir::PROFILE.match(/(.*)\\\\[^\\\\]*/)[1]
END
        on(agent, "#{ruby} -rubygems -e \"#{getbasedir}\"").stdout.chomp
      end

      # Checks whether the account with the given username has the given password on a host
      def assert_password_matches_on(host, username, password, msg = nil)
        script = <<-PS1
  Add-Type -AssemblyName System.DirectoryServices.AccountManagement
  $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Machine, $env:COMPUTERNAME)
  $ctx.ValidateCredentials("#{username}", "#{password}")
        PS1
        execute_powershell_script_on(host, script) do |result|
          assert_match(/True/, result.stdout.strip, msg)
        end
      end

      def date_format(locale)
        return JA_DATE_FORMAT if locale == 'ja'
        return FR_DATE_FORMAT if locale == 'fr'
        DATE_FORMAT
      end
    end
  end
end
