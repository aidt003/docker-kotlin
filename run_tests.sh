#!/usr/bin/env bash
# run_tests.sh - Script to validate the codebase and generate APKs
#
# This script runs INSIDE the Docker container and does three things:
# 1. Runs unit tests (if any exist)
# 2. Builds the debug APK
# 3. Builds the instrumented test APK
#
# All tasks run offline using cached dependencies from the Docker build.

# ===== 🚨 CUSTOMIZE FOR YOUR PROJECT 🚨 =====
# If your project has product flavors, set FLAVOR (e.g., "Demo", "Prod")
# If no flavors, leave empty
FLAVOR=""

# If your main/application module has a different name, change this
MODULE_NAME="app"
# =====================================

set -euo pipefail

cd /workspace

echo "==> Running unit tests..."
./gradlew test${FLAVOR}DebugUnitTest --no-daemon --offline

echo ""
echo "==> Building debug APK..."
./gradlew assemble${FLAVOR}Debug --no-daemon --offline

echo ""
echo "==> Building test APK..."
./gradlew assemble${FLAVOR}DebugAndroidTest --no-daemon --offline

echo ""
echo "==> 📊 Unit Test Results Summary: (unit tests only)"
echo ""

# Find JUnit XMLs for unit tests across variants (e.g., testDebugUnitTest, testReleaseUnitTest)
UNIT_RESULTS=$(find /workspace -type f \
  \( -path "*/build/test-results/test*/TEST-*.xml" \
   -o -path "*/build/test-results/*UnitTest/TEST-*.xml" \) 2>/dev/null || true)

if [ -n "$UNIT_RESULTS" ]; then
  echo "$UNIT_RESULTS" | while read -r result_file; do
    # Module path between /workspace/ and /build/... (keeps nested modules like app/feature-x)
    MODULE=$(echo "$result_file" | sed -E 's#.*/workspace/([^/].*)/build/.*#\1#')

    # Class name from filename: TEST-com.example.MyTest.xml -> com.example.MyTest -> MyTest
    BASENAME=$(basename "$result_file")
    FQCN="${BASENAME#TEST-}"
    FQCN="${FQCN%.xml}"

    # Fallback if filename isn't standard: first <testcase classname="...">
    if ! echo "$FQCN" | grep -q '\.' ; then
      FIRST_CLASS=$(grep -o 'classname="[^"]*"' "$result_file" 2>/dev/null | head -1 | cut -d'"' -f2)
      [ -n "$FIRST_CLASS" ] && FQCN="$FIRST_CLASS"
    fi
    CLASS_NAME="${FQCN##*.}"

    # Stats from the <testsuite ...> line
    SUITE_LINE=$(grep '<testsuite' "$result_file" 2>/dev/null | head -1)
    TESTS=$(echo "$SUITE_LINE"    | sed -n 's/.*tests="\([^"]*\)".*/\1/p')
    FAILURES=$(echo "$SUITE_LINE" | sed -n 's/.*failures="\([^"]*\)".*/\1/p')
    ERRORS=$(echo "$SUITE_LINE"   | sed -n 's/.*errors="\([^"]*\)".*/\1/p')
    TIME=$(echo "$SUITE_LINE"     | sed -n 's/.*time="\([^"]*\)".*/\1/p' | cut -d'.' -f1)

    # Status
    if [ "${FAILURES:-0}" = "0" ] && [ "${ERRORS:-0}" = "0" ]; then
      STATUS="✅ PASSED"
    else
      STATUS="❌ FAILED"
    fi

    printf "%s | %s | %s\n" "$STATUS" "$MODULE" "$CLASS_NAME"
    printf "   Tests: %s | Failures: %s | Errors: %s | Time: %ss\n\n" \
           "${TESTS:-0}" "${FAILURES:-0}" "${ERRORS:-0}" "${TIME:-0}"
  done
else
  echo "⚠️  No unit test results found"
fi

echo ""
echo "==> Build complete! APK locations:"
echo ""

# Find main app debug APK using MODULE_NAME
DEBUG_APK=$(find . -path "*/${MODULE_NAME}/build/outputs/apk/*/debug/*.apk" \
                -o -path "*/${MODULE_NAME}/build/outputs/apk/debug/*.apk" 2>/dev/null | \
            grep -v "androidTest" | grep -v "catalog" | head -1)

# Find test APK using MODULE_NAME
TEST_APK=$(find . -path "*/${MODULE_NAME}/build/outputs/apk/androidTest/*/debug/*-androidTest.apk" \
                -o -path "*/${MODULE_NAME}/build/outputs/apk/androidTest/debug/*-androidTest.apk" 2>/dev/null | \
           head -1)

# Strip leading "./" from the paths (no-op if not present)
CLEAN_DEBUG_APK=${DEBUG_APK#./}
CLEAN_TEST_APK=${TEST_APK#./}

if [ -n "$CLEAN_DEBUG_APK" ]; then
  printf '📦 Debug APK: %s\n' "$CLEAN_DEBUG_APK"
else
  echo "⚠️  Debug APK: Not found"
fi

echo ""

if [ -n "$CLEAN_TEST_APK" ]; then
  printf '📦 Test APK: %s\n' "$CLEAN_TEST_APK"
else
  echo "⚠️  Test APK: Not found"
fi

echo ""
echo "==> Generating ADB Commands:"
echo ""

# Find aapt tool
AAPT=$(find /opt/android-sdk/build-tools -name "aapt" -type f 2>/dev/null | head -1)

if [ -z "$AAPT" ]; then
    echo "⚠️  aapt not found, cannot auto-generate ADB commands"
else
    # Extract app info
    if [ -n "$DEBUG_APK" ]; then
        echo "🔹 Launch App Command:"
        
        APP_PACKAGE=$($AAPT dump badging "$DEBUG_APK" 2>/dev/null | \
                    grep "^package: name=" | \
                    sed "s/^package: name='\([^']*\)'.*/\1/" | head -1)
        LAUNCHER_ACTIVITY=$($AAPT dump badging "$DEBUG_APK" 2>/dev/null | \
                            grep "launchable-activity: name=" | \
                            sed "s/.*launchable-activity: name='\([^']*\)'.*/\1/" | head -1)
        
        if [ -n "$APP_PACKAGE" ] && [ -n "$LAUNCHER_ACTIVITY" ]; then
            APP_COMPONENT="$APP_PACKAGE/$LAUNCHER_ACTIVITY"
            printf -v Q_APP_COMPONENT '%q' "$APP_COMPONENT"
            echo "  adb shell am start -n $Q_APP_COMPONENT"
        else
            echo "  ⚠️  Could not extract launch info"
        fi
        echo ""
    fi

    # Extract test info
    if [ -n "$TEST_APK" ]; then
        echo "🔹 Run Instrumented Tests Command:"
        
        # Get test package from badging
        TEST_PACKAGE=$($AAPT dump badging "$TEST_APK" 2>/dev/null | \
                    grep "^package: name=" | \
                    sed "s/^package: name='\([^']*\)'.*/\1/" | head -1)
        
        # Get test runner from xmltree (more reliable than badging)
        TEST_RUNNER=$($AAPT dump xmltree "$TEST_APK" AndroidManifest.xml 2>/dev/null | \
                    grep -A 2 "E: instrumentation" | \
                    grep "A: android:name" | \
                    head -1 | \
                    sed 's/.*Raw: "\([^"]*\)".*/\1/')
        
        if [ -n "$TEST_PACKAGE" ] && [ -n "$TEST_RUNNER" ]; then
            TEST_COMPONENT="$TEST_PACKAGE/$TEST_RUNNER"
            printf -v Q_TEST_COMPONENT '%q' "$TEST_COMPONENT"
            echo "  adb shell am instrument -w $Q_TEST_COMPONENT"
        else
            echo "  ⚠️  Could not extract test runner info"
            echo "  Test package: ${TEST_PACKAGE:-unknown}"
            FALLBACK_COMPONENT="${TEST_PACKAGE:-PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"
            printf -v Q_FALLBACK_COMPONENT '%q' "$FALLBACK_COMPONENT"
            echo "  Try: adb shell am instrument -w $Q_FALLBACK_COMPONENT"
        fi
        echo ""
    fi
fi

echo "==> 📋 Next Steps to Run Instrumented Tests:"
echo ""

if [ -n "$DEBUG_APK" ] && [ -n "$TEST_APK" ]; then
    DEBUG_BASENAME=$(basename "$DEBUG_APK")
    TEST_BASENAME=$(basename "$TEST_APK")
    
    # Pre-escape paths and names for safe shell copy/paste
    printf -v Q_DEBUG_APK '%q' "$DEBUG_APK"
    printf -v Q_TEST_APK '%q' "$TEST_APK"
    printf -v Q_DEBUG_BASENAME '%q' "$DEBUG_BASENAME"
    printf -v Q_TEST_BASENAME '%q' "$TEST_BASENAME"
    
    echo "1. Extract APKs from Docker:"
    echo "  (Replace IMAGE_NAME with the name of your Docker image)"
    echo "    mkdir -p apks"
    echo "    docker run --rm --platform linux/amd64 -v \"\$(pwd)/apks:/apks\" IMAGE_NAME bash -c \\"
    echo "      \"cp $Q_DEBUG_APK /apks/ && cp $Q_TEST_APK /apks/\""
    echo ""
    
    echo "2. Uninstall existing APK versions (if present):"
    if [ -n "$APP_PACKAGE" ]; then
        printf -v Q_APP_PACKAGE '%q' "$APP_PACKAGE"
        echo "    adb uninstall $Q_APP_PACKAGE || true"
        if [ -n "$TEST_PACKAGE" ]; then
            printf -v Q_TEST_PACKAGE '%q' "$TEST_PACKAGE"
            echo "    adb uninstall $Q_TEST_PACKAGE || true"
        fi
    else
        echo "    adb uninstall YOUR_PACKAGE || true"
        echo "    adb uninstall YOUR_PACKAGE.test || true"
    fi
    echo ""
    
    echo "3. Install APKs:"
    echo "    cd apks"
    echo "    adb install $Q_DEBUG_BASENAME"
    echo "    adb install $Q_TEST_BASENAME"
    echo ""
    
    echo "4. Run instrumented tests:"
    if [ -n "$TEST_PACKAGE" ] && [ -n "$TEST_RUNNER" ]; then
        TEST_COMPONENT="$TEST_PACKAGE/$TEST_RUNNER"
        printf -v Q_TEST_COMPONENT2 '%q' "$TEST_COMPONENT"
        echo "    adb shell am instrument -w $Q_TEST_COMPONENT2"
    else
        echo "    adb shell am instrument -w TEST_PACKAGE/TEST_RUNNER"
    fi
    echo ""
    
    echo "5. (Optional) Launch app:"
    if [ -n "$APP_PACKAGE" ] && [ -n "$LAUNCHER_ACTIVITY" ]; then
        APP_COMPONENT2="$APP_PACKAGE/$LAUNCHER_ACTIVITY"
        printf -v Q_APP_COMPONENT2 '%q' "$APP_COMPONENT2"
        echo "    adb shell am start -n $Q_APP_COMPONENT2"
    else
        echo "    adb shell am start -n PACKAGE/.MainActivity"
    fi
fi

echo ""
echo "✔️ All steps completed!"
echo ""
