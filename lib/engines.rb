require "engines/plugin_list"
require "engines/plugin"

def logger
  RAILS_DEFAULT_LOGGER
end

module ::Engines
  # The name of the public directory to mirror public engine assets into.
  # Defaults to RAILS_ROOT/public/plugin_assets
  mattr_accessor :public_directory
  self.public_directory = File.join(RAILS_ROOT, 'public', 'plugin_assets')

  # The table in which to store plugin schema information. Defaults to
  # "plugin_schema_info".
  mattr_accessor :schema_info_table
  self.schema_info_table = "plugin_schema_info"

  # A reference to the current Rails::Initializer instance
  mattr_accessor :rails_initializer
  
  
  #--
  # These attributes control the behaviour of the engines extensions
  #++
  
  # Set this to true if views should *only* be loaded from plugins
  mattr_accessor :disable_application_view_loading
  self.disable_application_view_loading = false
  
  # Set this to true if controller/helper code shouldn't be loaded 
  # from the application
  mattr_accessor :disable_application_code_loading
  self.disable_application_code_loading = false
  
  # Set this ti true if code should not be mixed (i.e. it will be loaded
  # from the first valid path on $LOAD_PATH)
  mattr_accessor :disable_code_mixing
  self.disable_code_mixing = false
  
  
  private

  # A memo of the bottom of Rails' default load path
  mattr_accessor :rails_final_load_path
  # A memo of the bottom of Rails Dependencies load path
  mattr_accessor :rails_final_dependency_load_path
  
  public
    
  def self.version
    "#{Version::Major}.#{Version::Minor}.#{Version::Release}"
  end  
    
  def self.init(rails_configuration, rails_initializer)
    # First, determine if we're running in legacy mode
    @legacy_support = self.const_defined?(:LegacySupport) && LegacySupport

    # Store some information about the plugin subsystem
    Rails.configuration = rails_configuration

    # We need a hook into this so we can get freaky with the plugin loading itself
    self.rails_initializer = rails_initializer
    
    @load_all_plugins = false    
    
    store_load_path_marker
    store_dependency_load_path_marker
    
    Rails.plugins ||= PluginList.new
    enginize_previously_loaded_plugins # including this one, as it happens.

    initialize_base_public_directory
    
    check_for_star_wildcard
    
    logger.debug "engines has started."
  end

  # Whether or not to load legacy 'engines' (with init_engine.rb) as if they were plugins
  # You can enable legacy support by defining the LegacySupport constant
  # in the Engines module before Rails loads, i.e. at the *top* of environment.rb,
  # add:
  # 
  #   module Engines
  #     LegacySupport = true
  #   end
  #
  def self.legacy_support?
    @legacy_support
  end

  # A reference to the currently-loading/loaded plugin. This is present to support
  # legacy engines; it's preferred to use Rails.plugins[name] in your plugin's
  # init.rb file in order to get your Plugin instance.
  def self.current
    Rails.plugins.last
  end

  # This is set to true if Engines detects a "*" at the end of
  # the config.plugins array.  
  def self.load_all_plugins?
    @load_all_plugins
  end

  # Stores a record of the last path with Rails added to the load path.
  # We need this to ensure that we place our additions to the load path *after*
  # all Rails' defaults
  def self.store_load_path_marker
    self.rails_final_load_path = $LOAD_PATH.last
    logger.debug "Rails final load path: #{self.rails_final_load_path}"
  end

  # Store a record of the last entry in the dependency system's load path.
  # We need this to ensure that we place our additions to the load path *after*
  # all Rails' defaults
  def self.store_dependency_load_path_marker
    self.rails_final_dependency_load_path = ::Dependencies.load_paths.last
    logger.debug "Rails final dependency load path: #{self.rails_final_dependency_load_path}"
  end
  
  # Create Plugin instances for plugins loaded before Engines
  def self.enginize_previously_loaded_plugins
    Engines.rails_initializer.loaded_plugins.each do |name|
      plugin_path = File.join(self.find_plugin_path(name), name)
      unless Rails.plugins[name]
        plugin = Plugin.new(name, plugin_path)
        logger.debug "enginizing plugin: #{plugin.name} from #{plugin_path}"
        plugin.load # injects the extra directories into the load path, and mirrors public files
        Rails.plugins << plugin
      end
    end
    logger.debug "plugins is now: #{Rails.plugins.map { |p| p.name }.join(", ")}"
  end  
  
  # Ensure that the plugin asset subdirectory of RAILS_ROOT/public exists, and
  # that we've added a little warning message.
  def self.initialize_base_public_directory
    if !File.exist?(self.public_directory)
      # create the public/engines directory, with a warning message in it.
      logger.debug "Creating public engine files directory '#{self.public_directory}'"
      FileUtils.mkdir(self.public_directory)
      message = %{Files in this directory are automatically generated from your Rails Engines.
They are copied from the 'public' directories of each engine into this directory
each time Rails starts (server, console... any time 'start_engine' is called).
Any edits you make will NOT persist across the next server restart; instead you
should edit the files within the <engine_name>/public/ directory itself.}
      target = File.join(public_directory, "README")
      File.open(target, 'w') { |f| f.puts(message) } unless File.exist?(target)
    end
  end
  
  # Check for a "*" at the end of the plugins list; if one is found, note that
  # we should load all other plugins once Rails has finished initializing, and
  # remove the "*"
  def self.check_for_star_wildcard
    if Rails.configuration.plugins.last == "*"
      Rails.configuration.plugins.pop
      @load_all_plugins = true
    end 
  end


  #-
  # The following code is called once all plugins are loaded, and Rails is almost
  # finished initialization
  #+

  # Once the Rails Initializer has finished, the engines plugin takes over
  # and performs any post-processing tasks it may have, including:
  #
  # * loading any remaining plugins if config.plugins ended with a '*'
  # * ... nothing else right now.
  #
  def self.after_initialize
     if self.load_all_plugins?
      logger.debug "loading remaining plugins from #{Rails.configuration.plugin_paths.inspect}"
      # this will actually try to load ALL plugins again, but any that have already 
      # been loaded will be ignored.
      rails_initializer.load_all_plugins
    end
  end  
  
  
  #-
  # helper methods to find and deal with plugin paths and names
  #+
  
  def self.find_plugin_path(name)
    Rails.configuration.plugin_paths.find do |path|
      File.exist?(File.join(path, name.to_s))
    end    
  end
  
  # Also appears in Rails::Initializer extensions
  def self.plugin_name(path)
    File.basename(path)
  end
  
  
  def self.mirror_files_from(source, destination)
    return unless File.directory?(source)
    
    source_files = Dir[source + "/**/*"]
    source_dirs = source_files.select { |d| File.directory?(d) }
    source_files -= source_dirs  
    
    source_dirs.each do |dir|
      # strip down these paths so we have simple, relative paths we can
      # add to the destination
      target_dir = File.join(destination, dir.gsub(source, ''))
      begin        
        FileUtils.mkdir_p(target_dir)
      rescue Exception => e
        raise "Could not create directory #{target_dir}: \n" + e
      end
    end

    source_files.each do |file|
      begin
        target = File.join(destination, file.gsub(source, ''))
        unless File.exist?(target) && FileUtils.identical?(file, target)
          FileUtils.cp(file, target)
        end 
      rescue Exception => e
        raise "Could not copy #{file} to #{target}: \n" + e 
      end
    end  
  end
end