desc "Dependency related tasks"
hidden true
namespace :deps do

  desc "Install Gem dependencies"
  task :gems do
    locate "*Gemfile" do
      required = shell("bundle", "check", :exit_status => true) != 0
      if required
        Hem.ui.title "Installing Gem dependencies"
        shell "bundle", "install", realtime: true, indent: 2
        Hem.ui.separator
      end
    end
  end

  desc "Install composer dependencies"
  task :composer do
    if File.exists? File.join(Hem.project_path, "composer.json")
      Rake::Task["tools:composer"].invoke
      Hem.ui.title "Installing composer dependencies"
      Dir.chdir Hem.project_path do
        ansi = Hem.ui.supports_color? ? '--ansi' : ''
        args = [ "php bin/composer.phar install #{ansi} --prefer-dist", { realtime: true, indent: 2 } ]
        complete = false

        unless maybe(Hem.project_config.tasks.deps.composer.disable_host_run)
          check = Hem::Lib::HostCheck.check(:filter => /php_present/)

          if check[:php_present] == :ok
            begin
              shell *args
              complete = true
            rescue Hem::ExternalCommandError
              Hem.ui.warning "Installing composer dependencies locally failed!"
            end
          end
        end

        if !complete
          run_command *args
        end

        Hem.ui.success "Composer dependencies installed"
      end

      Hem.ui.separator
    end
  end

  desc "Install vagrant plugins"
  task :vagrant_plugins => [ "deps:gems" ] do
    plugins = shell "vagrant plugin list", :capture => true
    locate "*Vagrantfile" do
      to_install = []
      File.read("Vagrantfile").split("\n").each do |line|
        if line.match /#\s*Hem.vagrant_plugin (.*)/ or line.match /#\s*Hobo.vagrant_plugin (.*)/
          to_install << $1
        else
          next if line.match /^\s*#/
          next unless line.match /Vagrant\.require_plugin (.*)/
          to_install << $1
        end
      end

      to_install.each do |plugin|
        plugin.gsub!(/['"]*/, '')
        next if plugins.include? "#{plugin} "
        Hem.ui.title "Installing vagrant plugin: #{plugin}"
        shell "vagrant", "plugin", "install", plugin, :realtime => true, :indent => 2
        Hem.ui.separator
      end
    end
  end

  desc "Install chef dependencies"
  task :chef => [ "deps:gems" ] do
    locate "*Cheffile" do
      Hem.ui.title "Installing chef dependencies via librarian"
      bundle_shell "librarian-chef", "install", "--verbose", :realtime => true, :indent => 2 do |line|
        line =~ /Installing.*</ ? line.strip + "\n" : nil
      end
      Hem.ui.separator
    end

    locate "*Berksfile" do
      Hem.ui.title "Installing chef dependencies via berkshelf"
      executor = (shell("bash -c 'which berks'", :capture => true).strip =~ /chefdk/) ?
        lambda { |*args| shell *args } :
        lambda { |*args| bundle_shell *args }

      executor.call "berks", "install", :realtime => true, :indent => 2
      version = executor.call "berks", "-v", :capture => true
      if version =~ /^[3-9]/
        shell "rm -rf cookbooks"
        executor.call "berks", "vendor", "cookbooks"
      else
        executor.call "berks", "install", "--path", "cookbooks"
      end
      Hem.ui.separator
    end
  end
end