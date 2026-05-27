cmake_minimum_required(VERSION 3.22)
project(TheGoldModDev)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

# ── imgui ──────────────────────────────────────────────────────────────────────
FetchContent_Declare(ImGui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG        v1.92.1
    GIT_SHALLOW    TRUE
    GIT_PROGRESS   ON
)
FetchContent_MakeAvailable(ImGui)

# ── MinHook ───────────────────────────────────────────────────────────────────
FetchContent_Declare(MinHook
    GIT_REPOSITORY https://github.com/TsudaKageyu/minhook.git
    GIT_TAG        v1.3.3
    GIT_SHALLOW    TRUE
    GIT_PROGRESS   ON
)
FetchContent_MakeAvailable(MinHook)

add_library(minhook STATIC
    "${minhook_SOURCE_DIR}/src/buffer.c"
    "${minhook_SOURCE_DIR}/src/hook.c"
    "${minhook_SOURCE_DIR}/src/trampoline.c"
    "${minhook_SOURCE_DIR}/src/hde/hde32.c"
    "${minhook_SOURCE_DIR}/src/hde/hde64.c"
)
target_include_directories(minhook PUBLIC "${minhook_SOURCE_DIR}/include")
set_property(TARGET minhook PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

# ── UE4SS (reuse from SN2ThirdPersonMod — same game, same SDK) ───────────────
# If you've built SN2ThirdPersonMod these already exist.  Point at them here.
# To use a different location: cmake -DUE4SS_MOD_DIR=<path> ..
set(UE4SS_MOD_DIR "C:/Users/rafa/source/repos/SN2ThirdPersonMod"
    CACHE PATH "Root of the SN2ThirdPersonMod repo (contains RE-UE4SS/ and UE4SS.lib)")

set(UE4SS_SRC "${UE4SS_MOD_DIR}/RE-UE4SS")
set(UE4SS_LIB "${UE4SS_MOD_DIR}/UE4SS.lib" CACHE FILEPATH "Path to UE4SS.lib")

set(UE4SS_INCLUDE_DIRS
    "${UE4SS_MOD_DIR}/stubs"
    "${UE4SS_SRC}/UE4SS/include"
    "${UE4SS_SRC}/deps/first/String/include"
    "${UE4SS_SRC}/deps/first/File/include"
    "${UE4SS_SRC}/deps/first/Input/include"
    "${UE4SS_SRC}/deps/first/DynamicOutput/include"
    "${UE4SS_SRC}/deps/first/Helpers/include"
    "${UE4SS_SRC}/deps/first/Constructs/include"
    "${UE4SS_SRC}/deps/first/Function/include"
    "${UE4SS_SRC}/deps/first/ScopedTimer/include"
    "${UE4SS_SRC}/deps/first/MProgram/include"
    "${imgui_SOURCE_DIR}"
    "${imgui_SOURCE_DIR}/backends"
)

# ── imgui static lib ──────────────────────────────────────────────────────────
add_library(imgui_static STATIC
    "${imgui_SOURCE_DIR}/imgui.cpp"
    "${imgui_SOURCE_DIR}/imgui_draw.cpp"
    "${imgui_SOURCE_DIR}/imgui_tables.cpp"
    "${imgui_SOURCE_DIR}/imgui_widgets.cpp"
    "${imgui_SOURCE_DIR}/backends/imgui_impl_dx12.cpp"
    "${imgui_SOURCE_DIR}/backends/imgui_impl_win32.cpp"
)
target_compile_features(imgui_static PUBLIC cxx_std_23)
target_include_directories(imgui_static PUBLIC "${imgui_SOURCE_DIR}" "${imgui_SOURCE_DIR}/backends")
target_link_libraries(imgui_static PUBLIC d3d12 dxgi dxguid)
set_property(TARGET imgui_static PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_subdirectory(TheGoldModSettings)
