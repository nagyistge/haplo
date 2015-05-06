# Haplo Platform                                     http://haplo.org
# (c) ONEIS Ltd 2006 - 2015                    http://www.oneis.co.uk
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.


# Exception for throwing errors which may be reported to the developer
class JavaScriptAPIError < RuntimeError
end

class KJavaScriptPlugin < KPlugin

  def initialize(plugin_path)
    @plugin_path = plugin_path.dup.freeze    
    @plugin_json, @version = KJavaScriptPlugin.read_plugin_json_and_version(@plugin_path)
    # Verify the plugin_json is as expected
    KJavaScriptPlugin.reporting_errors do
      KJavaScriptPlugin.verify_plugin_json(@plugin_json)
    end
    @name = @plugin_json["pluginName"].freeze
    # Build controller factory info
    @controller_factories = []
    if @plugin_json.has_key?("respond")
      @plugin_json["respond"].each do |url_path|
        raise "Bad plugin respond path #{url_path}" unless url_path =~ /\A\/(do|api)\/([^\s\/]+)\z/
        @controller_factories << JavaScriptPluginControllerFactory.new($1 == 'api', $2, !!(@plugin_json['allowAnonymousRequests']), @name)
      end
    end
    # Make a hash of template name -> template kind from files on disc. Names from the JS side will be checked against this before trusting.
    @templates = Hash.new
    template_root = "#{plugin_path}/template/"
    Dir.glob("#{template_root}**/*.*") do |filename|
      if filename[template_root.length,filename.length] =~ /\A(.+?)\.([a-z0-9A-Z]+)\z/
        @templates[$1] = $2
      end
    end
    # Collect information
    @uses_database = !!(@plugin_json.has_key?("privilegesRequired") && @plugin_json["privilegesRequired"].include?("pDatabase"))
    @plugin_display_name = @plugin_json['displayName'].dup.freeze
    @plugin_description = @plugin_json['displayDescription'].dup.freeze
    @plugin_load_priority = (@plugin_json["loadPriority"] || KPlugin::DEFAULT_PLUGIN_LOAD_PRIORITY).to_i
    @api_version = @plugin_json['apiVersion'].to_i
  end

  def name
    @name
  end

  def version
    @version
  end

  def api_version
    @api_version
  end

  def plugin_path
    @plugin_path
  end

  def plugin_display_name
    @plugin_display_name
  end

  def plugin_description
    @plugin_description
  end

  def plugin_install_secret
    @plugin_json['installSecret']
  end

  def plugin_json
    @plugin_json
  end

  def uses_database
    @uses_database
  end

  def plugin_load_priority
    @plugin_load_priority
  end

  def has_privilege?(privilege)
    # Plugin has all the privileges requested in the plugin.json file, checks done on install.
    (@plugin_json["privilegesRequired"] || []).include?(privilege)
  end

  SCHEMA_LOCALS = {
    "type" => "T",
    "attribute" => "A",
    "aliased-attribute" => "AA",
    "qualifier" => "Q",
    "label" => "Label",
    "group" => "Group"
  }

  def javascript_load(runtime, schema_for_js_runtime)
    # Load global.js file, if appropraite, set up prefix and suffix for wrapping loaded scripts.
    name = self.name
    generated_javascript = ''
    global_js = "#{@plugin_path}/global.js"
    if File.exist?(global_js)
      runtime.loadScript(global_js, "p/#{name}/global.js", nil, nil)
    else
      generated_javascript << "var #{name} = O.plugin('#{name}');\n"
    end
    use_features = @plugin_json['use']
    if use_features && !(use_features.empty?)
      generated_javascript << "#{JSON.generate(use_features)}.forEach(function(f) { #{name}.use(f); });\n"
    end
    runtime.evaluateString(generated_javascript, "p/#{name}/auto-generated-global.js") if generated_javascript.length > 0
    prefix, suffix = javascript_file_wrappers(schema_for_js_runtime)
    # Load the JavaScript files
    @plugin_json["load"].each do |filename|
      raise "Bad plugin script filename" if filename =~ /\.\./ || filename =~ /\A\//
      runtime.loadScript("#{@plugin_path}/#{filename}", "p/#{name}/#{filename}", prefix, suffix)
    end
  end

  def javascript_file_wrappers(schema_for_js_runtime)
    name = self.name
    prefix = "(function(P"
    suffix = "\n})(#{name}"
    (@plugin_json["locals"] || {}).each do |k,v|
      # these values are checked, so can be trusted to be OK
      prefix << ", #{k}"
      suffix << ", #{name}.#{v}"
    end
    if self.api_version >= 4
      reqs = schema_for_js_runtime.for_plugin(name)
      reqs.each do |kind, value|
        locals_name = SCHEMA_LOCALS[kind]
        next unless locals_name # ignore "_optional" key
        prefix << ", #{locals_name}"
        suffix << ", $registry.pluginSchema.#{name}['#{kind}']"
      end
    end
    prefix << "){"
    suffix << ");\n"
    [prefix, suffix]
  end

  def on_install
    js_runtime = KJSPluginRuntime.current
    js_runtime.using_runtime do
      js_runtime.runtime.host.onPluginInstall(@name, @uses_database)
    end
  end

  def hook_needs_javascript_dispatch?(hook)
    KJSPluginRuntime.current.runtime.host.pluginImplementsHook(@name, hook)
  end

  def self.call_javascript_hooks(hook_name, runner, response, args)
    KJavaScriptPlugin.reporting_errors do
      jsplugins = KJSPluginRuntime.current
      jsresponse = jsplugins.make_response(response, runner)
      jsplugins.call_all_hooks(runner.jsargs(hook_name, jsresponse, args))
      jsplugins.retrieve_response(response, jsresponse, runner)
    end
  end

  def controller_for(path_element_name, other_path_elements, annotations)
    is_api = !!(annotations[:api_url])
    @controller_factories.each do |controller_factory|
      return controller_factory if controller_factory.is_api == is_api && controller_factory.path_element == path_element_name
    end
    nil
  end

  def load_template(name)
    kind = @templates[name]
    return nil if kind == nil
    # name is now trusted, as it has been checked against the list of templates found when registering the plugin
    File.open("#{@plugin_path}/template/#{name}.#{kind}") do |f|
      [f.read.strip, kind]
    end
  end

  # -----------------------------------------------------------------------------------------------------------------

  # Helper function for wrapping and reporting errors nicely for plugin development
  # Returns the result of the block
  PluginErrorInfo = Struct.new(:plugin_name)
  def self.reporting_errors(plugin_name = nil)
    # Do the block, and wrap any exceptions it raises
    begin
      yield
    rescue => e
      # If an exception is raised, mark it as something which should be reported as a plugin error
      runtime = KJSPluginRuntime.current_if_active
      pname = (runtime != nil) ? runtime.currently_executing_plugin_name : nil
      KFramework.mark_exception_as_reportable(e, PluginErrorInfo.new(pname || plugin_name))
      raise
    end
  end

  # -----------------------------------------------------------------------------------------------------------------

  def self.read_plugin_json_and_version(path)
    # Read the plugin.json file
    plugin_json = File.open("#{path}/plugin.json") { |f| JSON.parse(f.read) }
    # Read version file from disc, if it exists
    version = 'UNKNOWN'
    version_pathname = "#{path}/version"
    if File.exists?(version_pathname)
      File.open(version_pathname) { |f| version = f.read.chomp }
    end
    # Append version info from plugin.json
    version = "#{version}-#{plugin_json["pluginVersion"]}" if plugin_json.has_key?("pluginVersion")
    # Return both bits of info
    [plugin_json, version]
  end

  # Register a global javascript plugin - available to all apps
  def self.register_javascript_plugin(plugin_path)
    plugin = KJavaScriptPlugin.new(plugin_path)
    KPlugin.register_plugin(plugin)
    plugin.name
  end

  BUILT_IN_JAVASCRIPT_PLUGINS_DIR = "#{KFRAMEWORK_ROOT}/app/plugins"

  # Register built in plugins
  KPlugin::REGISTER_KNOWN_PLUGINS << Proc.new do
    Dir.glob("#{BUILT_IN_JAVASCRIPT_PLUGINS_DIR}/*/plugin.json") do |filename|
      begin
        self.register_javascript_plugin(File.dirname(filename))
      rescue => e
        # Too early in the application boot process for logging
        puts "\n\n*******\nWhile registering built-in JavaScript plugin #{filename}, got exception #{e}"; puts
      end
    end
  end

  def self.each_third_party_javascript_plugin
    # Find all the top level directories which may contain plugins
    top_level_dirs = Dir.entries(PLUGINS_LOCAL_DIRECTORY).select do |entry|
      # Only select actual directories, and not the ones ending with .dev which are used by development extensions
      entry !~ /\.dev\z/ && entry !~ /\A\./ && File.directory?("#{PLUGINS_LOCAL_DIRECTORY}/#{entry}")
    end
    # Then search for plugins in those directories, and yield the pathname of the directory
    top_level_dirs.each do |dir|
      Dir.glob("#{PLUGINS_LOCAL_DIRECTORY}/#{dir}/*/plugin.json") do |filename|
        yield File.dirname(filename)
      end
    end
  end

  # Register third party plugins
  KPlugin::REGISTER_KNOWN_PLUGINS << Proc.new do
    each_third_party_javascript_plugin do |pathname|
      begin
        self.register_javascript_plugin(pathname)
      rescue => e
        # Too early in the application boot process for logging
        puts "\n\n*******\nWhile registering third-party JavaScript plugin #{pathname}, got exception #{e}"; puts
      end
    end
    self.save_javascript_plugin_version_info
  end

  def self.reload_third_party_plugins(log_destination = :logger)
    before_scan = collect_plugin_version_info
    reload_required = []
    self.each_third_party_javascript_plugin do |pathname|
      # Read the version number
      plugin_json, version = self.read_plugin_json_and_version(pathname)
      name = plugin_json["pluginName"]
      if name != nil && before_scan[name] != version
        # Re-register (or register) the plugin
        self.register_javascript_plugin(pathname)
        # Does it require flushing the runtimes and caches in the running applications?
        if before_scan.has_key?(name)
          reload_required << name
        end
      end
    end
    # Stop now if nothing happened
    if reload_required.empty?
      KApp.logger.info("Reloaded third party plugins, no changes requiring application runtime flushing detected.")
    else
      # Go through each application, and see if has
      KApp.logger.info("Reloaded third party plugins, scanning for applications needing flushing for plugins: #{reload_required.join(', ')}")
      KApp.in_every_application do |app_id|
        installed_plugins = KPlugin.get_plugin_names_for_current_app
        reload_in_app = []
        reload_required.each do |name|
          reload_in_app.push(name) if installed_plugins.include?(name)
        end
        unless reload_in_app.empty?
          log_lines = ["Application #{app_id} #{KApp.global(:url_hostname)}"]
          reload_in_app.each { |name| log_lines << "  Changed plugin: #{name}" }
          # Reinstall the plugins: Trigger a JS runtime flush and call plugin's onInstall()
          KPlugin.install_plugin(reload_in_app, :reload)
          # Log
          case log_destination
          when :logger; KApp.logger.info(log_lines.join("\n"))
          when :stdout; puts(log_lines.join("\n"))
          else raise "Bad log destination #{log_destination}"
          end
        end
      end
    end
    # Finish by dumping the new version info and flushing the logs
    self.save_javascript_plugin_version_info
    KApp.logger.flush_buffered
  end

  def self.collect_plugin_version_info
    versions = {}
    KPlugin.each_registered_plugin do |plugin|
      if plugin.kind_of?(KJavaScriptPlugin)
        versions[plugin.name] = plugin.version
      end
    end
    versions
  end

  def self.save_javascript_plugin_version_info
    plugin_version_info = collect_plugin_version_info()
    File.open("#{PLUGINS_LOCAL_DIRECTORY}/versions.yaml", 'w') { |f| f.write YAML::dump(plugin_version_info) }
  end

  class JavaScriptPluginControllerFactory < Struct.new(:is_api, :path_element, :allow_anonymous, :plugin_name)
    def make_controller
      JavaScriptPluginController.new(self)
    end
  end

  # -----------------------------------------------------------------------------------------------------------------

  # Verification of plugin.json

  def self.verify_plugin_json(plugin_json)
    raise PluginJSONError, "plugin.json: Top level isn't a Hash" unless plugin_json.class == Hash
    plugin_json.each_key do |key|
      raise PluginJSONError, "plugin.json: Unknown key #{key}" unless PLUGIN_VALID_KEYS.has_key?(key)
    end
    PLUGIN_JSON_VERIFY.each do |v|
      v.verify(plugin_json)
    end
    api_version = plugin_json["apiVersion"]
    raise PluginJSONError, "plugin.json: Plugin requires a past apiVersion not implemented by this platform version" unless
          api_version >= MINIMUM_JAVASCRIPT_API_VERSION
    raise PluginJSONError, "plugin.json: Plugin requires a future apiVersion not implemented by this platform version" unless
          api_version <= CURRENT_JAVASCRIPT_API_VERSION
  end

  class PluginJSONError < RuntimeError
  end

  class PluginJSONVerify < Struct.new(:name, :required, :type)
    # Returns true if the key exists
    def verify(plugin_json)
      if plugin_json.has_key?(self.name)
        value = plugin_json[self.name]
        raise PluginJSONError, "plugin.json: #{self.name} should be a #{self.type.name}, but was a #{value.class.name}" unless
                value.kind_of?(self.type)
        true
      else
        raise PluginJSONError, "plugin.json: #{self.name} is not present" if self.required
        false
      end
    end
  end

  class PluginJSONVerifyBool < PluginJSONVerify
    def initialize(name, required)
      super(name, required, Object)
    end
    def verify(plugin_json)
      return unless super
      value = plugin_json[self.name]
      raise PluginJSONError, "plugin.json: #{self.name} should be true or false" unless value.class == TrueClass || value.class == FalseClass
    end
  end

  class PluginJSONVerifyHash < PluginJSONVerify
    def initialize(name, required, key_type, value_type)
      super(name, required, Hash)
      @key_type = key_type
      @value_type = value_type
    end
    def verify(plugin_json)
      return unless super
      plugin_json[self.name].each do |k, v|
        raise PluginJSONError, "plugin.json: in #{self.name}, key #{k} is not a #{self.key_type.name}" unless k.class == @key_type
        raise PluginJSONError, "plugin.json: in #{self.name}, value #{v} is not a #{self.value_type.name}" unless v.class == @value_type
      end
    end
  end

  class PluginJSONVerifyArray < PluginJSONVerify
    def initialize(name, required, value_type)
      super(name, required, Array)
      @value_type = value_type
    end
    def verify(plugin_json)
      return unless super
      plugin_json[self.name].each do |a|
        raise PluginJSONError, "plugin.json: in #{self.name}, value #{a} is not a #{@value_type.name}" unless a.class == @value_type
      end
    end
  end

  class PluginJSONVerifyArrayOfFilenames < PluginJSONVerifyArray
    def initialize(name, required)
      super(name, required, String)
    end
    def verify(plugin_json)
      return unless super
      plugin_json[self.name].each do |f|
        raise PluginJSONError, "plugin.json: in #{self.name}, filename #{f} is not valid" unless
                f =~ /\A([a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+\z/ && f !~ /\/\./ && f !~ /\/\//
      end
    end
  end

  class PluginJSONVerifyLocals <PluginJSONVerify
    def initialize(name, required)
      super(name, required, Hash)
    end
    def verify(plugin_json)
      return unless super
      plugin_json[self.name].each do |k,v|
        # Important checks!
        unless k.kind_of?(String) && v.kind_of?(String) && k =~ /\A[a-zA-Z][a-zA-Z0-9_]*\z/ && v =~ /\A[a-zA-Z][a-zA-Z0-9_\.]*\z/
          raise PluginJSONError, "plugin.json: in #{self.name}, invalid entry #{k}"
        end
      end
      api_version = (plugin_json["apiVersion"] || 4).to_i
      if api_version >= 4
        # Can't use schema names for locals when using API 4 or later
        KJavaScriptPlugin::SCHEMA_LOCALS.each_value do |k|
          if plugin_json[self.name].has_key?(k)
            raise PluginJSONError, "plugin.json: in #{self.name}, using a local named #{k} conflicts with schema names"
          end
        end
      end
    end
  end

  PLUGIN_JSON_VERIFY = [
      PluginJSONVerify.new("pluginName", true, String),
      PluginJSONVerify.new("pluginAuthor", true, String),
      PluginJSONVerify.new("pluginVersion", true, Fixnum),
      PluginJSONVerify.new("displayName", true, String),
      PluginJSONVerify.new("displayDescription", true, String),
      PluginJSONVerify.new("apiVersion", true, Fixnum),
      PluginJSONVerify.new("loadPriority", false, Fixnum),
      PluginJSONVerify.new("installSecret", false, String),
      PluginJSONVerifyLocals.new("locals", false),
      PluginJSONVerifyArrayOfFilenames.new("load", true),
      PluginJSONVerifyArray.new("use", false, String),
      PluginJSONVerifyArray.new("respond", false, String),
      PluginJSONVerifyArray.new("privilegesRequired", false, String),
      PluginJSONVerifyBool.new("allowAnonymousRequests", false)
    ]
  PLUGIN_JSON_VERIFY.freeze
  PLUGIN_VALID_KEYS = Hash.new
  PLUGIN_JSON_VERIFY.each { |v| PLUGIN_VALID_KEYS[v.name] = true }
  PLUGIN_VALID_KEYS.freeze

end
