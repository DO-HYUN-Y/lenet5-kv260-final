cmake_minimum_required(VERSION 3.20)
project(alexnet_golden LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(ALEXNET_GOLDEN_SOURCES
    src/activation_bank_ref.cpp
    src/activation_pingpong_ref.cpp
    src/alexnet_ref.cpp
    src/conv2d_ref.cpp
    src/descriptor_ref.cpp
    src/layout_ref.cpp
    src/linear_ref.cpp
    src/maxpool_ref.cpp
    src/output_router_ref.cpp
    src/packed_mac_ref.cpp
    src/partial_sum_bank_ref.cpp
    src/quant_ref.cpp
    src/sa_tile_ref.cpp
    src/skew_ref.cpp
    src/window_ref.cpp
    src/weight_tile_bank_ref.cpp)

add_library(alexnet_golden STATIC ${ALEXNET_GOLDEN_SOURCES})
target_include_directories(alexnet_golden PUBLIC include)
set_target_properties(alexnet_golden PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(alexnet_golden_dpi SHARED src/dpi_wrappers.cpp)
target_include_directories(alexnet_golden_dpi PUBLIC include)
target_link_libraries(alexnet_golden_dpi PRIVATE alexnet_golden)
set_target_properties(alexnet_golden_dpi PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)

if(MSVC)
  target_compile_options(alexnet_golden PRIVATE /W4)
  target_compile_options(alexnet_golden_dpi PRIVATE /W4)
else()
  target_compile_options(alexnet_golden PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(alexnet_golden_dpi PRIVATE -Wall -Wextra -Wpedantic)
endif()

enable_testing()
add_executable(alexnet_golden_tests tests/golden_tests.cpp)
target_link_libraries(alexnet_golden_tests PRIVATE alexnet_golden alexnet_golden_dpi)
add_test(NAME alexnet_golden_tests COMMAND alexnet_golden_tests)

add_executable(alexnet_board_full_graph_golden
    tools/board_full_graph_golden.cpp)
target_link_libraries(alexnet_board_full_graph_golden PRIVATE alexnet_golden)
