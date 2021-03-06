module Hem
  class << self

    attr_accessor :project_bar_cache

    def relaunch! env = {}
      Kernel.exec(env, 'hem', '--skip-host-checks', *$HEM_ARGV)
    end

    def in_project?
      !!Hem.project_path
    end

    def progress file, increment, total, type, opts = {}
      require 'ruby-progressbar'

      opts = {
        :title => File.basename(file),
        :total => total,
        :format => "%t [%B] %p%% %e"
      }.merge(opts)

      # Hack to stop newline spam on windows
      opts[:length] = 79 if Gem::win_platform?

      @progress_bar_cache ||= {}

      if type == :reset
        type = :update
        @progress_bar_cache.delete file
      end

      @progress_bar_cache[file] ||= ProgressBar.create(opts)

      case type
        when :update
          @progress_bar_cache[file].progress = [
            @progress_bar_cache[file].progress + increment,
            total
          ].min
        when :finished
          @progress_bar_cache[file].finish
      end

      return @progress_bar_cache[file]
    end

    def aws_credentials
      {
        :access_key_id => maybe(Hem.user_config.aws.access_key_id) || ENV['AWS_ACCESS_KEY_ID'],
        :secret_access_key => maybe(Hem.user_config.aws.secret_access_key) || ENV['AWS_SECRET_ACCESS_KEY']
      }
    end

    def windows?
      require 'rbconfig'
      !!(RbConfig::CONFIG['host_os'] =~ /mswin|msys|mingw|cygwin|bccwin|wince|emc/)
    end

    def system_ruby?
      require 'rbconfig'
      File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"]).match(/\/rvm\/|\/\.rvm\/|\/\.rbenv/) != nil
    end

    def vagrant_plugin plugin, constraint = nil
      return [plugin, nil] if constraint.nil?
      return [plugin, Gem::Dependency.new(plugin, constraint)]
    end
  end
end
