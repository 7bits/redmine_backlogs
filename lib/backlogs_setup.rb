require 'rubygems'
require 'yaml'
require 'singleton'

module Backlogs
  def version
    root = File.expand_path('..', File.dirname(__FILE__))
    git = File.join(root, '.git')
    v = Redmine::Plugin.find(:redmine_backlogs).version

    g = nil
    if File.directory?(git)
      Dir.chdir(root)
      g = `git log | head -1 | awk '{print $2}'`
      g.strip!
      g = "(#{g})"
    end

    v = [v, g].compact.join(' ')
    v = '?' if v == ''
    return v
  end
  module_function :version

  def platform_support(raise_error = false)
    case platform
      when :redmine
        return "#{Redmine::VERSION} (supported)" if Redmine::VERSION.to_a[0,2] == [1,3]
        return "#{Redmine::VERSION} (not supported, but it will work)" if Redmine::VERSION::MAJOR == 1 && Redmine::VERSION::MINOR == 2 && Redmine::VERSION::TINY > 0
        return "#{Redmine::VERSION} (NOT SUPPORTED)" unless raise_error
        raise "#{Redmine::VERSION} (NOT SUPPORTED)"
      when :chiliproject
        return "#{Redmine::VERSION} (supported)" if Redmine::VERSION.to_a[0,3] == [3,0,0]
        return "#{Redmine::VERSION} (NOT SUPPORTED)" unless raise_error
        raise "#{Redmine::VERSION} (NOT SUPPORTED)"
    end
  end
  module_function :platform_support

  def os
    return :windows if RUBY_PLATFORM =~ /cygwin|windows|mswin|mingw|bccwin|wince|emx/
    return :unix if RUBY_PLATFORM =~ /darwin|linux/
    return :java if RUBY_PLATFORM =~ /java/
    return nil
  end
  module_function :os

  def gems
    installed = Hash[*(['system_timer', 'nokogiri', 'open-uri/cached', 'holidays', 'icalendar', 'prawn'].collect{|gem| [gem, false]}.flatten)]
    installed.delete('system_timer') unless os == :unix && RUBY_VERSION =~ /^1\.8\./
    installed.keys.each{|gem|
      begin
        require gem
        installed[gem] = true
      rescue LoadError
      end
    }
    return installed
  end
  module_function :gems

  def trackers
    return {:task => !RbTask.tracker.nil?, :story => RbStory.trackers.size != 0, :default_priority => !IssuePriority.default.nil?}
  end
  module_function :trackers

  def task_workflow(project)
    return true if User.current.admin?
    return false unless RbTask.tracker

    roles = User.current.roles_for_project(@project)
    tracker = Tracker.find(RbTask.tracker)

    [false, true].each{|creator|
      [false, true].each{|assignee|
        tracker.issue_statuses.each {|status|
          status.new_statuses_allowed_to(roles, tracker, creator, assignee).each{|s|
            return true
          }
        }
      }
    }
  end
  module_function :task_workflow

  def migrated?
    available = Dir[File.join(File.dirname(__FILE__), '../db/migrate/*.rb')].collect{|m| Integer(m.split('_')[0])}.sort
    return true if migrations.size == 0
    ran = Setting.connection.execute("select version from schema_migrations where version like '%-redmine_backlogs'").collect{|m| Integer(m.split('-')[0])}.sort
    return ran >= available
  end
  module_function :migrated?

  def configured?(project=nil)
    return false if Backlogs.gems.values.reject{|installed| installed}.size > 0
    return false if Backlogs.trackers.values.reject{|configured| configured}.size > 0
    return false unless Backlogs.migrated?
    return false unless project.nil? || project.enabled_module_names.include?("backlogs")
    return true
  end
  module_function :configured?

  def platform
    unless @platform
      begin
        ChiliProject::VERSION
        @platform = :chiliproject
      rescue NameError
        @platform = :redmine
      end
    end
    return @platform
  end
  module_function :platform

  class SettingsProxy
    include Singleton

    def [](key)
      return safe_load[key]
    end

    def []=(key, value)
      settings = safe_load
      settings[key] = value
      Setting.plugin_redmine_backlogs = settings
    end

    def to_h
      h = safe_load
      h.freeze
      h
    end

    private

    def safe_load
      settings = Setting.plugin_redmine_backlogs.dup
      if settings.is_a?(String)
        Setting.connection.execute("select value from settings where name = 'plugin_redmine_backlogs'").each{|v| settings = v}
        settings = YAML::load(settings)
      end
      raise "Unable to load settings" if settings.is_a?(String)
      settings
    end
  end
  
  def setting
    SettingsProxy.instance
  end
  module_function :setting
  def settings
    SettingsProxy.instance.to_h
  end
  module_function :settings
end
