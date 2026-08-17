cmake_minimum_required(VERSION 3.13)

option(RF_BUILD_PICO "Build the RP2040 firmware with the Raspberry Pi Pico SDK" OFF)
set(RF_PICOTOOL_EXECUTABLE "" CACHE FILEPATH
    "Optional picotool executable used to create UF2 when PICO_NO_PICOTOOL=1")

if(RF_BUILD_PICO)
    if(DEFINED PICO_SDK_PATH AND
       EXISTS "${PICO_SDK_PATH}/external/pico_sdk_import.cmake")
        include("${PICO_SDK_PATH}/external/pico_sdk_import.cmake")
    elseif(DEFINED ENV{PICO_SDK_PATH} AND
           EXISTS "$ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake")
        include("$ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake")
    else()
        message(FATAL_ERROR
            "RF_BUILD_PICO=ON requires PICO_SDK_PATH to point to a Pico SDK checkout")
    endif()
endif()

project(rf_frontend_controller VERSION 1.0.0 LANGUAGES C CXX ASM)

set(RF_INCLUDE_DIRECTORIES
    firmware/include
    firmware/drivers
    firmware/app
    firmware/protocol
    firmware/transport
)

add_library(rf_core
    firmware/drivers/sn74hc595_chain.c
    firmware/drivers/pe4302.c
    firmware/drivers/maps010144.c
    firmware/drivers/bgb741.c
    firmware/drivers/tps7a2033.c
    firmware/app/rf_frontend.c
    firmware/app/safety_monitor.c
    firmware/protocol/command_protocol.c
    firmware/transport/line_reader.c
)
target_include_directories(rf_core PUBLIC ${RF_INCLUDE_DIRECTORIES})
target_compile_features(rf_core PUBLIC c_std_11)

function(rf_enable_strict_warnings target)
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
endfunction()

rf_enable_strict_warnings(rf_core)

if(RF_BUILD_PICO)
    pico_sdk_init()

    add_executable(rf_frontend_firmware
        firmware/src/main.c
        firmware/src/pico_io.c
        firmware/transport/usb_cdc_transport.c
    )
    target_link_libraries(rf_frontend_firmware PRIVATE
        rf_core
        pico_stdlib
        hardware_watchdog
    )
    target_include_directories(rf_frontend_firmware PRIVATE
        ${RF_INCLUDE_DIRECTORIES})
    target_compile_definitions(rf_frontend_firmware PRIVATE
        PICO_STDIO_USB_STDOUT_TIMEOUT_US=0)
    # Pico SDK sources are compiled as part of this target and intentionally
    # use a few non-ISO embedded-C constructs, so do not apply -Wpedantic to
    # the complete executable. Project portable sources remain pedantic in
    # rf_core; the Pico integration still builds with warnings as errors.
    if(MSVC)
        target_compile_options(rf_frontend_firmware PRIVATE /W4 /WX)
    else()
        target_compile_options(rf_frontend_firmware PRIVATE
            -Wall -Wextra -Werror)
    endif()
    pico_enable_stdio_usb(rf_frontend_firmware 1)
    pico_enable_stdio_uart(rf_frontend_firmware 0)
    pico_add_extra_outputs(rf_frontend_firmware)
    if(PICO_NO_PICOTOOL AND RF_PICOTOOL_EXECUTABLE)
        add_custom_command(TARGET rf_frontend_firmware POST_BUILD
            COMMAND "${RF_PICOTOOL_EXECUTABLE}" uf2 convert --quiet
                    "$<TARGET_FILE:rf_frontend_firmware>"
                    "${CMAKE_CURRENT_BINARY_DIR}/rf_frontend_firmware.uf2"
            COMMENT "Creating UF2 with the supplied picotool"
            VERBATIM)
    elseif(PICO_NO_PICOTOOL)
        message(WARNING
            "PICO_NO_PICOTOOL=1 and RF_PICOTOOL_EXECUTABLE is unset; UF2 will not be generated")
    endif()
else()
    include(CTest)
    if(BUILD_TESTING)
        # Unit tests use the C assert macro as their test oracle. Keep asserts
        # enabled even when a multi-config generator builds the Release config.
        foreach(flags_var IN ITEMS CMAKE_C_FLAGS_RELEASE
                                   CMAKE_C_FLAGS_RELWITHDEBINFO
                                   CMAKE_C_FLAGS_MINSIZEREL)
            if(MSVC)
                string(REPLACE "/DNDEBUG" "" ${flags_var} "${${flags_var}}")
            else()
                string(REPLACE "-DNDEBUG" "" ${flags_var} "${${flags_var}}")
            endif()
        endforeach()
        foreach(test_name IN ITEMS
                test_pe4302
                test_maps010144
                test_rf_frontend
                test_protocol
                test_safety_monitor)
            add_executable(${test_name} tests/${test_name}.c)
            target_link_libraries(${test_name} PRIVATE rf_core)
            target_include_directories(${test_name} PRIVATE tests)
            rf_enable_strict_warnings(${test_name})
            add_test(NAME ${test_name} COMMAND ${test_name})
        endforeach()
    endif()
endif()
