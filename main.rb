require 'open3'
require 'pathname'
require 'English'
require 'digest'
require 'fileutils'

XCRESULTPARSER_VERSION = '2.2.0'.freeze
XCRESULTPARSER_SHA256 = '83d058fe215ea3b30c50eabc778020c02eadf89f0dcb87decd4b292528d6633a'.freeze

def env_has_key(key)
  ENV[key].nil? || ENV[key] == '' ? nil : ENV[key]
end

output_dir = env_has_key('AC_OUTPUT_DIR')
test_result_path = env_has_key('AC_TEST_RESULT_PATH')
convert_type = env_has_key('AC_CONVERT_TYPE')
convert_file_name = env_has_key('AC_CONVERT_FILE_NAME')
include_coverage = env_has_key('AC_INCLUDE_COVERAGE')
xcresultparser_base_url = (env_has_key('AC_XCRESULTPARSER_BASE_URL') || 'https://github.com/a7ex/xcresultparser/releases/download').chomp('/')

if File.extname(test_result_path) != '.xcresult'
  puts 'Test result extension must be xcresult.'
  exit 0
end

def run_command(command)
  puts "@@[command] #{command}"
  return if system(command)

  exit $?.exitstatus
end

def convert_xml(convert_type, test_result_path, output_dir, convert_file_name, include_coverage)
  puts "xcresult converting to #{convert_type}"
  command = "xcresultparser -o #{convert_type} #{test_result_path} > #{output_dir}/#{convert_file_name}.#{convert_type}"

  if include_coverage == 'Yes'
    command.concat(' ')
    command.concat('--coverage')
  end
  run_command(command)
  puts "#{test_result_path} converted successfuly to #{convert_type}\n Exported to #{output_dir}/#{convert_file_name}.#{convert_type}"
end

# Installs the pinned xcresultparser release binary unless the tool is already on PATH.
def install_xcresultparser(base_url)
  if system('which xcresultparser > /dev/null 2>&1')
    puts 'xcresultparser is already installed, skipping download.'
    return
  end

  install_dir = "#{Dir.home}/xcresultparser/#{XCRESULTPARSER_VERSION}"
  unless File.exist?("#{install_dir}/product/xcresultparser")
    archive_url = "#{base_url}/#{XCRESULTPARSER_VERSION}/xcresultparser.zip"
    puts "Downloading xcresultparser #{XCRESULTPARSER_VERSION} from #{archive_url}"
    run_command("curl -fsSL --retry 3 -o xcresultparser.zip #{archive_url}")
    checksum = Digest::SHA256.file('xcresultparser.zip').hexdigest
    abort "Checksum mismatch for xcresultparser.zip: expected #{XCRESULTPARSER_SHA256}, got #{checksum}" unless checksum == XCRESULTPARSER_SHA256
    puts "Checksum verified: #{checksum}"
    FileUtils.mkdir_p(install_dir)
    run_command("ditto -x -k xcresultparser.zip #{install_dir}")
    FileUtils.rm_f('xcresultparser.zip')
  end
  ENV['PATH'] = "#{install_dir}/product:#{ENV['PATH']}"
end

open(ENV['AC_ENV_FILE_PATH'], 'a') do |f|
  f.puts "AC_CONVERTED_TEST_RESULT_PATH=#{output_dir}/#{convert_file_name}.#{convert_type}"
end

install_xcresultparser(xcresultparser_base_url)
convert_xml(convert_type, test_result_path, output_dir, convert_file_name, include_coverage)
