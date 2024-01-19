require 'open3'
require 'pathname'
require 'English'

def env_has_key(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

output_dir = env_has_key('AC_OUTPUT_DIR')
test_result_path = env_has_key('AC_TEST_RESULT_PATH')
convert_type = env_has_key('AC_CONVERT_TYPE')
convert_file_name = env_has_key('AC_CONVERT_FILE_NAME')

if File.extname(test_result_path) != ".xcresult"
    puts "Test result extension must be xcresult."
    exit 0
end

def runCommand(command)
    puts "@@[command] #{command}"
    unless system(command)
      exit $?.exitstatus
    end
end

def convert_xml(convert_type, test_result_path, output_dir, convert_file_name)
    puts "xcresult converting to #{convert_type}"
    command = "xcresultparser -o #{convert_type} #{test_result_path} > #{output_dir}/#{convert_file_name}.#{convert_type}"
    runCommand(command)
    puts "#{test_result_path} converted successfuly to #{convert_type}\n Exported to #{output_dir}/#{convert_file_name}.#{convert_type}"
end

open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
f.puts "AC_CONVERTED_TEST_RESULT_PATH=#{output_dir}/#{convert_file_name}.#{convert_type}"
}

runCommand("brew tap a7ex/homebrew-formulae")
runCommand("brew install xcresultparser")
convert_xml(convert_type, test_result_path, output_dir, convert_file_name)




