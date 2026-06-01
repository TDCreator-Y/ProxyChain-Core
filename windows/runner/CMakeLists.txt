cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# The runner manifest already declares `requireAdministrator`. Disable the
# linker-generated default UAC snippet to avoid manifest merge conflicts.
target_link_options(${BINARY_NAME} PRIVATE "/MANIFESTUAC:NO")

# 确保运行时能找到 wintun.dll
set(WINTUN_DLL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../core_rust/target/debug/examples/wintun.dll")
if(NOT EXISTS "${WINTUN_DLL_PATH}")
    file(GLOB_RECURSE WINTUN_CANDIDATES "${CMAKE_CURRENT_SOURCE_DIR}/../../build/windows/x64/plugins/rust_lib_flutter_rust_app/cargokit_build/*/wintun.dll")
    list(GET WINTUN_CANDIDATES 0 WINTUN_DLL_PATH)
endif()

if(EXISTS "${WINTUN_DLL_PATH}")
    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${WINTUN_DLL_PATH}"
        "$<TARGET_FILE_DIR:${BINARY_NAME}>/"
    )
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
