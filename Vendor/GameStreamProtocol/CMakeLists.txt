cmake_minimum_required(VERSION 3.20)
project(UmbraGameStreamProtocol LANGUAGES C)

option(UMBRA_BUILD_TESTS "Build focused bridge tests" ON)

set(BUILD_SHARED_LIBS_BACKUP "${BUILD_SHARED_LIBS}")
set(BUILD_SHARED_LIBS OFF)
add_subdirectory(Upstream)
set(BUILD_SHARED_LIBS "${BUILD_SHARED_LIBS_BACKUP}")

target_include_directories(moonlight-common-c PRIVATE Facade/include)

add_library(CGameStreamProtocol STATIC
    Facade/src/UmbraClientMicrophoneRTSPExtension.c
    Facade/src/UmbraOptimizationModeRTSPExtension.c
    Facade/src/UmbraRequiredCallbacks.c
    Facade/src/UmbraStreamingBridge.c
)

target_compile_features(CGameStreamProtocol PUBLIC c_std_11)
target_include_directories(CGameStreamProtocol
    PUBLIC Facade/include
    PRIVATE Upstream/src Upstream/enet/include
)
target_link_libraries(CGameStreamProtocol PUBLIC moonlight-common-c)

if(APPLE)
    target_compile_definitions(CGameStreamProtocol PRIVATE HAS_SOCKLEN_T)
endif()

if(UMBRA_BUILD_TESTS)
    enable_testing()
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    target_compile_definitions(moonlight-common-c PRIVATE UMBRA_STREAM_TESTING)
    target_compile_definitions(CGameStreamProtocol PRIVATE UMBRA_STREAM_TESTING)
    add_executable(CGameStreamProtocolTests
        Facade/Tests/UmbraStreamingBridgeTests.c
    )
    target_compile_definitions(CGameStreamProtocolTests PRIVATE UMBRA_STREAM_TESTING)
    target_compile_features(CGameStreamProtocolTests PRIVATE c_std_11)
    target_include_directories(CGameStreamProtocolTests PRIVATE Facade/Tests Facade/src Upstream/src)
    target_link_libraries(CGameStreamProtocolTests PRIVATE CGameStreamProtocol)
    add_test(NAME CGameStreamProtocolTests COMMAND CGameStreamProtocolTests)
    add_test(
        NAME GameStreamProtocolProvenance
        COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/Tests/verify_provenance.py
            --vendor ${CMAKE_CURRENT_SOURCE_DIR}
    )
endif()
