# Appcircle Xcresult Convert XML/HTML Component

This component parses test and coverage results to single JSON file. This component currently supports following test and coverage formats

## Test Format

- Xcode 13+ `.xctest`

## Required Inputs

- `AC_TEST_RESULT_PATH`: Test result path. This directory and subdirectories will be searched for compatible test files. This envıronment variable is automatically set if you use Appcircle's test component

- `AC_CONVERT_FILE_NAME`: The name of the converted file. You can give a specific name. The default name is `test_results`.

- `AC_CONVERT_TYPE`: This is the convertion type. Xcresult can be converted to HTML or XML.

## Output

- `AC_CONVERTED_TEST_RESULT_PATH`: Component creates a single file which contains the test results in converted extension.
