namespace :tools do
  desc "Fetches the n98-magerun utility"
  task :n98magerun do
    FileUtils.mkdir_p "bin"
    vm_shell '"wget" --no-check-certificate "https://raw.github.com/netz98/n98-magerun/master/n98-magerun.phar" -O bin/n98-magerun.phar'
    FileUtils.chmod 0755, "bin/n98-magerun.phar"
  end
end

desc "Magento related tasks"
namespace :magento do

  desc "Patch tasks"
  namespace :patches do
    def magento_path
      magento_version_file = 'public/app/Mage.php'
      /(?:(.*)\/)app\/Mage\.php/.match(magento_version_file)
      $1
    end

    def detect_clean
      status = shell('git status -z', :capture => true, :strip => false)
      status.split("\u0000").each do |line|
        match = line.match(/^([\s\S]{2})\s+(.*)$/)
        next if match.nil?

        if ![' ', '?'].include?($1[0]) || $2.start_with?(magento_path)
          raise Hobo::UserError.new "Please remove all files from the git index, and stash all changes in '#{magento_path}' before continuing"
        end
      end
    end

    def detect_version
      config_dirty = false
      magento_version_file = "#{magento_path}/app/Mage.php"

      if Hobo.project_config[:magento_edition].nil?
        magento_edition = nil
        if magento_version_file
          args = [ "php -r \"require '#{magento_version_file}'; echo Mage::getEdition();\""]

          magento_edition = vm_shell(*args, :capture => true).to_s.downcase
        end

        edition_options = ['community', 'enterprise', 'professional', 'go']

        unless edition_options.include? magento_edition
          raise Hobo::Error.new "Invalid Magento edition '#{magento_edition}' was found when calling Mage::getEdition(), skipping patches"
        end

        Hobo.project_config[:magento_edition] = magento_edition
        config_dirty = true
      end

      if Hobo.project_config[:magento_version].nil?
        magento_version = nil
        if magento_version_file
          args = [ "php -r \"require '#{magento_version_file}'; echo Mage::getVersion();\""]

          magento_version = vm_shell(*args, :capture => true)
        end

        version_regex = /^\d+(\.\d+){3}$/

        unless version_regex.match(magento_version)
          raise Hobo::Error.new "Invalid Magento version '#{magento_version}' was found when calling Mage::getVersion(), skipping patches"
        end

        Hobo.project_config[:magento_version] = magento_version
        config_dirty = true
      end

      if config_dirty
        Hobo::Config::File.save(Hobo.project_config_file, Hobo.project_config)
      end
    end

    def detect_tools
      ['patch'].each do |tool|
        status = vm_shell("which #{tool}", :exit_status => true)
        if status
          raise Hobo::UserError.new "Please install '#{tool}' on the VM before continuing"
        end
      end
    end

    desc "Apply patches to Magento"
    task "apply" do
      detect_clean
      detect_version
      detect_tools

      config = Hobo.project_config

      sync = Hobo::Lib::S3::Sync.new(Hobo.aws_credentials)

      patches_path = "tools/patches"
      incoming_path = "#{patches_path}/incoming"

      Hobo.ui.success("Downloading Magento #{config[:magento_edition].capitalize} #{config[:magento_version]} patches")
      changes = sync.sync(
        "s3://inviqa-assets-magento/#{config[:magento_edition]}/patches/#{config[:magento_version]}/",
        "#{incoming_path}/",
        :delete => false
      )
      Hobo.ui.separator

      Hobo.ui.success("#{changes[:add].length} new patches found")

      Hobo.ui.separator

      Dir.glob("#{incoming_path}/*.{sh,patch,diff}") do |file|
        filename = File.basename(file)

        if File.exist?("#{patches_path}/#{filename}")
          Hobo.ui.success("Patch #{filename} has already been applied, so skipping it")
          File.delete file
        end

        Hobo.ui.success("Applying patch #{filename}")

        if /\.sh$/.match(file)
          File.rename file, "#{magento_path}/#{filename}"
          file = "#{magento_path}/#{filename}"

          vm_shell "cd #{magento_path} && sh #{filename}", :realtime => true, :indent => 2
          File.rename file, "#{patches_path}/#{filename}"

          shell "git add #{magento_path}"
          shell "git commit -m 'Apply Magento patch #{filename}'"
        else
          shell "git am #{file}"
          File.rename file, "#{patches_path}/#{filename}"
        end
        shell "git add #{patches_path}/#{filename}"
        shell "git commit --amend --reuse-message HEAD"

        Hobo.ui.separator
      end

      Hobo.ui.success("Finished applying #{changes[:add].length} patches")
    end
  end

  desc "Setup script tasks"
  namespace :'setup-scripts' do
    desc "Run magento setup scripts"
    task :run => ['tools:n98magerun']  do
      Hobo.ui.success "Running setup scripts"
      vm_shell("bin/n98-magerun.phar sys:setup:incremental -n", :realtime => true, :indent => 2)
      Hobo.ui.separator
    end
  end

  desc "Cache tasks"
  namespace :cache do
    desc "Clear cache"
    task :clear => ['tools:n98magerun']  do
      Hobo.ui.success "Clearing magento cache"
      vm_shell("bin/n98-magerun.phar cache:flush", :realtime => true, :indent => 2)
      Hobo.ui.separator
    end
  end

  desc "Configuration related tasks"
  namespace :config do
    desc "Configure magento base URLs"
    task :'configure-urls' => ['tools:n98magerun'] do
      Hobo.ui.success "Configuring magento base urls"
      url = "http://#{Hobo.project_config.hostname}/"
      vm_shell("bin/n98-magerun.phar config:set web/unsecure/base_url '#{url}'", :realtime => true, :indent => 2)
      vm_shell("bin/n98-magerun.phar config:set web/secure/base_url '#{url}'", :realtime => true, :indent => 2)
      Hobo.ui.separator
    end

    desc "Enable magento errors"
    task :'enable-errors' do
      error_config = File.join(Hobo.project_path, 'public/errors/local.xml')

      FileUtils.cp(
          error_config + ".sample",
          error_config
      ) unless File.exists? error_config
    end

    desc "Create admin user"
    task :'create-admin-user' do
      initialized = vm_shell("bin/n98-magerun.phar admin:user:list | grep admin", :exit_status => true) == 0
      unless initialized
        Hobo.ui.success "Creating admin user"
        vm_shell("bin/n98-magerun.phar admin:user:create admin '' admin admin admin", :realtime => true, :indent => 2)
        Hobo.ui.separator
      end
    end

    desc "Enable rewrites"
    task :'enable-rewrites' do
      Hobo.ui.success "Enabling rewrites"
      vm_shell("bin/n98-magerun.phar config:set web/seo/use_rewrites 1", :realtime => true, :indent => 2)
      Hobo.ui.separator
    end
  end

  desc "Initializes magento specifics on the virtual machine after a fresh build"
  task :'initialize-vm' => [
    'magento:config:enable-errors',
    'tools:n98magerun',
    'magento:setup-scripts:run',
    'magento:config:configure-urls',
    'magento:config:create-admin-user',
    'magento:config:enable-rewrites',
    'magento:cache:clear'
  ]
end
