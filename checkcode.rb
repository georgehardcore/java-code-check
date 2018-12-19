#!/usr/bin/ruby2.3
require 'fileutils'
require 'tmpdir'
require 'yaml'
require 'open3'

class Array
    def check_all?
        inject(true) { |status, item| yield(item) && status }
    end
end

# Invoke the associated block with the name of generated temporary directory name
# The corresponding temporary directory is created and deleted automatically
def with_temporary_directory
    tmp_dir = Dir.mktmpdir + "/"
    result = yield tmp_dir
    FileUtils::rm_rf tmp_dir
    result
end

# Module provides means to detect the platform the code is running on
module OS
  def OS.windows?
    (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
  end

  def OS.mac?
   (/darwin/ =~ RUBY_PLATFORM) != nil
  end

  def OS.unix?
    !OS.windows?
  end

  def OS.linux?
    OS.unix? and not OS.mac?
  end
end

# Convert paths on windows platform into correct Cygwin notation
def fix_path(path)
    return path if not OS.windows?
    `cygpath -w #{path}`.strip.gsub("\\", "/")
end

# Convert path returned by hg on windows to correct form for filtering
def fix_hg_path(path)
    return path if not OS.windows?
    return path.strip.gsub("\\", "/")
end

# Class reads code checker configuration from tools directory and from
# repository
# Currently supported configuration options for tools configuration
# * tests - tests to perform on files
# * extensions - file extensions to check
# Currently supported configuration options for repository configuration
# * exclude - GLOB patterns of files to exclude from the code checking
# * classpath - paths to add to Java classpath
class Configuration
    
    @@REPOSITORY_CONFIG_FILENAME = 'codecheck-config.yaml'
    @@TOOLS_CONFIG_FILENAME = 'config/checkcode-global-config.yaml'
    
    attr_reader :exclude_patterns, :tests, :extensions, :environment_variables

    def initialize()
        @tests = []
        @extesions = []
        @exclude_patterns = []
        @java_classpaths = ''
        @environment_variables = {}
        read_config_file
        read_tools_config_file
    end

private

    def read_config_file()
        return if not File.exists?(@@REPOSITORY_CONFIG_FILENAME)
        config_file = YAML.load_file(@@REPOSITORY_CONFIG_FILENAME)
        @exclude_patterns = config_file['exclude'] if config_file.has_key?('exclude')
        return unless config_file.has_key?('classpath')
        paths = config_file['classpath']
        @java_classpaths = paths.map{|path| '-cp ' + fix_path(path)}.join(' ')
    end

    def read_tools_config_file()
        tools_directory = fix_path(File.expand_path(File.dirname(__FILE__)))
        filePath = tools_directory + '/' + @@TOOLS_CONFIG_FILENAME
        return if not File.exists?(filePath)
        config_file = YAML.load_file(filePath)
        @extensions = config_file['extensions'] if config_file.has_key?('extensions')
        tests = config_file['tests'] if config_file.has_key?('tests')
        @tests = tests.map do |test|
            {
                :test => test['test'] % {:base => tools_directory, :file => "%{file}",
                    :classpath => @java_classpaths},
                :check => test['check']
            }
        end
        @environment_variables["CLASSPATH"] = tools_directory + '/config'
    end

end

class CodeChecker

    # Create an object
    def initialize(extensions = [], exclude_patterns = [], tests = [], environment_variables = {})
        @revision = ENV['HG_NODE']
        @extensions = extensions
        @exclude_patterns = exclude_patterns
        @tests = tests
        @environment_variables = environment_variables
    end
    
    # main entry point of a checker
    def check_changeset
        with_temporary_directory do |tmp_dir|
            files_to_check = filter_filelist(`hg log -r "#{@revision}" --template '{file_mods} {file_adds}'`)
            files_to_check.check_all? { |filename| check_file_in_changeset(filename, tmp_dir) }
        end
    end

    # Check all files found in the repository 
    def check_repository
        run_check_in_repository '-a -m -c'
    end

    # Check all modifications made to the repository
    def check_modifications
        run_check_in_repository '-a -m'
    end

private

    def run_check_in_repository(file_mask)
        mask = "-I '**." + @extensions.join("' -I '**.") + "'"
        files_to_check = filter_filelist(`hg st #{file_mask} #{mask}`)
        files_to_check.check_all? { |filename| check_file(filename) }
    end

    def filter_filelist(mercurial_output)
        mercurial_output.split.select{ |filename|
            not @exclude_patterns.any? { |pattern| File.fnmatch(pattern, fix_hg_path(filename)) } and
            @extensions.any? { |extension| File.fnmatch('**.' + extension, filename) }
        }
    end

    def check_file_in_changeset(filename, tmp_dir)
        FileUtils.mkdir_p(tmp_dir + filename[/^.*\//])
        temp_file = tmp_dir + filename
        `hg cat -r #{@revision} #{filename} > #{temp_file}`
        check_file(temp_file)
    end

    def check_file(filename)
        filename.gsub!("\\", "/") if OS.windows?
        puts 'Checking ' + filename
        @tests.check_all? { |test| run_test(test[:test], test[:check], filename) }
    end

    def run_test(command, good_output, file)
        result, status = Open3.capture2(@environment_variables, "#{command % {:file => file}}")
        passed = good_output == result
        puts result unless passed
        passed
    end

end

if __FILE__ == $0
    config = Configuration.new
    checker = CodeChecker.new(config.extensions, config.exclude_patterns, config.tests,
                             config.environment_variables)
    if ENV['HG_NODE'] == nil
        if ARGV[0] == 'all'
            checker.check_repository
        else
            checker.check_modifications
        end
    elsif checker.check_changeset
        exit 0
    else
        exit 1
    end
end
