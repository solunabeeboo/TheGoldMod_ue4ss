// TheGoldModSettings v1.0
// In-game ImGui settings overlay for TheGoldMod (creature transformation mod).
// D3D12/DXGI injection is identical to SN2ThirdPersonSettings v3.0 — every
// architectural decision (never-cache back buffers, per-slot fence, CPU wait,
// dual detection flags) is documented in the SN2ThirdPersonMod project.

#include <Mod/CppUserModBase.hpp>
#include <UE4SSProgram.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <imgui.h>
#include <backends/imgui_impl_dx12.h>
#include <backends/imgui_impl_win32.h>

#include <MinHook.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <windows.h>
#include <dxgi1_4.h>
#include <d3d12.h>

// ── Settings ──────────────────────────────────────────────────────────────────

struct GMSettings
{
    std::string wheelKey     = "G";
    std::string primaryKey   = "T";
    std::string secondaryKey = "R";
    std::string revertKey    = "H";
    bool        autoUnlock   = true;

    bool operator==(const GMSettings& o) const
    {
        return wheelKey == o.wheelKey && primaryKey == o.primaryKey &&
               secondaryKey == o.secondaryKey && revertKey == o.revertKey &&
               autoUnlock == o.autoUnlock;
    }
    bool operator!=(const GMSettings& o) const { return !(*this == o); }
};

// ── File I/O ──────────────────────────────────────────────────────────────────

static std::filesystem::path GetModRootDir()
{
    wchar_t buf[MAX_PATH]{};
    HMODULE hm = nullptr;
    GetModuleHandleExW(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&GetModRootDir), &hm);
    GetModuleFileNameW(hm, buf, MAX_PATH);
    return std::filesystem::path(buf).parent_path().parent_path();
}

static GMSettings LoadSettings()
{
    GMSettings s;
    std::ifstream f(GetModRootDir() / L"settings.txt");
    if (!f.is_open()) return s;

    std::string line;
    while (std::getline(f, line))
    {
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq);
        std::string val = line.substr(eq + 1);
        if (!val.empty() && val.back() == '\r') val.pop_back();
        if      (key == "WheelKey"     && !val.empty()) s.wheelKey     = val;
        else if (key == "PrimaryKey"   && !val.empty()) s.primaryKey   = val;
        else if (key == "SecondaryKey" && !val.empty()) s.secondaryKey = val;
        else if (key == "RevertKey"    && !val.empty()) s.revertKey    = val;
        else if (key == "AutoUnlock")  s.autoUnlock = (val == "true" || val == "1");
    }
    return s;
}

static void SaveSettings(const GMSettings& s)
{
    std::ofstream f(GetModRootDir() / L"settings.txt");
    if (!f.is_open()) return;
    f << "WheelKey="     << s.wheelKey     << "\n";
    f << "PrimaryKey="   << s.primaryKey   << "\n";
    f << "SecondaryKey=" << s.secondaryKey << "\n";
    f << "RevertKey="    << s.revertKey    << "\n";
    f << "AutoUnlock="   << (s.autoUnlock ? "true" : "false") << "\n";
}

// ── Key presets ───────────────────────────────────────────────────────────────

static constexpr const char* k_keys[] = {
    "F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12",
    "F13","F14","F15","F16","F17","F18","F19","F20","F21","F22","F23","F24",
    "ONE","TWO","THREE","FOUR","FIVE","SIX","SEVEN","EIGHT","NINE","ZERO",
    "NUM_ONE","NUM_TWO","NUM_THREE","NUM_FOUR","NUM_FIVE",
    "NUM_SIX","NUM_SEVEN","NUM_EIGHT","NUM_NINE","NUM_ZERO",
    "A","B","C","D","E","F","G","H","I","J","K","L","M",
    "N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
    "RETURN","BACKSPACE","TAB","ESCAPE","SPACE",
    "INSERT","DELETE","HOME","END","PAGE_UP","PAGE_DOWN",
    "UP_ARROW","DOWN_ARROW","LEFT_ARROW","RIGHT_ARROW",
    "LEFT_MOUSE_BUTTON","RIGHT_MOUSE_BUTTON","MIDDLE_MOUSE_BUTTON",
};
static constexpr int k_key_count = static_cast<int>(sizeof(k_keys) / sizeof(k_keys[0]));

static int FindKeyIndex(const std::string& key)
{
    for (int i = 0; i < k_key_count; ++i)
        if (key == k_keys[i]) return i;
    return -1;
}

// ── D3D12 overlay internals ───────────────────────────────────────────────────
// Everything below this line is identical to SN2ThirdPersonSettings v3.0.
// The architectural decisions are documented in that project.

static constexpr int NUM_BACK_BUFFERS = 3;

static std::mutex             g_overlayMtx;
static bool                   g_d3dReady          = false;
static HWND                   g_gameHwnd          = nullptr;

static ID3D12Device*              g_device        = nullptr;
static ID3D12CommandQueue*        g_ueQueue       = nullptr;
static ID3D12DescriptorHeap*      g_srvHeap       = nullptr;
static ID3D12DescriptorHeap*      g_rtvHeap       = nullptr;
static ID3D12CommandAllocator*    g_alloc[NUM_BACK_BUFFERS] = {};
static ID3D12GraphicsCommandList* g_cmdList       = nullptr;
static D3D12_CPU_DESCRIPTOR_HANDLE g_rtvSlot      = {};
static UINT                       g_rtvDescSize   = 0;
static ID3D12Fence*               g_fence         = nullptr;
static HANDLE                     g_fenceEvent    = nullptr;
static UINT64                     g_fenceSlot[NUM_BACK_BUFFERS] = {};
static UINT64                     g_fenceVal      = 0;
static int                        g_bufCount      = 0;
static int                        g_srvAllocIdx   = 0;

typedef HRESULT(STDMETHODCALLTYPE* PFN_Present)(IDXGISwapChain*, UINT, UINT);
typedef HRESULT(STDMETHODCALLTYPE* PFN_Present1)(IDXGISwapChain1*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*);
typedef HRESULT(STDMETHODCALLTYPE* PFN_CreateSCFH)(IDXGIFactory2*, IUnknown*, HWND,
    const DXGI_SWAP_CHAIN_DESC1*, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC*,
    IDXGIOutput*, IDXGISwapChain1**);
typedef LRESULT(CALLBACK* PFN_WndProc)(HWND, UINT, WPARAM, LPARAM);

static PFN_Present      g_origPresent    = nullptr;
static PFN_Present1     g_origPresent1   = nullptr;
static PFN_CreateSCFH   g_origCreateSCFH = nullptr;
static PFN_WndProc      g_origWndProc    = nullptr;

static std::function<void()> g_renderFn;
static std::atomic<bool>     g_showOverlay{false};
static std::atomic<bool>     g_showContent{false};

// ── WndProc hook ──────────────────────────────────────────────────────────────

IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

static LRESULT CALLBACK WndProc_Hook(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp))
        return true;
    return g_origWndProc(hwnd, msg, wp, lp);
}

// ── ImGui SRV descriptor allocator ───────────────────────────────────────────

static void SrvAlloc(ImGui_ImplDX12_InitInfo*, D3D12_CPU_DESCRIPTOR_HANDLE* cpu,
                     D3D12_GPU_DESCRIPTOR_HANDLE* gpu)
{
    UINT sz = g_device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    cpu->ptr = g_srvHeap->GetCPUDescriptorHandleForHeapStart().ptr + g_srvAllocIdx * sz;
    gpu->ptr = g_srvHeap->GetGPUDescriptorHandleForHeapStart().ptr + g_srvAllocIdx * sz;
    g_srvAllocIdx++;
}
static void SrvFree(ImGui_ImplDX12_InitInfo*, D3D12_CPU_DESCRIPTOR_HANDLE,
                    D3D12_GPU_DESCRIPTOR_HANDLE) {}

// ── D3D12 + ImGui initialisation ─────────────────────────────────────────────

static bool InitD3DAndImGui(IDXGISwapChain* sc)
{
    IDXGISwapChain3* sc3 = nullptr;
    if (FAILED(sc->QueryInterface(IID_PPV_ARGS(&sc3)))) return false;

    if (FAILED(sc3->GetDevice(IID_PPV_ARGS(&g_device)))) { sc3->Release(); return false; }

    DXGI_SWAP_CHAIN_DESC scDesc{};
    sc3->GetDesc(&scDesc);
    g_bufCount = (int)scDesc.BufferCount;
    if (g_bufCount > NUM_BACK_BUFFERS) g_bufCount = NUM_BACK_BUFFERS;

    D3D12_DESCRIPTOR_HEAP_DESC rtvHD{};
    rtvHD.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rtvHD.NumDescriptors = 1;
    rtvHD.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    if (FAILED(g_device->CreateDescriptorHeap(&rtvHD, IID_PPV_ARGS(&g_rtvHeap))))
        return false;
    g_rtvDescSize = g_device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    g_rtvSlot = g_rtvHeap->GetCPUDescriptorHandleForHeapStart();

    D3D12_DESCRIPTOR_HEAP_DESC srvHD{};
    srvHD.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    srvHD.NumDescriptors = 64;
    srvHD.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    if (FAILED(g_device->CreateDescriptorHeap(&srvHD, IID_PPV_ARGS(&g_srvHeap))))
        return false;

    for (int i = 0; i < g_bufCount; ++i)
        g_device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&g_alloc[i]));

    g_device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                g_alloc[0], nullptr, IID_PPV_ARGS(&g_cmdList));
    g_cmdList->Close();

    g_device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&g_fence));
    g_fenceEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
    g_fenceVal   = 0;

    if (!g_ueQueue) return false;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    ImGui::StyleColorsDark();

    ImGui_ImplWin32_Init(g_gameHwnd);

    ImGui_ImplDX12_InitInfo di{};
    di.Device              = g_device;
    di.CommandQueue        = g_ueQueue;
    di.NumFramesInFlight   = g_bufCount;
    di.RTVFormat           = scDesc.BufferDesc.Format;
    di.DSVFormat           = DXGI_FORMAT_UNKNOWN;
    di.SrvDescriptorHeap   = g_srvHeap;
    di.SrvDescriptorAllocFn = SrvAlloc;
    di.SrvDescriptorFreeFn  = SrvFree;
    if (!ImGui_ImplDX12_Init(&di)) return false;

    sc3->Release();

    g_origWndProc = reinterpret_cast<PFN_WndProc>(
        SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC,
                          reinterpret_cast<LONG_PTR>(WndProc_Hook)));

    return true;
}

// ── Per-frame render ──────────────────────────────────────────────────────────

static void RenderOverlay(IDXGISwapChain3* sc3)
{
    if (!g_showOverlay.load(std::memory_order_relaxed)) return;

    UINT fi = sc3->GetCurrentBackBufferIndex();
    if (fi >= (UINT)g_bufCount) fi = 0;

    ID3D12Resource* backBuf = nullptr;
    if (FAILED(sc3->GetBuffer(fi, IID_PPV_ARGS(&backBuf)))) return;

    g_device->CreateRenderTargetView(backBuf, nullptr, g_rtvSlot);

    if (g_fence->GetCompletedValue() < g_fenceSlot[fi])
    {
        g_fence->SetEventOnCompletion(g_fenceSlot[fi], g_fenceEvent);
        WaitForSingleObject(g_fenceEvent, 100);
    }

    g_alloc[fi]->Reset();
    g_cmdList->Reset(g_alloc[fi], nullptr);

    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type                   = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource   = backBuf;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    barrier.Transition.StateAfter  = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    g_cmdList->ResourceBarrier(1, &barrier);

    g_cmdList->OMSetRenderTargets(1, &g_rtvSlot, FALSE, nullptr);
    g_cmdList->SetDescriptorHeaps(1, &g_srvHeap);

    ImGui_ImplDX12_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();

    {
        std::lock_guard<std::mutex> lk(g_overlayMtx);
        if (g_renderFn) g_renderFn();
    }

    ImGui::Render();
    ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(), g_cmdList);

    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter  = D3D12_RESOURCE_STATE_PRESENT;
    g_cmdList->ResourceBarrier(1, &barrier);
    g_cmdList->Close();

    backBuf->Release();

    ID3D12CommandList* lists[] = {g_cmdList};
    g_ueQueue->ExecuteCommandLists(1, lists);
    g_ueQueue->Signal(g_fence, ++g_fenceVal);
    g_fenceSlot[fi] = g_fenceVal;
    g_fence->SetEventOnCompletion(g_fenceVal, g_fenceEvent);
    WaitForSingleObject(g_fenceEvent, 100);
}

// ── Present hooks ─────────────────────────────────────────────────────────────

static bool TryInitOnFirstPresent(IDXGISwapChain* sc)
{
    if (g_d3dReady) return true;

    DXGI_SWAP_CHAIN_DESC desc{};
    sc->GetDesc(&desc);
    g_gameHwnd = desc.OutputWindow;
    if (!g_gameHwnd) return false;

    if (InitD3DAndImGui(sc))
        g_d3dReady = true;

    return g_d3dReady;
}

static HRESULT STDMETHODCALLTYPE Present_Hook(IDXGISwapChain* sc, UINT sync, UINT flags)
{
    TryInitOnFirstPresent(sc);
    if (g_d3dReady)
    {
        IDXGISwapChain3* sc3 = nullptr;
        if (SUCCEEDED(sc->QueryInterface(IID_PPV_ARGS(&sc3))))
        {
            RenderOverlay(sc3);
            sc3->Release();
        }
    }
    return g_origPresent(sc, sync, flags);
}

static HRESULT STDMETHODCALLTYPE Present1_Hook(IDXGISwapChain1* sc, UINT sync, UINT flags,
                                               const DXGI_PRESENT_PARAMETERS* params)
{
    TryInitOnFirstPresent(sc);
    if (g_d3dReady)
    {
        IDXGISwapChain3* sc3 = nullptr;
        if (SUCCEEDED(sc->QueryInterface(IID_PPV_ARGS(&sc3))))
        {
            RenderOverlay(sc3);
            sc3->Release();
        }
    }
    return g_origPresent1(sc, sync, flags, params);
}

// ── CreateSwapChainForHwnd hook ───────────────────────────────────────────────

static HRESULT STDMETHODCALLTYPE CreateSCFH_Hook(
    IDXGIFactory2* factory, IUnknown* pDevice, HWND hWnd,
    const DXGI_SWAP_CHAIN_DESC1* pDesc,
    const DXGI_SWAP_CHAIN_FULLSCREEN_DESC* pFSDesc,
    IDXGIOutput* pOutput, IDXGISwapChain1** ppSC)
{
    HRESULT hr = g_origCreateSCFH(factory, pDevice, hWnd, pDesc, pFSDesc, pOutput, ppSC);

    if (SUCCEEDED(hr) && ppSC && *ppSC && !g_origPresent)
    {
        if (!g_ueQueue)
        {
            ID3D12CommandQueue* q = nullptr;
            if (SUCCEEDED(reinterpret_cast<IUnknown*>(pDevice)->QueryInterface(IID_PPV_ARGS(&q))))
                g_ueQueue = q;
        }

        IDXGISwapChain1* sc1 = *ppSC;
        void** vtbl = *reinterpret_cast<void***>(sc1);

        MH_CreateHook(vtbl[8],  reinterpret_cast<void*>(Present_Hook),
                      reinterpret_cast<void**>(&g_origPresent));
        MH_CreateHook(vtbl[22], reinterpret_cast<void*>(Present1_Hook),
                      reinterpret_cast<void**>(&g_origPresent1));
        MH_EnableHook(vtbl[8]);
        MH_EnableHook(vtbl[22]);
    }

    return hr;
}

// ── Hook installation ─────────────────────────────────────────────────────────

static void InstallHooks()
{
    MH_Initialize();

    IDXGIFactory2* tmp = nullptr;
    if (SUCCEEDED(CreateDXGIFactory2(0, IID_PPV_ARGS(&tmp))))
    {
        void** vtbl = *reinterpret_cast<void***>(tmp);
        MH_CreateHook(vtbl[15], reinterpret_cast<void*>(CreateSCFH_Hook),
                      reinterpret_cast<void**>(&g_origCreateSCFH));
        MH_EnableHook(vtbl[15]);
        tmp->Release();
    }
}

static void UninstallHooks()
{
    MH_DisableHook(MH_ALL_HOOKS);
    MH_Uninitialize();

    if (g_origWndProc && g_gameHwnd)
        SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC,
                          reinterpret_cast<LONG_PTR>(g_origWndProc));

    if (g_d3dReady)
    {
        ImGui_ImplDX12_Shutdown();
        ImGui_ImplWin32_Shutdown();
        ImGui::DestroyContext();
    }

    if (g_fence)     { g_fence->Release();       g_fence = nullptr; }
    if (g_fenceEvent){ CloseHandle(g_fenceEvent); g_fenceEvent = nullptr; }
    if (g_cmdList)   { g_cmdList->Release();      g_cmdList = nullptr; }
    for (auto& a : g_alloc) { if (a) { a->Release(); a = nullptr; } }
    if (g_rtvHeap)   { g_rtvHeap->Release();      g_rtvHeap = nullptr; }
    if (g_srvHeap)   { g_srvHeap->Release();      g_srvHeap = nullptr; }
    if (g_ueQueue)   { g_ueQueue->Release();       g_ueQueue = nullptr; }
    if (g_device)    { g_device->Release();        g_device = nullptr; }
}

// ── Mod class ─────────────────────────────────────────────────────────────────

class TheGoldModSettingsMod : public RC::CppUserModBase
{
    GMSettings m_saved;
    GMSettings m_edit;
    bool       m_dirty      = false;
    bool       m_showSaved  = false;
    float      m_flashTimer = 0.f;

    // One custom-key buffer per keybind
    char m_wheelBuf[64]{};
    char m_primaryBuf[64]{};
    char m_secondaryBuf[64]{};
    char m_revertBuf[64]{};

    std::atomic<bool> m_unrealReady{false};
    int               m_pollTick = 0;

public:
    TheGoldModSettingsMod() : CppUserModBase()
    {
        ModName        = STR("TheGoldModSettings");
        ModVersion     = STR("1.0");
        ModDescription = STR("In-game settings overlay for TheGoldMod");
        ModAuthors     = STR("rafa");

        m_saved = LoadSettings();
        m_edit  = m_saved;
        SyncCustomBufs();

        {
            std::lock_guard<std::mutex> lk(g_overlayMtx);
            g_renderFn = [this] { RenderPanel(); };
        }

        // F9 force-show for testing
        register_keydown_event(Input::Key::F9, [this]() {
            g_showOverlay.store(!g_showOverlay.load(std::memory_order_relaxed),
                                std::memory_order_relaxed);
        });

        register_keydown_event(Input::Key::ESCAPE, [this]() {
            g_showOverlay.store(false, std::memory_order_relaxed);
        });

        InstallHooks();
    }

    ~TheGoldModSettingsMod() override
    {
        {
            std::lock_guard<std::mutex> lk(g_overlayMtx);
            g_renderFn = nullptr;
        }
        UninstallHooks();
    }

    auto on_unreal_init() -> void override
    {
        m_unrealReady = true;
    }

    auto on_update() -> void override
    {
        if (!m_unrealReady.load(std::memory_order_relaxed)) return;
        if (++m_pollTick < 6) return;
        m_pollTick = 0;

        auto* vm = RC::Unreal::UObjectGlobals::FindFirstOf(L"WBP_Settings2Screen_C");
        g_showOverlay.store(vm != nullptr, std::memory_order_relaxed);

        bool content = false;
        if (vm != nullptr)
        {
            std::ifstream f(GetModRootDir() / L"settings_open.flag");
            if (f.is_open()) { char c = '0'; f.get(c); content = (c == '1'); }
        }
        g_showContent.store(content, std::memory_order_relaxed);
    }

private:
    // ── Panel shell ───────────────────────────────────────────────────────────

    void RenderPanel()
    {
        if (!g_showContent.load(std::memory_order_relaxed)) return;

        const ImGuiIO& io = ImGui::GetIO();

        // Identical dimensions to SN2ThirdPersonSettings (measured at 1920×1080)
        constexpr float kPanelLeft  = 25.f;
        constexpr float kTopFrac    = 0.1796f;  // 194 / 1080
        constexpr float kBottomFrac = 0.8000f;  // (194 + 670) / 1080
        constexpr float kWidthFrac  = 0.1146f;  // 220 / 1920

        const float panelX = kPanelLeft;
        const float panelY = io.DisplaySize.y * kTopFrac;
        const float panelW = io.DisplaySize.x * kWidthFrac;
        const float panelH = io.DisplaySize.y * (kBottomFrac - kTopFrac);

        ImGui::SetNextWindowPos(ImVec2(panelX, panelY), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(panelW, panelH), ImGuiCond_Always);

        constexpr ImGuiWindowFlags flags =
            ImGuiWindowFlags_NoMove             |
            ImGuiWindowFlags_NoResize           |
            ImGuiWindowFlags_NoCollapse         |
            ImGuiWindowFlags_NoSavedSettings    |
            ImGuiWindowFlags_AlwaysVerticalScrollbar;

        if (!ImGui::Begin("TheGoldMod", nullptr, flags))
        {
            ImGui::End();
            return;
        }

        RenderContent();
        ImGui::End();
    }

    // ── Panel content ─────────────────────────────────────────────────────────

    void RenderContent()
    {
        // ── BEHAVIOUR ─────────────────────────────────────────────────────────
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.55f, 0.80f, 1.00f, 1.00f));
        ImGui::TextUnformatted("BEHAVIOUR");
        ImGui::PopStyleColor();
        ImGui::Spacing();

        if (ImGui::Checkbox("Auto-unlock all forms", &m_edit.autoUnlock))
            m_dirty = true;
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip(
                "Calls UnlockAll() at mod startup so every\n"
                "creature form is immediately available.\n\n"
                "Unlocked state is saved to dna_save.txt and\n"
                "persists even if you disable this setting.");

        ImGui::Spacing();
        ImGui::Separator();
        ImGui::Spacing();

        // ── KEYBINDS ──────────────────────────────────────────────────────────
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.55f, 0.80f, 1.00f, 1.00f));
        ImGui::TextUnformatted("KEYBINDS");
        ImGui::PopStyleColor();
        ImGui::Spacing();

        RenderKeyRow("Wheel",     "##wheel",     "Open / close the creature selection wheel.", m_edit.wheelKey,     m_wheelBuf,     sizeof(m_wheelBuf));
        ImGui::Spacing();
        RenderKeyRow("Primary",   "##primary",   "Activate primary ability while transformed.", m_edit.primaryKey,   m_primaryBuf,   sizeof(m_primaryBuf));
        ImGui::Spacing();
        RenderKeyRow("Secondary", "##secondary", "Activate secondary ability while transformed.", m_edit.secondaryKey, m_secondaryBuf, sizeof(m_secondaryBuf));
        ImGui::Spacing();
        RenderKeyRow("Revert",    "##revert",    "Revert to human instantly (panic button).", m_edit.revertKey,    m_revertBuf,    sizeof(m_revertBuf));

        ImGui::Spacing();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.00f, 0.80f, 0.30f, 0.85f));
        ImGui::TextWrapped("Key changes require Ctrl+R to take effect.");
        ImGui::PopStyleColor();

        ImGui::Spacing();
        ImGui::Separator();
        ImGui::Spacing();

        // ── Save / Reset ──────────────────────────────────────────────────────
        if (m_dirty)
        {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.00f, 0.75f, 0.20f, 1.00f));
            ImGui::TextUnformatted("*  Unsaved changes");
            ImGui::PopStyleColor();
        }

        if (m_dirty)
        {
            ImGui::PushStyleColor(ImGuiCol_Button,        ImVec4(0.18f, 0.50f, 0.18f, 1.00f));
            ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.28f, 0.68f, 0.28f, 1.00f));
            ImGui::PushStyleColor(ImGuiCol_ButtonActive,  ImVec4(0.12f, 0.38f, 0.12f, 1.00f));
        }
        if (ImGui::Button("Save"))
        {
            m_saved      = m_edit;
            SaveSettings(m_saved);
            m_dirty      = false;
            m_showSaved  = true;
            m_flashTimer = 2.5f;
        }
        if (m_dirty) ImGui::PopStyleColor(3);

        ImGui::SameLine(0.f, 10.f);
        if (ImGui::Button("Reset to defaults"))
        {
            GMSettings def{};
            m_edit = def;
            SyncCustomBufs();
            m_dirty = (m_edit != m_saved);
        }

        if (m_showSaved)
        {
            ImGui::SameLine(0.f, 14.f);
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.35f, 1.00f, 0.35f, 1.00f));
            ImGui::TextUnformatted("Saved!");
            ImGui::PopStyleColor();
            m_flashTimer -= ImGui::GetIO().DeltaTime;
            if (m_flashTimer <= 0.f) m_showSaved = false;
        }
    }

    // ── Key dropdown helper ───────────────────────────────────────────────────
    // Renders label + combo. Shows custom text input below if key not in preset list.
    // Sets m_dirty = true if changed.

    void RenderKeyRow(const char* label, const char* comboId, const char* tooltip,
                      std::string& editKey, char* customBuf, size_t bufSz)
    {
        int         sel     = FindKeyIndex(editKey);
        const char* preview = sel >= 0 ? k_keys[sel] : "Custom...";

        ImGui::TextUnformatted(label);
        ImGui::SameLine();
        ImGui::TextDisabled("(?)");
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("%s\n\nKey names match UE4SS identifiers, e.g.:\n  G, F3, NUM_ONE, INSERT ...\n\nKey changes require Ctrl+R.", tooltip);

        const float helpW = ImGui::CalcTextSize(" (?)").x + ImGui::GetStyle().ItemSpacing.x;
        ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x);
        if (ImGui::BeginCombo(comboId, preview))
        {
            for (int i = 0; i < k_key_count; ++i)
            {
                bool is_sel = (i == sel);
                if (ImGui::Selectable(k_keys[i], is_sel))
                {
                    editKey = k_keys[i];
                    strncpy_s(customBuf, bufSz, editKey.c_str(), bufSz - 1);
                    m_dirty = true;
                }
                if (is_sel) ImGui::SetItemDefaultFocus();
            }
            if (ImGui::Selectable("Custom...", sel < 0))
            {
                editKey = customBuf;
                m_dirty = true;
            }
            ImGui::EndCombo();
        }

        if (sel < 0)
        {
            ImGui::SetNextItemWidth(-FLT_MIN);
            std::string inputId = std::string("##custom_") + comboId;
            if (ImGui::InputText(inputId.c_str(), customBuf, bufSz))
            {
                editKey = customBuf;
                m_dirty = true;
            }
        }
    }

    void SyncCustomBufs()
    {
        strncpy_s(m_wheelBuf,     m_edit.wheelKey.c_str(),     sizeof(m_wheelBuf) - 1);
        strncpy_s(m_primaryBuf,   m_edit.primaryKey.c_str(),   sizeof(m_primaryBuf) - 1);
        strncpy_s(m_secondaryBuf, m_edit.secondaryKey.c_str(), sizeof(m_secondaryBuf) - 1);
        strncpy_s(m_revertBuf,    m_edit.revertKey.c_str(),     sizeof(m_revertBuf) - 1);
    }
};

// ── Exports ───────────────────────────────────────────────────────────────────

extern "C"
{
    __declspec(dllexport) RC::CppUserModBase* start_mod()
    {
        return new TheGoldModSettingsMod();
    }

    __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* m)
    {
        delete m;
    }
}
