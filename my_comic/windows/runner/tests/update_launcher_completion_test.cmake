# Exercise production launcher completion without starting any real process.
set(LAUNCHER_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/update_launcher.cpp")
set(LAUNCHER_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/update_launcher_completion_production.inc")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${LAUNCHER_SOURCE}")
include("${CMAKE_CURRENT_SOURCE_DIR}/tests/update_launcher_completion_extract.cmake")
add_executable(my_comic_windows_update_launcher_completion_test
  "tests/update_launcher_completion_test.cpp")
apply_standard_settings(my_comic_windows_update_launcher_completion_test)
target_include_directories(my_comic_windows_update_launcher_completion_test PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}")
add_custom_target(my_comic_windows_update_launcher_completion_gate
  COMMAND "$<TARGET_FILE:my_comic_windows_update_launcher_completion_test>"
  DEPENDS my_comic_windows_update_launcher_completion_test
  VERBATIM)
add_dependencies(${BINARY_NAME} my_comic_windows_update_launcher_completion_gate)
