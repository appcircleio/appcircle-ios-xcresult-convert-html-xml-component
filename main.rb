require 'open3'
require 'pathname'
require 'English'

def env_has_key(key)
  ENV[key].nil? || ENV[key] == '' ? nil : ENV[key]
end

output_dir = env_has_key('AC_OUTPUT_DIR')
test_result_path = env_has_key('AC_TEST_RESULT_PATH')
convert_type = env_has_key('AC_CONVERT_TYPE')
convert_file_name = env_has_key('AC_CONVERT_FILE_NAME')
include_coverage = env_has_key('AC_INCLUDE_COVERAGE')

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

open(ENV['AC_ENV_FILE_PATH'], 'a') do |f|
  f.puts "AC_CONVERTED_TEST_RESULT_PATH=#{output_dir}/#{convert_file_name}.#{convert_type}"
end

run_command('brew tap a7ex/homebrew-formulae')
run_command('brew install xcresultparser')
convert_xml(convert_type, test_result_path, output_dir, convert_file_name, include_coverage)
