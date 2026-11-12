if(WIN32)
  add_executable(my_comic_siglus_legacy_owner_publication_test
    "${CMAKE_CURRENT_LIST_DIR}/siglus_legacy_owner_publication_test.cpp")
  target_include_directories(my_comic_siglus_legacy_owner_publication_test PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../hook/adapters")
  target_compile_features(my_comic_siglus_legacy_owner_publication_test PRIVATE cxx_std_17)
  if(MSVC)
    target_compile_options(my_comic_siglus_legacy_owner_publication_test PRIVATE /W4 /WX)
  endif()
  add_test(NAME my_comic_siglus_legacy_owner_publication_test
    COMMAND my_comic_siglus_legacy_owner_publication_test)
endif()
