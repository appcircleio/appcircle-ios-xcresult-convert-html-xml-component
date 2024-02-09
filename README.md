# Appcircle Xcresult Convert XML/HTML Component

This component parses test and coverage results into a single file. This component currently supports the following test and coverage formats:

## Test Format

- Xcode 13+ `.xctest`

## Required Inputs

- `AC_OUTPUT_DIR`: Specifies the path for outputs. Conversion results will be stored in this path.
- `AC_TEST_RESULT_PATH`: Test result path. This directory and its subdirectories will be searched for compatible test files. This environment variable is automatically set if you use Appcircle's test component.
- `AC_CONVERT_FILE_NAME`: The name of the converted file. You can give a specific name. The default name is `test_results`.
- `AC_CONVERT_TYPE`: This is the conversion type. Xcresult can be converted to HTML or XML.

## Output

- `AC_CONVERTED_TEST_RESULT_PATH`: The component creates a single file that contains the test results in the converted extension.
