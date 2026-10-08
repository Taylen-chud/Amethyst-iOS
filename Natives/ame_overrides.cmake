# used through -DCMAKE_PROJECT_INCLUDE, renames MobileGlues' own versions of the functions in ame_overrides.cpp

if(NOT PROJECT_NAME STREQUAL "mobileglues")
    return()
endif()

function(ame_apply_overrides mg_src ame_dir)
    target_sources(mobileglues PRIVATE "${ame_dir}/ame_overrides.cpp")
    target_include_directories(mobileglues PRIVATE "${mg_src}")

    set_property(SOURCE "${mg_src}/gl/framebuffer.cpp" APPEND PROPERTY
        COMPILE_DEFINITIONS "glFramebufferTexture=ame_orig_glFramebufferTexture")
    set_property(SOURCE "${mg_src}/gl/gl_native.cpp" APPEND PROPERTY
        COMPILE_DEFINITIONS "glClientWaitSync=ame_orig_glClientWaitSync")
    set_property(SOURCE "${mg_src}/glx/lookup.cpp" APPEND PROPERTY
        COMPILE_DEFINITIONS "dlsym=ame_dlsym")
endfunction()

# defer so the target exists, EVAL so the paths are fixed now
cmake_language(EVAL CODE "cmake_language(DEFER CALL ame_apply_overrides [[${CMAKE_CURRENT_SOURCE_DIR}]] [[${CMAKE_CURRENT_LIST_DIR}]])")
