#!/usr/bin/env bash

# For code formatting we have clang-format.
#
# But it's not sane to apply clang-format for whole code base,
#  because it sometimes makes worse for properly formatted files.
#
# It's only reasonable to blindly apply clang-format only in cases
#  when the code is likely to be out of style.
#
# For this purpose we have a script that will use very primitive heuristics
#  (simple regexps) to check if the code is likely to have basic style violations.
#  and then to run formatter only for the specified files.

LC_ALL="en_US.UTF-8"
ROOT_PATH="."
EXCLUDE='build/|integration/|widechar_width/|glibc-compatibility/|poco/|memcpy/|consistent-hashing|benchmark|tests/.*.cpp|programs/keeper-bench/example.yaml|base/base/openpty.h'
EXCLUDE_DOCS='Settings\.cpp|FormatFactorySettings\.h'

# From [1]:
#     But since array_to_string_internal() in array.c still loops over array
#     elements and concatenates them into a string, it's probably not more
#     efficient than the looping solutions proposed, but it's more readable.
#
#  [1]: https://stackoverflow.com/a/15394738/328260
function in_array()
{
    local IFS="|"
    local value=$1 && shift

    [[ "${IFS}${*}${IFS}" =~ "${IFS}${value}${IFS}" ]]
}

find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' 2>/dev/null |
    grep -vP $EXCLUDE |
    grep -v 'src/Storages/System/StorageSystemDashboards.cpp' |
    grep -vP $EXCLUDE_DOCS |
    xargs grep $@ -P '((class|struct|namespace|enum|if|for|while|else|throw|switch).*|\)(\s*const)?(\s*override)?\s*)\{$|\s$|^ {1,3}[^\* ]\S|\t|^\s*(if|else if|if constexpr|else if constexpr|for|while|catch|switch)\(|\( [^\s\\]|\S \)' |
# a curly brace not in a new line, but not for the case of C++11 init or agg. initialization | trailing whitespace | number of ws not a multiple of 4, but not in the case of comment continuation | missing whitespace after for/if/while... before opening brace | whitespaces inside braces
    grep -v -P '(//|:\s+\*|\$\(\()| \)"' && echo "{ should be a new line"
# single-line comment | continuation of a multiline comment | a typical piece of embedded shell code | something like ending of raw string literal

# Tabs
find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' 2>/dev/null |
    grep -vP $EXCLUDE |
    xargs grep $@ -F $'\t' && echo '^ tabs are not allowed'

# // namespace comments are unneeded
result=$(find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' 2>/dev/null |
    grep -vP $EXCLUDE |
    xargs grep $@ -P '}\s*//+\s*namespace\s*' 2>/dev/null)

if [ -n "$result" ]; then
    echo "$result"
    echo "^ Found unnecessary namespace comments"
fi

# Broken symlinks
find -L $ROOT_PATH -type l 2>/dev/null | grep -v contrib && echo "^ Broken symlinks found"

# Duplicated or incorrect setting declarations
bash $ROOT_PATH/ci/jobs/scripts/check_style/check-settings-style

# Unused/Undefined/Duplicates ErrorCodes/ProfileEvents/CurrentMetrics
declare -A EXTERN_TYPES
EXTERN_TYPES[ErrorCodes]=int
EXTERN_TYPES[ProfileEvents]=Event
EXTERN_TYPES[CurrentMetrics]=Metric

EXTERN_TYPES_EXCLUDES=(
    ProfileEvents::global_counters
    ProfileEvents::Event
    ProfileEvents::Count
    ProfileEvents::Counters
    ProfileEvents::end
    ProfileEvents::increment
    ProfileEvents::incrementForLogMessage
    ProfileEvents::incrementLoggerElapsedNanoseconds
    ProfileEvents::getName
    ProfileEvents::Timer
    ProfileEvents::Type
    ProfileEvents::TypeEnum
    ProfileEvents::ValueType
    ProfileEvents::dumpToMapColumn
    ProfileEvents::getProfileEvents
    ProfileEvents::ThreadIdToCountersSnapshot
    ProfileEvents::LOCAL_NAME
    ProfileEvents::keeper_profile_events
    ProfileEvents::CountersIncrement
    ProfileEvents::size
    ProfileEvents::checkCPUOverload

    CurrentMetrics::add
    CurrentMetrics::sub
    CurrentMetrics::get
    CurrentMetrics::getDocumentation
    CurrentMetrics::getName
    CurrentMetrics::set
    CurrentMetrics::end
    CurrentMetrics::Increment
    CurrentMetrics::Metric
    CurrentMetrics::values
    CurrentMetrics::Value
    CurrentMetrics::keeper_metrics
    CurrentMetrics::size

    ErrorCodes::ErrorCode
    ErrorCodes::getName
    ErrorCodes::increment
    ErrorCodes::end
    ErrorCodes::extendedMessage
    ErrorCodes::values
    ErrorCodes::values[i]
    ErrorCodes::getErrorCodeByName
    ErrorCodes::Value
)
for extern_type in ${!EXTERN_TYPES[@]}; do
    type_of_extern=${EXTERN_TYPES[$extern_type]}
    allowed_chars='[_A-Za-z]+'

    # Unused
    # NOTE: to fix automatically, replace echo with:
    # sed -i "/extern const $type_of_extern $val/d" $file
    find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' | {
        # NOTE: the check is pretty dumb and distinguish only by the type_of_extern,
        # and this matches with zkutil::CreateMode
        grep -v -e 'src/Common/ZooKeeper/Types.h' -e 'src/Coordination/KeeperConstants.cpp'
    } | {
        grep -vP $EXCLUDE | xargs grep -l -P "extern const $type_of_extern $allowed_chars"
    } | while read file; do
        grep -P "extern const $type_of_extern $allowed_chars;" $file | sed -r -e "s/^.*?extern const $type_of_extern ($allowed_chars);.*?$/\1/" | while read val; do
            if ! grep -q "$extern_type::$val" $file; then
                # Excludes for SOFTWARE_EVENT/HARDWARE_EVENT/CACHE_EVENT in ThreadProfileEvents.cpp
                if [[ ! $extern_type::$val =~ ProfileEvents::Perf.* ]]; then
                    echo "$extern_type::$val is defined but not used in file $file"
                fi
            fi
        done
    done

    # Undefined
    # NOTE: to fix automatically, replace echo with:
    # ( grep -q -F 'namespace $extern_type' $file && \
    #   sed -i -r "0,/(\s*)extern const $type_of_extern [$allowed_chars]+/s//\1extern const $type_of_extern $val;\n&/" $file || \
    #     awk '{ print; if (ns == 1) { ns = 2 }; if (ns == 2) { ns = 0; print "namespace $extern_type\n{\n    extern const $type_of_extern '$val';\n}" } }; /namespace DB/ { ns = 1; };' < $file > ${file}.tmp && mv ${file}.tmp $file )
    find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' | {
        grep -vP $EXCLUDE | xargs grep -l -P "$extern_type::$allowed_chars"
    } | while read file; do
        grep -P "$extern_type::$allowed_chars" $file | grep -P -v '^\s*//' | sed -r -e "s/^.*?$extern_type::($allowed_chars).*?$/\1/" | while read val; do
            if ! grep -q "extern const $type_of_extern $val" $file; then
                if ! in_array "$extern_type::$val" "${EXTERN_TYPES_EXCLUDES[@]}"; then
                    echo "$extern_type::$val is used in file $file but not defined"
                fi
            fi
        done
    done

    # Duplicates
    find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' | {
        grep -vP $EXCLUDE | xargs grep -l -P "$extern_type::$allowed_chars"
    } | while read file; do
        grep -P "extern const $type_of_extern $allowed_chars;" $file | sort | uniq -c | grep -v -P ' +1 ' && echo "Duplicate $extern_type in file $file"
    done
done

# Three or more consecutive empty lines
find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    while read file; do awk '/^$/ { ++i; if (i > 2) { print "More than two consecutive empty lines in file '$file'" } } /./ { i = 0 }' $file; done

# Check that every header file has #pragma once in first line
find $ROOT_PATH/{src,programs,utils} -name '*.h' |
    grep -vP $EXCLUDE |
    while read file; do [[ $(head -n1 $file) != '#pragma once' ]] && echo "File $file must have '#pragma once' in first line"; done

# Too many exclamation marks
find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -F '!!!' | grep -P '.' && echo "Too many exclamation marks (looks dirty, unconfident)."

# Exclamation mark in a message
find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -F '!",' | grep -P '.' && echo "No need for an exclamation mark (looks dirty, unconfident)."

# Trailing whitespaces
find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -n -P ' $' | grep -n -P '.' && echo "^ Trailing whitespaces."

# Forbid stringstream because it's easy to use them incorrectly and hard to debug possible issues
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -P 'std::[io]?stringstream' | grep -v "STYLE_CHECK_ALLOW_STD_STRING_STREAM" && echo "Use WriteBufferFromOwnString or ReadBufferFromString instead of std::stringstream"

# Forbid std::cerr/std::cout in src (fine in programs/utils)
std_cerr_cout_excludes=(
    /examples/
    /tests/
    _fuzzer
    # OK
    base/base/ask.cpp
    src/Common/ProgressIndication.cpp
    src/Common/ProgressTable.cpp
    # only under #ifdef DBMS_HASH_MAP_DEBUG_RESIZES, that is used only in tests
    src/Common/HashTable/HashTable.h
    # SensitiveDataMasker::printStats()
    src/Common/SensitiveDataMasker.cpp
    # StreamStatistics::print()
    src/Compression/LZ4_decompress_faster.cpp
    # ContextSharedPart with subsequent std::terminate()
    src/Interpreters/Context.cpp
    # IProcessor::dump()
    src/Processors/IProcessor.cpp
    src/Client/ClientApplicationBase.cpp
    src/Client/ClientBase.cpp
    src/Common/ProgressIndication.h
    src/Client/LineReader.h
    src/Client/LineReader.cpp
    src/Client/ReplxxLineReader.h
    src/Client/QueryFuzzer.cpp
    src/Client/Suggest.cpp
    src/Client/ClientBase.h
    src/Client/LineReader.h
    src/Client/ReplxxLineReader.h
    src/Bridge/IBridge.cpp
    src/Daemon/BaseDaemon.cpp
    src/Loggers/Loggers.cpp
    src/Common/GWPAsan.cpp
    src/Common/ProgressIndication.h
    src/IO/Ask.cpp
)
sources_with_std_cerr_cout=( $(
    find $ROOT_PATH/{src,base} -name '*.h' -or -name '*.cpp' | \
        grep -vP $EXCLUDE | \
        grep -F -v $(printf -- "-e %s " "${std_cerr_cout_excludes[@]}") | \
        xargs grep -F --with-filename -e std::cerr -e std::cout | cut -d: -f1 | sort -u
) )
# Exclude comments
for src in "${sources_with_std_cerr_cout[@]}"; do
    # suppress stderr, since it may contain warning for #pragma once in headers
    if gcc -fpreprocessed -dD -E "$src" 2>/dev/null | grep -F -q -e std::cerr -e std::cout; then
        echo "$src: uses std::cerr/std::cout"
    fi
done

expect_tests=( $(find $ROOT_PATH/tests/queries -name '*.expect') )
for test_case in "${expect_tests[@]}"; do
    pattern="^exp_internal -f \$CLICKHOUSE_TMP/\$basename.debuglog 0$"
    grep -q "$pattern" "$test_case" || echo "Missing '$pattern' in '$test_case'"

    if grep -q "^spawn.*CLICKHOUSE_CLIENT_BINARY$" "$test_case"; then
        pattern="^spawn.*CLICKHOUSE_CLIENT_BINARY.*--history_file$"
        grep -q "$pattern" "$test_case" || echo "Missing '$pattern' in '$test_case'"
    fi

    # Otherwise expect_after/expect_before will not bail without stdin attached
    # (and actually this is a hack anyway, correct way is to use $any_spawn_id)
    pattern="-i \$any_spawn_id timeout"
    grep -q -- "$pattern" "$test_case" || echo "Missing '$pattern' in '$test_case'"
    pattern="-i \$any_spawn_id eof"
    grep -q -- "$pattern" "$test_case" || echo "Missing '$pattern' in '$test_case'"
done

# Forbid non-unique error codes
if [[ "$(grep -Po "M\([0-9]*," $ROOT_PATH/src/Common/ErrorCodes.cpp | wc -l)" != "$(grep -Po "M\([0-9]*," $ROOT_PATH/src/Common/ErrorCodes.cpp | sort | uniq | wc -l)" ]]
then
    echo "ErrorCodes.cpp contains non-unique error codes"
fi

# Check that there is no system-wide libraries/headers in use.
#
# NOTE: it is better to override find_path/find_library in cmake, but right now
# it is not possible, see [1] for the reference.
#
#   [1]: git grep --recurse-submodules -e find_library -e find_path contrib
if git grep -e find_path -e find_library -- :**CMakeLists.txt; then
    echo "There is find_path/find_library usage. ClickHouse should use everything bundled. Consider adding one more contrib module."
fi

# Forbid std::filesystem::is_symlink and std::filesystem::read_symlink, because it's easy to use them incorrectly
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -P '::(is|read)_symlink' | grep -v "STYLE_CHECK_ALLOW_STD_FS_SYMLINK" && echo "Use DB::FS::isSymlink and DB::FS::readSymlink instead"

# Forbid __builtin_unreachable(), because it's hard to debug when it becomes reachable
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -P '__builtin_unreachable' && echo "Use UNREACHABLE() from defines.h instead"

# Forbid mt19937() and random_device() which are outdated and slow
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -P '(std::mt19937|std::mersenne_twister_engine|std::random_device)' && echo "Use pcg64_fast (from pcg_random.h) and randomSeed (from Common/randomSeed.h) instead"

# Require checking return value of close(),
# since it can hide fd misuse and break other places.
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -e ' close(.*fd' -e ' ::close(' | grep -v = && echo "Return value of close() should be checked"

# A small typo can lead to debug code in release builds, see https://github.com/ClickHouse/ClickHouse/pull/47647
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' | xargs grep -l -F '#ifdef NDEBUG' | xargs -I@FILE awk '/#ifdef NDEBUG/ { inside = 1; dirty = 1 } /#endif/ { if (inside && dirty) { print "File @FILE has suspicious #ifdef NDEBUG, possibly confused with #ifndef NDEBUG" }; inside = 0 } /#else/ { dirty = 0 }' @FILE

# If a user is doing dynamic or typeid cast with a pointer, and immediately dereferencing it, it is unsafe.
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' | xargs grep --line-number -P '(dynamic|typeid)_cast<[^>]+\*>\([^\(\)]+\)->' | grep -P '.' && echo "It's suspicious when you are doing a dynamic_cast or typeid_cast with a pointer and immediately dereferencing it. Use references instead of pointers or check a pointer to nullptr."

# Check for bad punctuation: whitespace before comma.
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' | xargs grep -P --line-number '\w ,' | grep -v 'bad punctuation is ok here' && echo "^ There is bad punctuation: whitespace before comma. You should write it like this: 'Hello, world!'"

# Check usage of std::regex which is too bloated and slow.
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' | xargs grep -P --line-number 'std::regex' | grep -P '.' && echo "^ Please use re2 instead of std::regex"

# Cyrillic characters hiding inside Latin.
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' | grep -v StorageSystemContributors.generated.cpp | xargs grep -P --line-number '[a-zA-Z][а-яА-ЯёЁ]|[а-яА-ЯёЁ][a-zA-Z]' && echo "^ Cyrillic characters found in unexpected place."

# Orphaned header files.
join -v1 <(find $ROOT_PATH/{src,programs,utils} -name '*.h' -printf '%f\n' | sort | uniq) <(find $ROOT_PATH/{src,programs,utils,tests/lexer} -name '*.cpp' -or -name '*.c' -or -name '*.h' -or -name '*.S' | xargs grep --no-filename -o -P '[\w-]+\.h' | sort | uniq) |
    grep . && echo '^ Found orphan header files.'

# Don't allow dynamic compiler check with CMake, because we are using hermetic, reproducible, cross-compiled, static (TLDR, good) builds.
ls -1d $ROOT_PATH/contrib/*-cmake | xargs -I@ find @ -name 'CMakeLists.txt' -or -name '*.cmake' | xargs grep --with-filename -i -P 'check_c_compiler_flag|check_cxx_compiler_flag|check_c_source_compiles|check_cxx_source_compiles|check_include_file|check_symbol_exists|cmake_push_check_state|cmake_pop_check_state|find_package|CMAKE_REQUIRED_FLAGS|CheckIncludeFile|CheckCCompilerFlag|CheckCXXCompilerFlag|CheckCSourceCompiles|CheckCXXSourceCompiles|CheckCSymbolExists|CheckCXXSymbolExists' | grep -v Rust && echo "^ It's not allowed to have dynamic compiler checks with CMake."

# Wrong spelling of abbreviations, e.g. SQL is right, Sql is wrong. XMLHttpRequest is very wrong.
find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -P 'Sql|Html|Xml|Cpu|Tcp|Udp|Http|Db|Json|Yaml' | grep -v -P 'RabbitMQ|Azure|Aws|aws|Avro|IO/S3' &&
    echo "Abbreviations such as SQL, XML, HTTP, should be in all caps. For example, SQL is right, Sql is wrong. XMLHttpRequest is very wrong."

find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' |
    grep -vP $EXCLUDE |
    xargs grep -F -i 'ErrorCodes::LOGICAL_ERROR, "Logical error:' &&
    echo "If an exception has LOGICAL_ERROR code, there is no need to include the text 'Logical error' in the exception message, because then the phrase 'Logical error' will be printed twice."

PATTERN="allow_";
DIFF=$(comm -3 <(grep -o "\b$PATTERN\w*\b" $ROOT_PATH/src/Core/Settings.cpp | sort -u) <(grep -o -h "\b$PATTERN\w*\b" $ROOT_PATH/src/Databases/enableAllExperimentalSettings.cpp $ROOT_PATH/ci/jobs/scripts/check_style/experimental_settings_ignore.txt | sort -u));
[ -n "$DIFF" ] && echo "$DIFF" && echo "^^ Detected 'allow_*' settings that might need to be included in src/Databases/enableAllExperimentalSettings.cpp" && echo "Alternatively, consider adding an exception to ci/jobs/scripts/check_style/experimental_settings_ignore.txt"

# Don't allow the direct inclusion of magic_enum.hpp and instead point to base/EnumReflection.h
find $ROOT_PATH/{src,base,programs,utils} -name '*.cpp' -or -name '*.h' | xargs grep -l "magic_enum.hpp" | grep -v EnumReflection.h | while read -r line;
do
    echo "Found the inclusion of magic_enum.hpp in '${line}'. Please use <base/EnumReflection.h> instead"
done

# Currently fmt::format is faster both at compile and runtime
find $ROOT_PATH/{src,base,programs,utils} -name '*.h' -or -name '*.cpp' | grep -vP $EXCLUDE | xargs grep -l "std::format" | while read -r file;
do
    echo "Found the usage of std::format in '${file}'. Please use fmt::format instead"
done

# Forbid using quotes for includes (except for autogenerated files)
QUOTE_EXCLUSIONS=(
    --exclude "$ROOT_PATH/utils/memcpy-bench/glibc/*"
    # TODO (WIP)
    --exclude "$ROOT_PATH/src/Functions/*"
    --exclude "$ROOT_PATH/src/Interpreters/*"
    --exclude "$ROOT_PATH/src/IO/*"
    --exclude "$ROOT_PATH/src/Loggers/*"
    --exclude "$ROOT_PATH/src/Parsers/*"
    --exclude "$ROOT_PATH/src/Processors/*"
    --exclude "$ROOT_PATH/src/Server/*"
    --exclude "$ROOT_PATH/src/Storages/*"
    --exclude "$ROOT_PATH/src/TableFunctions/*"
)
find $ROOT_PATH/{src,programs,utils} -name '*.h' -or -name '*.cpp' | \
  xargs grep -P '#include[\s]*(").*(")' "${QUOTE_EXCLUSIONS[@]}" | \
  grep -v -F -e \"config.h\" -e \"config_tools.h\" -e \"SQLGrammar.pb.h\" | \
  xargs -i echo "Found include with quotes in '{}'. Please use <> instead"

# Context.h (and a few similar headers) is included in many parts of the
# codebase, so any modifications to it trigger a large-scale recompilation.
# Therefore, it is crucial to avoid unnecessary inclusion of Context.h in
# headers.
#
# In most cases, we can include Context_fwd.h instead, as we usually do not
# need the full definition of the Context structure in headers - only declaration.
CONTEXT_H_EXCLUDES=(
    # For now we have few exceptions (somewhere due to templated code, in other
    # places just because for now it does not worth it, i.e. the header is not
    # too generic):
    --exclude "$ROOT_PATH/src/BridgeHelper/XDBCBridgeHelper.h"
    --exclude "$ROOT_PATH/src/Interpreters/AddDefaultDatabaseVisitor.h"
    --exclude "$ROOT_PATH/src/TableFunctions/ITableFunctionCluster.h"
    --exclude "$ROOT_PATH/src/Core/PostgreSQLProtocol.h"
    --exclude "$ROOT_PATH/src/Client/ClientBase.h"
    --exclude "$ROOT_PATH/src/Common/tests/gtest_global_context.h"
    --exclude "$ROOT_PATH/src/Analyzer/InDepthQueryTreeVisitor.h"

    # For functions we allow it for regular functions (due to lots of
    # templates), but forbid it in interface (IFunction) part.
    --exclude "$ROOT_PATH/src/Functions/*"
    --include "$ROOT_PATH/src/Functions/IFunction*"
)
find $ROOT_PATH/src -name '*.h' -print0 | xargs -0 grep -P '#include[\s]*(<|")Interpreters/Context.h(>|")' "${CONTEXT_H_EXCLUDES[@]}" | \
    grep . && echo '^ Too broad Context.h usage. Consider using Context_fwd.h and Context.h out from .h into .cpp'

exit 0
