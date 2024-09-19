#!/bin/bash -u

set -o pipefail

# Test that the mk and ninja files generated by Soong don't change if some
# incremental modules are restored from cache.

OUTPUT_DIR="$(mktemp -d tmp.XXXXXX)"
echo ${OUTPUT_DIR}

function cleanup {
  rm -rf "${OUTPUT_DIR}"
}
trap cleanup EXIT

function run_soong_build {
  USE_RBE=false TARGET_PRODUCT=aosp_arm TARGET_RELEASE=trunk_staging TARGET_BUILD_VARIANT=userdebug build/soong/soong_ui.bash --make-mode --incremental-build-actions nothing
}

function run_soong_clean {
  build/soong/soong_ui.bash --make-mode clean
}

function assert_files_equal {
  if [ $# -ne 2 ]; then
    echo "Usage: assert_files_equal file1 file2"
    exit 1
  fi

  if ! cmp -s "$1" "$2"; then
    echo "Files are different: $1 $2"
    exit 1
  fi
}

function compare_mtimes() {
  if [ $# -ne 2 ]; then
    echo "Usage: compare_mtimes file1 file2"
    exit 1
  fi

  file1_mtime=$(stat -c '%Y' $1)
  file2_mtime=$(stat -c '%Y' $2)

  if [ "$file1_mtime" -eq "$file2_mtime" ]; then
      return 1
  else
      return 0
  fi
}

function test_build_action_restoring() {
  run_soong_clean
  cat > ${OUTPUT_DIR}/Android.bp <<'EOF'
python_binary_host {
  name: "my_little_binary_host",
  srcs: ["my_little_binary_host.py"],
}
EOF
  touch ${OUTPUT_DIR}/my_little_binary_host.py
  run_soong_build
  mkdir -p "${OUTPUT_DIR}/before"
  cp -pr out/soong/build_aosp_arm_ninja_incremental out/soong/*.mk out/soong/build.aosp_arm.*.ninja ${OUTPUT_DIR}/before
  # add a comment to the bp file, this should force a new analysis but no module
  # should be really impacted, so all the incremental modules should be skipped.
  cat >> ${OUTPUT_DIR}/Android.bp <<'EOF'
// new comments
EOF
  run_soong_build
  mkdir -p "${OUTPUT_DIR}/after"
  cp -pr out/soong/build_aosp_arm_ninja_incremental out/soong/*.mk out/soong/build.aosp_arm.*.ninja ${OUTPUT_DIR}/after

  compare_files
  echo "Tests passed"
}

function compare_files() {
  count=0
  for file_before in ${OUTPUT_DIR}/before/*.ninja; do
    file_after="${OUTPUT_DIR}/after/$(basename "$file_before")"
    assert_files_equal $file_before $file_after
    compare_mtimes $file_before $file_after
    if [ $? -ne 0 ]; then
      echo "Files have identical mtime: $file_before $file_after"
      exit 1
    fi
    ((count++))
  done
  echo "Compared $count ninja files"

  count=0
  for file_before in ${OUTPUT_DIR}/before/*.mk; do
    file_after="${OUTPUT_DIR}/after/$(basename "$file_before")"
    assert_files_equal $file_before $file_after
    compare_mtimes $file_before $file_after
    # mk files shouldn't be regenerated
    if [ $? -ne 1 ]; then
      echo "Files have different mtimes: $file_before $file_after"
      exit 1
    fi
    ((count++))
  done
  echo "Compared $count mk files"

  count=0
  for file_before in ${OUTPUT_DIR}/before/build_aosp_arm_ninja_incremental/*.ninja; do
    file_after="${OUTPUT_DIR}/after/build_aosp_arm_ninja_incremental/$(basename "$file_before")"
    assert_files_equal $file_before $file_after
    compare_mtimes $file_before $file_after
    # ninja files of skipped modules shouldn't be regenerated
    if [ $? -ne 1 ]; then
      echo "Files have different mtimes: $file_before $file_after"
      exit 1
    fi
    ((count++))
  done
  echo "Compared $count incremental ninja files"
}

test_build_action_restoring
