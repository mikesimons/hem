namespace :tools do
  desc "Fetches the n98-magerun utility"
  task :n98magerun do
    FileUtils.mkdir_p "bin"
    run_command '"wget" --no-check-certificate "https://raw.github.com/netz98/n98-magerun/master/n98-magerun.phar" -O bin/n98-magerun.phar'
    FileUtils.chmod 0755, "bin/n98-magerun.phar"
  end
end

desc "Magento related tasks"
namespace :magento do

  desc "Patch tasks"
  namespace :patches do
    def magento_path
      unless @magento_path
        files = locate('*app/Mage.php')
        unless files.length > 0
          raise Hem::UserError.new "Could not find app/Mage.php in the git repository, this command should only be run for Magento projects"
        end

        /(?:(.*)\/)app\/Mage\.php/.match(files[0])
        @magento_path = $1
      end
      @magento_path
    end

    def detect_clean
      status = shell('git status -z', :capture => true, :strip => false)
      status.split("\u0000").each do |line|
        match = line.match(/^([\s\S]{2})\s+(.*)$/)
        next if match.nil?

        if ![' ', '?'].include?($1[0]) || $2.start_with?(magento_path)
          raise Hem::UserError.new "Please remove all files from the git index, and stash all changes in '#{magento_path}' before continuing"
        end
      end
    end

    def detect_version
      config_dirty = false
      magento_version_file = "#{magento_path}/app/Mage.php"

      if Hem.project_config[:magento_edition].nil?
        magento_edition = nil
        if magento_version_file
          args = [ "php -r \"require '#{magento_version_file}'; echo Mage::getEdition();\""]

          magento_edition = run_command(*args, :capture => true).to_s.downcase
        end

        edition_options = ['community', 'enterprise', 'professional', 'go']

        unless edition_options.include? magento_edition
          raise Hem::Error.new "Invalid Magento edition '#{magento_edition}' was found when calling Mage::getEdition(), skipping patches"
        end

        Hem.project_config[:magento_edition] = magento_edition
        config_dirty = true
      end

      if Hem.project_config[:magento_version].nil?
        magento_version = nil
        if magento_version_file
          args = [ "php -r \"require '#{magento_version_file}'; echo Mage::getVersion();\""]

          magento_version = run_command(*args, :capture => true)
        end

        version_regex = /^\d+(\.\d+){3}$/

        unless version_regex.match(magento_version)
          raise Hem::Error.new "Invalid Magento version '#{magento_version}' was found when calling Mage::getVersion(), skipping patches"
        end

        Hem.project_config[:magento_version] = magento_version
        config_dirty = true
      end

      if config_dirty
        Hem::Config::File.save(Hem.project_config_file, Hem.project_config)
      end
    end

    def detect_tools
      use_vm = shell("which which", :exit_status => true) != 0

      tools = ['patch', 'sed']
      tools_command = tools.map {|tool| "which #{tool}"}.join " && "
      status = 0

      unless use_vm
        status = shell(tools_command, :exit_status => true)
        use_vm = status != 0
      end

      if use_vm
        status = run_command(tools_command, :exit_status => true)
      end

      if status != 0
        raise Hem::UserError.new "Please make sure '#{tools.join(',')}' is installed on your host or VM before continuing"
      end

      use_vm
    end

    desc "Apply patches to Magento"
    task "apply" do
      detect_clean
      detect_version

      config = Hem.project_config

      sync = Hem::Lib::S3::Sync.new(Hem.aws_credentials)

      patches_path = "#{Hem.project_path}/tools/patches"
      incoming_path = "#{patches_path}/incoming"

      Hem.ui.success("Downloading Magento #{config[:magento_edition].capitalize} #{config[:magento_version]} patches")
      changes = sync.sync(
        "s3://inviqa-assets-magento/#{config[:magento_edition]}/patches/#{config[:magento_version]}/",
        "#{incoming_path}/",
        :delete => false
      )
      Hem.ui.separator

      use_vm = false
      use_vm = detect_tools if Dir.glob("#{incoming_path}/*.sh").length > 0

      patch_files = Dir.glob("#{incoming_path}/*.{sh,patch,diff}")

      Hem.ui.success("#{patch_files.length} new patches found")

      Hem.ui.separator

      patch_files.each do |file|
        filename = File.basename(file)
        base_filename = File.basename(filename, File.extname(filename))

        if File.exist?("#{patches_path}/#{filename}")
          Hem.ui.debug("Patch #{filename} has already been applied, so skipping it")

          File.delete file
          next
        end

        if File.exist?("#{patches_path}/#{base_filename}.skip")
          File.delete file
          next
        end

        Hem.ui.success("Applying patch #{filename}")

        yaml_file = File.join(File.dirname(file), base_filename + ".yaml")

        metadata = {
          'commit_message' => "Apply Magento patch #{filename}"
        }
        if File.exist?(yaml_file)
          metadata = Hem::Config::File.load(yaml_file)
        end

        Hem.ui.info(metadata['description']) unless metadata['description'].nil?

        patch_options = %w( yes never skip )
        answer = Hem.ui.ask_choice('Do you want to apply this patch?', patch_options)

        if answer == 'skip'
          next
        end

        if answer == 'never'
          File.delete file
          File.write("#{patches_path}/#{base_filename}.skip", '')

          shell "git add '#{patches_path}/#{base_filename}.skip'"
          shell "git commit -m 'Add a skip file for patch #{filename}'"
          next
        end

        if /\.sh$/.match(file)
          File.rename file, "#{magento_path}/#{filename}"
          file = "#{magento_path}/#{filename}"
          if use_vm
            run_command "cd #{magento_path} && sh #{filename}", :realtime => true, :indent => 2
          else
            shell "cd #{magento_path} && sh #{filename}", :realtime => true, :indent => 2
          end
        else
          shell "git apply --directory #{magento_path} #{file}"
        end
        File.rename file, "#{patches_path}/#{filename}"
        shell "git add #{magento_path}"
        shell "git add #{patches_path}/#{filename}"

        if File.exist?(yaml_file)
          yaml_filename = File.basename(yaml_file)
          File.rename yaml_file, "#{patches_path}/#{yaml_filename}"
          shell "git add #{patches_path}/#{yaml_filename}"
        end
        shell "git commit -m #{metadata['commit_message'].shellescape}"

        Hem.ui.separator
      end

      Hem.ui.success("Finished applying #{patch_files.length} patches")
    end
  end

  desc "Setup script tasks"
  namespace :'setup-scripts' do
    desc "Run magento setup scripts"
    task :run => ['tools:n98magerun']  do
      Hem.ui.success "Running setup scripts"
      run_command("bin/n98-magerun.phar cache:clean config", :realtime => true, :indent => 2)
      run_command("bin/n98-magerun.phar sys:setup:incremental -n", :realtime => true, :indent => 2)
      Hem.ui.separator
    end
  end

  desc "Cache tasks"
  namespace :cache do
    desc "Clear cache"
    task :clear => ['tools:n98magerun']  do
      Hem.ui.success "Clearing magento cache"
      run_command("bin/n98-magerun.phar cache:flush", :realtime => true, :indent => 2)
      Hem.ui.separator
    end
  end

  desc "Configuration related tasks"
  namespace :config do
    desc "Configure magento base URLs"
    task :'configure-urls' => ['tools:n98magerun'] do
      Hem.ui.success "Configuring magento base urls"
      domain = Hem.project_config.hostname
      run_command("bin/n98-magerun.phar config:set web/unsecure/base_url 'http://#{domain}/'", :realtime => true, :indent => 2)
      run_command("bin/n98-magerun.phar config:set web/secure/base_url 'https://#{domain}/'", :realtime => true, :indent => 2)
      Hem.ui.separator
    end

    desc "Enable magento errors"
    task :'enable-errors' do
      error_config = File.join(Hem.project_path, 'public/errors/local.xml')

      FileUtils.cp(
          error_config + ".sample",
          error_config
      ) unless File.exists? error_config
    end

    desc "Create admin user"
    task :'create-admin-user' do
      initialized = run_command("bin/n98-magerun.phar admin:user:list | grep admin", :exit_status => true) == 0
      unless initialized
        Hem.ui.success "Creating admin user"
        run_command("bin/n98-magerun.phar admin:user:create admin '' admin admin admin", :realtime => true, :indent => 2)
        Hem.ui.separator
      end
    end

    desc "Enable rewrites"
    task :'enable-rewrites' do
      Hem.ui.success "Enabling rewrites"
      run_command("bin/n98-magerun.phar config:set web/seo/use_rewrites 1", :realtime => true, :indent => 2)
      Hem.ui.separator
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
