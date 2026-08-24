cmake_minimum_required(VERSION 3.20)
project(UmbraMoonlightBridge LANGUAGES C)

option(UMBRA_BUILD_TESTS "Build focused bridge tests" ON)

set(BUILD_SHARED_LIBS_BACKUP "${BUILD_SHARED_LIBS}")
set(BUILD_SHARED_LIBS OFF)
add_subdirectory(Upstream)
set(BUILD_SHARED_LIBS "${BUILD_SHARED_LIBS_BACKUP}")

target_include_directories(moonlight-common-c PRIVATE Facade/include)

add_library(CMoonlightBridge STATIC
    Facade/src/UmbraClientMicrophoneRTSPExtension.c
    Facade/src/UmbraOptimizationModeRTSPExtension.c
    Facade/src/UmbraRequiredCallbacks.c
    Facade/src/UmbraStreamingBridge.c
)

target_compile_features(CMoonlightBridge PUBLIC c_std_11)
target_include_directories(CMoonlightBridge
    PUBLIC Facade/include
    PRIVATE Upstream/src Upstream/enet/include
)
target_link_libraries(CMoonlightBridge PUBLIC moonlight-common-c)

if(APPLE)
    target_compile_definitions(CMoonlightBridge PRIVATE HAS_SOCKLEN_T)
endif()

if(UMBRA_BUILD_TESTS)
    enable_testing()
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    target_compile_definitions(moonlight-common-c PRIVATE UMBRA_STREAM_TESTING)
    target_compile_definitions(CMoonlightBridge PRIVATE UMBRA_STREAM_TESTING)
    add_executable(CMoonlightBridgeTests
        Facade/Tests/UmbraStreamingBridgeTests.c
    )
    target_compile_definitions(CMoonlightBridgeTests PRIVATE UMBRA_STREAM_TESTING)
    target_compile_features(CMoonlightBridgeTests PRIVATE c_std_11)
    target_include_directories(CMoonlightBridgeTests PRIVATE Facade/Tests Facade/src Upstream/src)
    target_link_libraries(CMoonlightBridgeTests PRIVATE CMoonlightBridge)
    add_test(NAME CMoonlightBridgeTests COMMAND CMoonlightBridgeTests)
    add_test(
        NAME MoonlightCommonProvenance
        COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/Tests/verify_provenance.py
            --vendor ${CMAKE_CURRENT_SOURCE_DIR}
    )
endif()
