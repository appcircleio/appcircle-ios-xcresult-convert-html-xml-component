# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'digest'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end


# ─── Helpers ──────────────────────────────────────────────────────────────────

STEP_ENV_KEYS = %w[
  AC_OUTPUT_DIR
  AC_TEST_RESULT_PATH
  AC_CONVERT_TYPE
  AC_CONVERT_FILE_NAME
  AC_INCLUDE_COVERAGE
  AC_XCRESULTPARSER_BASE_URL
  AC_ENV_FILE_PATH
].freeze
WHICH_COMMAND    = 'which xcresultparser > /dev/null 2>&1'
DEFAULT_BASE_URL = 'https://github.com/a7ex/xcresultparser/releases/download'
MAIN_OBJECT      = TOPLEVEL_BINDING.receiver

# Saves and clears every variable the step reads (plus PATH, which the step
# prepends to), runs the block, then restores them.
def with_clean_env
  keys = STEP_ENV_KEYS + ['PATH']
  old = keys.to_h { |k| [k, ENV[k]] }
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  yield
ensure
  keys.each { |k| ENV.delete(k) }
  old.each { |k, v| ENV[k] = v unless v.nil? }
end

# Stubs Kernel#system on `receiver` so no real command runs. Every call is
# recorded; the block maps a command to the exit code it should report (0 by
# default). A trivial `sh -c "exit N"` sets $? so run_command's
# `exit $?.exitstatus` sees a real Process::Status.
def stub_system(receiver, recorder: nil, &exit_code_for)
  allow(receiver).to receive(:system) do |cmd|
    recorder&.<<(cmd)
    code = exit_code_for ? exit_code_for.call(cmd).to_i : 0
    Kernel.system('sh', '-c', "exit #{code}")
  end
end

def stub_checksum(hexdigest)
  allow(Digest::SHA256).to receive(:file).with('xcresultparser.zip').and_return(double('Digest', hexdigest: hexdigest))
end

# Runs the block with $stdout and $stderr captured.
# Returns [stdout, stderr, SystemExit or nil].
def capture_io
  old_out = $stdout
  old_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  exit_error = nil
  begin
    yield
  rescue SystemExit => e
    exit_error = e
  end
  [$stdout.string, $stderr.string, exit_error]
ensure
  $stdout = old_out
  $stderr = old_err
end

# Ruby's Coverage resets a file's counters on every `load`, so a snapshot is
# taken before each load and summed into the final report.
COVERAGE_SNAPSHOTS = []

def snapshot_coverage
  return unless defined?(Coverage) && Coverage.running?

  data = Coverage.peek_result[MAIN_RB]
  COVERAGE_SNAPSHOTS << data if data
end

# Runs main.rb's step body in-process with the given ENV.
# Returns [stdout, stderr, SystemExit or nil].
def run_step(env)
  with_clean_env do
    env.each { |k, v| ENV[k] = v }
    old_program_name = $PROGRAM_NAME
    $PROGRAM_NAME = MAIN_RB
    snapshot_coverage
    begin
      capture_io { load MAIN_RB }
    ensure
      $PROGRAM_NAME = old_program_name
    end
  end
end

# Runs main.rb in a subprocess with the given ENV. Every variable the step reads
# is unset first (a nil value unsets it in the child), so the ambient
# environment cannot leak in.
def run_main(env = {})
  clean_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }
  Open3.capture3(clean_env.merge(env), "ruby #{MAIN_RB}")
end

# Writes a fake `xcresultparser` executable into bin_dir. It appends its
# arguments to $FAKE_TOOL_LOG and prints a stub report, so the subprocess tests
# run the real step without the real tool or any download.
#   FAKE_XCRESULTPARSER_FAIL=1 -> prints an error to stderr and exits 3
def write_fake_xcresultparser(bin_dir)
  FileUtils.mkdir_p(bin_dir)
  path = File.join(bin_dir, 'xcresultparser')
  File.write(path, <<~SH)
    #!/bin/sh
    echo "xcresultparser $*" >> "$FAKE_TOOL_LOG"
    if [ "$FAKE_XCRESULTPARSER_FAIL" = "1" ]; then
      echo "xcresultparser: error: invalid xcresult bundle" >&2
      exit 3
    fi
    echo "<testsuites name=\\"fake\\"/>"
  SH
  File.chmod(0o755, path)
  bin_dir
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    old.nil? ? ENV.delete('_TEST_VAR') : ENV['_TEST_VAR'] = old
  end

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_TEST_VAR'] = 'xml'
      expect(env_has_key('_TEST_VAR')).to eq('xml')
    end

    it 'keeps whitespace-only values as-is' do
      ENV['_TEST_VAR'] = '  '
      expect(env_has_key('_TEST_VAR')).to eq('  ')
    end
  end

  context 'negative path' do
    it 'returns nil when the key is missing' do
      ENV.delete('_TEST_VAR')
      expect(env_has_key('_TEST_VAR')).to be_nil
    end

    it 'returns nil when the value is an empty string' do
      ENV['_TEST_VAR'] = ''
      expect(env_has_key('_TEST_VAR')).to be_nil
    end

    it 'raises TypeError for a nil key' do
      expect { env_has_key(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  let(:commands) { [] }

  context 'positive path' do
    it 'passes the command string to system unchanged' do
      stub_system(self, recorder: commands)
      capture_io { run_command('xcresultparser -o xml "A B.xcresult" > out/r.xml') }
      expect(commands).to eq(['xcresultparser -o xml "A B.xcresult" > out/r.xml'])
    end

    it 'logs the command and returns nil when it succeeds' do
      stub_system(self)
      result = nil
      out, _err, error = capture_io { result = run_command('xcresultparser -o html t.xcresult') }
      expect(error).to be_nil
      expect(result).to be_nil
      expect(out).to eq("@@[command] xcresultparser -o html t.xcresult\n")
    end

    it 'does not exit for a real shell command that succeeds' do
      _out, _err, error = capture_io { run_command('true') }
      expect(error).to be_nil
    end
  end

  context 'negative path' do
    it 'exits with the exit status reported by the failing command' do
      stub_system(self) { 3 }
      expect { run_command('xcresultparser -o xml bad.xcresult') }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
        .and output(/@@\[command\]/).to_stdout
    end

    it 'propagates the exit status of a real failing shell command' do
      _out, _err, error = capture_io { run_command("sh -c 'exit 5'") }
      expect(error).to be_a(SystemExit)
      expect(error.status).to eq(5)
    end

    it 'exits 127 when the executable does not exist' do
      _out, _err, error = capture_io { run_command('__csm487_no_such_command__') }
      expect(error).to be_a(SystemExit)
      expect(error.status).to eq(127)
    end

    it 'still logs the command before exiting' do
      stub_system(self) { 1 }
      out, _err, error = capture_io { run_command('xcresultparser -o xml bad.xcresult') }
      expect(error.status).to eq(1)
      expect(out).to eq("@@[command] xcresultparser -o xml bad.xcresult\n")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#convert_xml' do
  let(:commands) { [] }

  before { allow(self).to receive(:run_command) { |cmd| commands << cmd } }

  context 'positive path' do
    it 'composes the xml command without coverage' do
      capture_io { convert_xml('xml', '/tmp/Test.xcresult', '/tmp/out', 'test_results', 'No') }
      expect(commands).to eq(['xcresultparser -o xml /tmp/Test.xcresult > /tmp/out/test_results.xml'])
    end

    it 'composes the html command' do
      capture_io { convert_xml('html', '/tmp/Test.xcresult', '/tmp/out', 'report', 'No') }
      expect(commands).to eq(['xcresultparser -o html /tmp/Test.xcresult > /tmp/out/report.html'])
    end

    it "appends ' --coverage' when include_coverage is 'Yes'" do
      capture_io { convert_xml('xml', '/tmp/Test.xcresult', '/tmp/out', 'test_results', 'Yes') }
      expect(commands).to eq(['xcresultparser -o xml /tmp/Test.xcresult > /tmp/out/test_results.xml --coverage'])
    end

    it 'runs exactly one command' do
      capture_io { convert_xml('xml', '/tmp/Test.xcresult', '/tmp/out', 'test_results', 'Yes') }
      expect(commands.size).to eq(1)
    end

    it 'prints the start and success messages' do
      out, _err, _error = capture_io { convert_xml('html', '/tmp/T.xcresult', '/tmp/out', 'r', 'No') }
      expect(out).to include('xcresult converting to html')
      expect(out).to include("/tmp/T.xcresult converted successfuly to html\n Exported to /tmp/out/r.html")
    end
  end

  context 'negative path' do
    ['No', 'yes', 'YES', '', nil].each do |value|
      it "does not add --coverage when include_coverage is #{value.inspect}" do
        capture_io { convert_xml('xml', '/tmp/Test.xcresult', '/tmp/out', 'test_results', value) }
        expect(commands.first).not_to include('--coverage')
      end
    end

    it 'propagates the exit when the conversion command fails and skips the success message' do
      allow(self).to receive(:run_command).and_raise(SystemExit.new(65))
      out, _err, error = capture_io { convert_xml('xml', '/tmp/Test.xcresult', '/tmp/out', 'test_results', 'No') }
      expect(error.status).to eq(65)
      expect(out).to include('xcresult converting to xml')
      expect(out).not_to include('converted successfuly')
    end

    it 'does not quote paths containing spaces (current behaviour pinned)' do
      capture_io { convert_xml('xml', '/tmp/My Tests.xcresult', '/tmp/out dir', 'test_results', 'No') }
      expect(commands.first).to eq('xcresultparser -o xml /tmp/My Tests.xcresult > /tmp/out dir/test_results.xml')
    end

    it 'interpolates nil arguments as empty strings (current behaviour pinned)' do
      capture_io { convert_xml(nil, '/tmp/Test.xcresult', nil, nil, nil) }
      expect(commands.first).to eq('xcresultparser -o  /tmp/Test.xcresult > /.')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#install_xcresultparser' do
  let(:tmpdir)      { Dir.mktmpdir('xcresultparser_install') }
  let(:home)        { File.join(tmpdir, 'home') }
  let(:install_dir) { File.join(home, 'xcresultparser', XCRESULTPARSER_VERSION) }
  let(:base_url)    { 'https://mirror.example.com/xcresultparser' }
  let(:commands)    { [] }

  around do |example|
    old_path = ENV['PATH']
    Dir.chdir(tmpdir) { example.run }
  ensure
    ENV['PATH'] = old_path
    FileUtils.rm_rf(tmpdir)
  end

  before do
    FileUtils.mkdir_p(home)
    allow(Dir).to receive(:home).and_return(home)
  end

  def stub_which(found)
    allow(self).to receive(:system).with(WHICH_COMMAND).and_return(found)
  end

  # Records commands; `curl` drops a fake archive in the cwd like the real one would.
  def stub_run_command(fail_on: nil)
    allow(self).to receive(:run_command) do |cmd|
      commands << cmd
      raise SystemExit.new(22) if fail_on && cmd.start_with?(fail_on)

      File.write('xcresultparser.zip', 'fake archive') if cmd.start_with?('curl')
    end
  end

  context 'positive path' do
    it 'skips the download when xcresultparser is already on PATH' do
      stub_which(true)
      stub_run_command
      path_before = ENV['PATH']
      out, _err, error = capture_io { install_xcresultparser(base_url) }
      expect(error).to be_nil
      expect(out).to include('xcresultparser is already installed, skipping download.')
      expect(commands).to be_empty
      expect(ENV['PATH']).to eq(path_before)
    end

    it 'reuses a previously installed binary without downloading and prepends it to PATH' do
      stub_which(false)
      stub_run_command
      FileUtils.mkdir_p(File.join(install_dir, 'product'))
      FileUtils.touch(File.join(install_dir, 'product', 'xcresultparser'))
      path_before = ENV['PATH']
      capture_io { install_xcresultparser(base_url) }
      expect(commands).to be_empty
      expect(ENV['PATH']).to eq("#{install_dir}/product:#{path_before}")
    end

    it 'downloads, verifies, extracts the pinned release and prepends it to PATH' do
      stub_which(false)
      stub_run_command
      stub_checksum(XCRESULTPARSER_SHA256)
      path_before = ENV['PATH']
      out, _err, error = capture_io { install_xcresultparser(base_url) }
      expect(error).to be_nil
      expect(commands).to eq([
        "curl -fsSL --retry 3 -o xcresultparser.zip #{base_url}/#{XCRESULTPARSER_VERSION}/xcresultparser.zip",
        "ditto -x -k xcresultparser.zip #{install_dir}"
      ])
      expect(out).to include("Downloading xcresultparser #{XCRESULTPARSER_VERSION} from #{base_url}/#{XCRESULTPARSER_VERSION}/xcresultparser.zip")
      expect(out).to include("Checksum verified: #{XCRESULTPARSER_SHA256}")
      expect(Dir.exist?(install_dir)).to be(true)
      expect(File.exist?('xcresultparser.zip')).to be(false)
      expect(ENV['PATH']).to eq("#{install_dir}/product:#{path_before}")
    end

    it 'pins version 2.2.0 and a 64-char SHA-256' do
      expect(XCRESULTPARSER_VERSION).to eq('2.2.0')
      expect(XCRESULTPARSER_SHA256).to match(/\A\h{64}\z/)
    end
  end

  context 'negative path' do
    before { stub_which(false) }

    it 'aborts on a checksum mismatch before extracting' do
      stub_run_command
      path_before = ENV['PATH']
      expected = Digest::SHA256.hexdigest('fake archive')
      _out, err, error = capture_io { install_xcresultparser(base_url) }
      expect(error).to be_a(SystemExit)
      expect(error.status).to eq(1)
      expect(err).to include("Checksum mismatch for xcresultparser.zip: expected #{XCRESULTPARSER_SHA256}, got #{expected}")
      expect(commands.none? { |c| c.start_with?('ditto') }).to be(true)
      expect(Dir.exist?(install_dir)).to be(false)
      expect(ENV['PATH']).to eq(path_before)
    end

    it 'propagates a failed download and never verifies or extracts' do
      stub_run_command(fail_on: 'curl')
      expect(Digest::SHA256).not_to receive(:file)
      _out, _err, error = capture_io { install_xcresultparser(base_url) }
      expect(error.status).to eq(22)
      expect(commands.size).to eq(1)
    end

    it 'propagates a failed extraction and leaves PATH untouched' do
      stub_run_command(fail_on: 'ditto')
      stub_checksum(XCRESULTPARSER_SHA256)
      path_before = ENV['PATH']
      _out, _err, error = capture_io { install_xcresultparser(base_url) }
      expect(error.status).to eq(22)
      expect(ENV['PATH']).to eq(path_before)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'step execution (in-process)' do
  let(:tmpdir)      { Dir.mktmpdir('xcresult_step') }
  let(:home)        { File.join(tmpdir, 'home') }
  let(:output_dir)  { File.join(tmpdir, 'out') }
  let(:result_path) { File.join(tmpdir, 'Test.xcresult') }
  let(:env_file)    { File.join(tmpdir, 'env_file') }
  let(:commands)    { [] }
  let(:base_env) do
    {
      'AC_OUTPUT_DIR'        => output_dir,
      'AC_TEST_RESULT_PATH'  => result_path,
      'AC_CONVERT_TYPE'      => 'xml',
      'AC_CONVERT_FILE_NAME' => 'test_results',
      'AC_INCLUDE_COVERAGE'  => 'No',
      'AC_ENV_FILE_PATH'     => env_file
    }
  end
  let(:convert_cmd) { "xcresultparser -o xml #{result_path} > #{output_dir}/test_results.xml" }

  around do |example|
    Dir.chdir(tmpdir) { example.run }
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  before do
    FileUtils.mkdir_p(home)
    allow(Dir).to receive(:home).and_return(home)
  end

  # xcresultparser is "on PATH" unless `installed: false`; the converter exits with `convert_exit`.
  def stub_step_commands(installed: true, convert_exit: 0)
    stub_system(MAIN_OBJECT, recorder: commands) do |cmd|
      if cmd == WHICH_COMMAND
        installed ? 0 : 1
      elsif cmd.start_with?('xcresultparser')
        convert_exit
      else
        0
      end
    end
  end

  context 'positive path' do
    it 'writes AC_CONVERTED_TEST_RESULT_PATH and converts with the composed command' do
      stub_step_commands
      out, _err, error = run_step(base_env)
      expect(error).to be_nil
      expect(commands).to eq([WHICH_COMMAND, convert_cmd])
      expect(File.read(env_file)).to eq("AC_CONVERTED_TEST_RESULT_PATH=#{output_dir}/test_results.xml\n")
      expect(out).to include('xcresultparser is already installed, skipping download.')
      expect(out).to include("converted successfuly to xml\n Exported to #{output_dir}/test_results.xml")
    end

    it 'appends to an existing env file' do
      stub_step_commands
      File.write(env_file, "EXISTING=1\n")
      run_step(base_env)
      expect(File.read(env_file)).to eq("EXISTING=1\nAC_CONVERTED_TEST_RESULT_PATH=#{output_dir}/test_results.xml\n")
    end

    it 'converts to html with coverage' do
      stub_step_commands
      run_step(base_env.merge('AC_CONVERT_TYPE' => 'html', 'AC_CONVERT_FILE_NAME' => 'report', 'AC_INCLUDE_COVERAGE' => 'Yes'))
      expect(commands.last).to eq("xcresultparser -o html #{result_path} > #{output_dir}/report.html --coverage")
      expect(File.read(env_file)).to eq("AC_CONVERTED_TEST_RESULT_PATH=#{output_dir}/report.html\n")
    end

    it 'downloads from the default GitHub release URL when AC_XCRESULTPARSER_BASE_URL is unset' do
      stub_step_commands(installed: false)
      stub_checksum(XCRESULTPARSER_SHA256)
      _out, _err, error = run_step(base_env)
      expect(error).to be_nil
      expect(commands).to include("curl -fsSL --retry 3 -o xcresultparser.zip #{DEFAULT_BASE_URL}/2.2.0/xcresultparser.zip")
      expect(commands.last).to eq(convert_cmd)
    end

    it 'strips a trailing slash from AC_XCRESULTPARSER_BASE_URL' do
      stub_step_commands(installed: false)
      stub_checksum(XCRESULTPARSER_SHA256)
      run_step(base_env.merge('AC_XCRESULTPARSER_BASE_URL' => 'https://mirror.example.com/xcp/'))
      expect(commands).to include('curl -fsSL --retry 3 -o xcresultparser.zip https://mirror.example.com/xcp/2.2.0/xcresultparser.zip')
    end

    it 'falls back to the default URL when AC_XCRESULTPARSER_BASE_URL is empty' do
      stub_step_commands(installed: false)
      stub_checksum(XCRESULTPARSER_SHA256)
      run_step(base_env.merge('AC_XCRESULTPARSER_BASE_URL' => ''))
      expect(commands).to include("curl -fsSL --retry 3 -o xcresultparser.zip #{DEFAULT_BASE_URL}/2.2.0/xcresultparser.zip")
    end
  end

  context 'negative path – AC_TEST_RESULT_PATH' do
    before { stub_step_commands }

    ['/tmp/results.zip', '/tmp/Test.xcresult.json', '/tmp/xcresult'].each do |path|
      it "exits 0 without converting when the extension of #{path} is not .xcresult" do
        out, _err, error = run_step(base_env.merge('AC_TEST_RESULT_PATH' => path))
        expect(error.status).to eq(0)
        expect(out).to include('Test result extension must be xcresult.')
        expect(commands).to be_empty
        expect(File.exist?(env_file)).to be(false)
      end
    end

    it 'raises TypeError when missing (current behaviour pinned)' do
      expect { run_step(base_env.reject { |k, _| k == 'AC_TEST_RESULT_PATH' }) }.to raise_error(TypeError)
      expect(commands).to be_empty
    end

    it 'raises TypeError when empty, since env_has_key maps it to nil (current behaviour pinned)' do
      expect { run_step(base_env.merge('AC_TEST_RESULT_PATH' => '')) }.to raise_error(TypeError)
      expect(commands).to be_empty
    end
  end

  context 'negative path – AC_ENV_FILE_PATH' do
    before { stub_step_commands }

    it 'raises TypeError and runs no command when missing' do
      expect { run_step(base_env.reject { |k, _| k == 'AC_ENV_FILE_PATH' }) }.to raise_error(TypeError)
      expect(commands).to be_empty
    end

    it 'raises Errno::ENOENT and runs no command when empty' do
      expect { run_step(base_env.merge('AC_ENV_FILE_PATH' => '')) }.to raise_error(Errno::ENOENT)
      expect(commands).to be_empty
    end

    it 'raises Errno::ENOENT when its directory does not exist' do
      expect { run_step(base_env.merge('AC_ENV_FILE_PATH' => File.join(tmpdir, 'missing', 'env'))) }
        .to raise_error(Errno::ENOENT)
    end
  end

  context 'negative path – toolchain failures' do
    it 'exits with the converter exit status' do
      stub_step_commands(convert_exit: 70)
      out, _err, error = run_step(base_env)
      expect(error.status).to eq(70)
      expect(out).not_to include('converted successfuly')
    end

    it 'has already written the env file when the converter fails (current behaviour pinned)' do
      stub_step_commands(convert_exit: 70)
      run_step(base_env)
      expect(File.read(env_file)).to include('AC_CONVERTED_TEST_RESULT_PATH=')
    end

    it 'aborts on a checksum mismatch and never runs the converter' do
      stub_step_commands(installed: false)
      stub_checksum('0' * 64)
      _out, err, error = run_step(base_env)
      expect(error.status).to eq(1)
      expect(err).to include('Checksum mismatch for xcresultparser.zip')
      expect(commands.none? { |c| c.start_with?('xcresultparser') }).to be(true)
    end

    it 'exits with the curl exit status when the download fails' do
      stub_system(MAIN_OBJECT, recorder: commands) { |cmd| cmd.start_with?('curl') ? 22 : (cmd == WHICH_COMMAND ? 1 : 0) }
      _out, _err, error = run_step(base_env)
      expect(error.status).to eq(22)
      expect(commands.none? { |c| c.start_with?('xcresultparser') }).to be(true)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess)' do
  let(:tmpdir)      { Dir.mktmpdir('xcresult_env') }
  let(:bin_dir)     { write_fake_xcresultparser(File.join(tmpdir, 'bin')) }
  let(:tool_log)    { File.join(tmpdir, 'tool.log') }
  let(:env_file)    { File.join(tmpdir, 'env_file') }
  let(:output_dir)  { FileUtils.mkdir_p(File.join(tmpdir, 'out')).first }
  let(:result_path) { File.join(tmpdir, 'Test.xcresult') }
  let(:base_env) do
    {
      'PATH'                 => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}",
      'HOME'                 => tmpdir,
      'FAKE_TOOL_LOG'        => tool_log,
      'AC_OUTPUT_DIR'        => output_dir,
      'AC_TEST_RESULT_PATH'  => result_path,
      'AC_CONVERT_TYPE'      => 'xml',
      'AC_CONVERT_FILE_NAME' => 'test_results',
      'AC_INCLUDE_COVERAGE'  => 'No'
    }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def tool_calls
    File.exist?(tool_log) ? File.read(tool_log).lines.map(&:chomp) : []
  end

  shared_examples 'aborts with message' do |env_override, expected_pattern|
    it "exits non-zero and stderr matches /#{expected_pattern.source}/" do
      env = instance_exec(&env_override)
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(expected_pattern)
      expect(tool_calls).to be_empty
    end
  end

  context 'required variable: AC_ENV_FILE_PATH' do
    context 'when missing' do
      include_examples 'aborts with message', -> { base_env }, /no implicit conversion of nil into String/
    end

    context 'when an empty string' do
      include_examples 'aborts with message', -> { base_env.merge('AC_ENV_FILE_PATH' => '') },
                       /No such file or directory/
    end
  end

  context 'AC_TEST_RESULT_PATH' do
    context 'when missing' do
      include_examples 'aborts with message',
                       -> { base_env.reject { |k, _| k == 'AC_TEST_RESULT_PATH' }.merge('AC_ENV_FILE_PATH' => env_file) },
                       /no implicit conversion of nil into String/
    end

    it 'exits 0 without converting when the extension is not .xcresult' do
      out, _err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file, 'AC_TEST_RESULT_PATH' => '/tmp/results.zip'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Test result extension must be xcresult.')
      expect(tool_calls).to be_empty
      expect(File.exist?(env_file)).to be(false)
    end
  end

  context 'converter failure' do
    it 'exits with the xcresultparser exit status and prints its error' do
      _out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file, 'FAKE_XCRESULTPARSER_FAIL' => '1'))
      expect(status.exitstatus).to eq(3)
      expect(err).to include('xcresultparser: error: invalid xcresult bundle')
    end
  end

  context 'all variables set' do
    it 'converts to xml, writes the output file and AC_CONVERTED_TEST_RESULT_PATH, exits 0' do
      out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file))
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
      expect(tool_calls).to eq(["xcresultparser -o xml #{result_path}"])
      expect(out).to include('xcresultparser is already installed, skipping download.')
      expect(out).to include("@@[command] xcresultparser -o xml #{result_path} > #{output_dir}/test_results.xml")
      expect(File.read(File.join(output_dir, 'test_results.xml'))).to eq("<testsuites name=\"fake\"/>\n")
      expect(File.read(env_file)).to eq("AC_CONVERTED_TEST_RESULT_PATH=#{output_dir}/test_results.xml\n")
    end

    it 'passes --coverage to xcresultparser when AC_INCLUDE_COVERAGE is Yes' do
      _out, _err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file, 'AC_CONVERT_TYPE' => 'html',
                                                    'AC_INCLUDE_COVERAGE' => 'Yes'))
      expect(status.exitstatus).to eq(0)
      expect(tool_calls).to eq(["xcresultparser -o html #{result_path} --coverage"])
      expect(File.exist?(File.join(output_dir, 'test_results.html'))).to be(true)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'loading main.rb' do
  it 'does not execute the step when required from another script' do
    out, err, status = Open3.capture3(STEP_ENV_KEYS.to_h { |k| [k, nil] },
                                      "ruby -e 'require %q(#{MAIN_RB}); puts :loaded'")
    expect(status.exitstatus).to eq(0)
    expect(err).to eq('')
    expect(out.strip).to eq('loaded')
  end

  it 'defines env_has_key, run_command, convert_xml and install_xcresultparser' do
    %i[env_has_key run_command convert_xml install_xcresultparser].each do |name|
      expect(respond_to?(name, true)).to be(true)
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = COVERAGE_SNAPSHOTS.reduce(result[main_path]) do |acc, snap|
    acc.zip(snap).map { |a, b| a.nil? ? nil : a + b.to_i }
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
