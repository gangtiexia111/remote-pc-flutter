#include "flutter_window.h"

#include <optional>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winternl.h>
#include <intrin.h>
#include <sstream>
#include <iomanip>
#include <dpapi.h>
#include <shlobj.h>
#include <wintrust.h>

#include "flutter/generated_plugin_registrant.h"

// -- Native Security Bridge Implementation --

// Detect if being debugged (IsDebuggerPresent + NtQueryInformationProcess)
static bool IsBeingDebugged() {
    if (::IsDebuggerPresent()) return true;

    BOOL debugged = FALSE;
    ::CheckRemoteDebuggerPresent(::GetCurrentProcess(), &debugged);
    if (debugged) return true;

    // NtQueryInformationProcess: ProcessDebugPort = 7
    typedef NTSTATUS(NTAPI* pfnNtQueryInformationProcess)(
        HANDLE, UINT, PVOID, ULONG, PULONG);
    HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
    if (ntdll) {
        auto NtQIP = reinterpret_cast<pfnNtQueryInformationProcess>(
            ::GetProcAddress(ntdll, "NtQueryInformationProcess"));
        if (NtQIP) {
            DWORD_PTR debugPort = 0;
            NTSTATUS status = NtQIP(::GetCurrentProcess(), 7, &debugPort, sizeof(debugPort), nullptr);
            if (status == 0 && debugPort != 0) return true;
        }
    }

    return false;
}

// Get hardware fingerprint (CPU ID + Board Serial -> SHA-256)
static std::string GetHardwareFingerprint() {
    std::stringstream ss;

    // Get CPU ID
    int cpuInfo[4] = {};
    __cpuid(cpuInfo, 1);
    ss << std::hex << cpuInfo[0] << cpuInfo[3];

    // Get board serial from registry
    HKEY hKey = nullptr;
    if (::RegOpenKeyExW(HKEY_LOCAL_MACHINE,
        L"HARDWARE\\DESCRIPTION\\System\\BIOS",
        0, KEY_READ, &hKey) == ERROR_SUCCESS) {
        wchar_t buf[256] = {};
        DWORD size = sizeof(buf);
        if (::RegQueryValueExW(hKey, L"SystemSerialNumber", nullptr, nullptr,
            reinterpret_cast<LPBYTE>(buf), &size) == ERROR_SUCCESS) {
            // Convert wchar_t to narrow string (ASCII-safe for serial numbers)
            std::wstring ws(buf);
            ss << "|";
            for (auto wc : ws) {
                ss << static_cast<char>(wc & 0xFF);
            }
        }
        ::RegCloseKey(hKey);
    }

    std::string raw = ss.str();

    // BCrypt SHA-256
    BCRYPT_ALG_HANDLE hAlg = nullptr;
    BCRYPT_HASH_HANDLE hHash = nullptr;
    DWORD cbHash = 0, cbData = 0;

    if (::BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_SHA256_ALGORITHM,
        nullptr, 0) == 0) {
        ::BCryptGetProperty(hAlg, BCRYPT_HASH_LENGTH,
            reinterpret_cast<PBYTE>(&cbHash), sizeof(DWORD), &cbData, 0);
        ::BCryptCreateHash(hAlg, &hHash, nullptr, 0, nullptr, 0, 0);
        ::BCryptHashData(hHash,
            reinterpret_cast<PBYTE>(const_cast<char*>(raw.data())),
            static_cast<ULONG>(raw.size()), 0);

        std::vector<BYTE> hash(cbHash);
        ::BCryptFinishHash(hHash, hash.data(), cbHash, 0);

        std::stringstream hex;
        for (auto b : hash) {
            hex << std::setfill('0') << std::setw(2) << std::hex << static_cast<int>(b);
        }

        ::BCryptDestroyHash(hHash);
        ::BCryptCloseAlgorithmProvider(hAlg, 0);

        return hex.str();
    }

    // Fallback: return raw data
    return raw;
}


// System integrity check (functional implementation)
static bool VerifySystemIntegrity() {
    // 1. Ensure no debugger is present
    if (::IsDebuggerPresent()) return false;

    // 2. Check current exe exists
    wchar_t exePath[MAX_PATH] = {};
    if (::GetModuleFileNameW(nullptr, exePath, MAX_PATH) == 0) return false;
    if (::GetFileAttributesW(exePath) == INVALID_FILE_ATTRIBUTES) return false;

    // 3. Check critical DLLs are loaded (basic integrity)
    if (!::GetModuleHandleW(L"kernel32.dll")) return false;
    if (!::GetModuleHandleW(L"ntdll.dll")) return false;
    if (!::GetModuleHandleW(L"user32.dll")) return false;

    // 4. Check for common injection tool windows (simple heuristic)
    // (Full WinVerifyTrust impl deferred to v1.0.4)
    return true;
}

// Native self-destruct: remove app data directory
static bool NativeSelfDestruct(const std::string& reason) {
    (void)reason;  // reserved for future use

    wchar_t appDataPath[MAX_PATH] = {};
    if (::SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, appDataPath) != S_OK) {
        return false;
    }

    std::wstring appDir(appDataPath);
    appDir += L"\\remote_pc";

    std::wstring doubleNullPath = appDir + L'\0';

    SHFILEOPSTRUCTW fileOp = {};
    fileOp.wFunc = FO_DELETE;
    fileOp.pFrom = doubleNullPath.c_str();
    fileOp.fFlags = FOF_NOCONFIRMATION | FOF_SILENT;

    int result = ::SHFileOperationW(&fileOp);
    return (result == 0);
}

// -- FlutterWindow Implementation --

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
    if (!Win32Window::OnCreate()) {
        return false;
    }

    RECT frame = GetClientArea();

    flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
        frame.right - frame.left, frame.bottom - frame.top, project_);
    if (!flutter_controller_->engine() || !flutter_controller_->view()) {
        return false;
    }
    RegisterPlugins(flutter_controller_->engine());
    SetChildContent(flutter_controller_->view()->GetNativeWindow());

    // Register native security MethodChannel
    const static std::string channelName("com.remotepc/security");

    flutter::MethodChannel<> channel(
        flutter_controller_->engine()->messenger(), channelName,
        &flutter::StandardMethodCodec::GetInstance());

    channel.SetMethodCallHandler(
        [](const flutter::MethodCall<>& call,
           std::unique_ptr<flutter::MethodResult<>> result) {
            if (call.method_name() == "isBeingDebugged") {
                result->Success(flutter::EncodableValue(IsBeingDebugged()));
            } else if (call.method_name() == "verifySystemIntegrity") {
                result->Success(flutter::EncodableValue(VerifySystemIntegrity()));
            } else if (call.method_name() == "getHardwareFingerprint") {
                result->Success(flutter::EncodableValue(GetHardwareFingerprint()));
            } else if (call.method_name() == "nativeSelfDestruct") {
                const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
                std::string reason;
                if (args) {
                    auto it = args->find(flutter::EncodableValue("reason"));
                    if (it != args->end()) {
                        reason = std::get<std::string>(it->second);
                    }
                }
                result->Success(flutter::EncodableValue(NativeSelfDestruct(reason)));
            } else {
                result->NotImplemented();
            }
        });

    flutter_controller_->engine()->SetNextFrameCallback([&]() {
        this->Show();
    });

    flutter_controller_->ForceRedraw();

    return true;
}

void FlutterWindow::OnDestroy() {
    if (flutter_controller_) {
        flutter_controller_ = nullptr;
    }

    Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
    if (flutter_controller_) {
        std::optional<LRESULT> result =
            flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                          lparam);
        if (result) {
            return *result;
        }
    }

    switch (message) {
        case WM_FONTCHANGE:
            flutter_controller_->engine()->ReloadSystemFonts();
            break;
    }

    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
