// keyholder (Windows) — holds key combos down until told to release.
//
// Protocol, one command per line on stdin:
//   D <id> <mods> <key>   press and HOLD under <id>. Either combo field may be "-".
//   U <id>                release the hold owned by <id>
//   T <mods> <key>        TAP a combo without disturbing anything held
//   C 1 / C 0             start / stop capturing the keyboard
//
// Replies on stdout, one per line:
//   CAPTURE on|off|failed
//   K D <name> / K U <name>   a key went down or up while capturing ("-" if unrecognised)
//
// Capture exists because the property inspector is a web view: by the time a keystroke
// reaches it the system has already acted on it, so recording Ctrl+Alt+T would fire
// whatever Ctrl+Alt+T is bound to instead of recording it. A low-level keyboard hook sees
// keys first and swallows them, which is the only way to record a combination that is
// already a shortcut.
//
// Holds are keyed by id because several Stream Deck buttons or pedals can be down at
// once, and each must release only its own keys. A shared key or modifier stays down
// until the last hold that wants it lets go.
//
// Unlike macOS (where a combo is one event carrying modifier flags), SendInput has no
// flags field: the modifier keys must be physically pressed, then the key, and released
// in reverse order. That asymmetry is why the helper owns combo semantics, not the plugin.

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <iostream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

const std::map<std::string, WORD> kKeys = {
    {"a", 'A'}, {"b", 'B'}, {"c", 'C'}, {"d", 'D'}, {"e", 'E'}, {"f", 'F'},
    {"g", 'G'}, {"h", 'H'}, {"i", 'I'}, {"j", 'J'}, {"k", 'K'}, {"l", 'L'},
    {"m", 'M'}, {"n", 'N'}, {"o", 'O'}, {"p", 'P'}, {"q", 'Q'}, {"r", 'R'},
    {"s", 'S'}, {"t", 'T'}, {"u", 'U'}, {"v", 'V'}, {"w", 'W'}, {"x", 'X'},
    {"y", 'Y'}, {"z", 'Z'},
    {"space", VK_SPACE},
    {"0", '0'}, {"1", '1'}, {"2", '2'}, {"3", '3'}, {"4", '4'},
    {"5", '5'}, {"6", '6'}, {"7", '7'}, {"8", '8'}, {"9", '9'},
    {"enter", VK_RETURN}, {"numpadenter", VK_RETURN},
    {"tab", VK_TAB}, {"escape", VK_ESCAPE},
    {"backspace", VK_BACK}, {"delete", VK_DELETE}, {"insert", VK_INSERT},
    {"home", VK_HOME}, {"end", VK_END}, {"pageup", VK_PRIOR},
    {"pagedown", VK_NEXT}, {"left", VK_LEFT}, {"right", VK_RIGHT},
    {"up", VK_UP}, {"down", VK_DOWN},
    {"semicolon", VK_OEM_1}, {"equal", VK_OEM_PLUS}, {"comma", VK_OEM_COMMA},
    {"minus", VK_OEM_MINUS}, {"period", VK_OEM_PERIOD}, {"slash", VK_OEM_2},
    {"backquote", VK_OEM_3}, {"leftbracket", VK_OEM_4},
    {"backslash", VK_OEM_5}, {"rightbracket", VK_OEM_6}, {"quote", VK_OEM_7},
    {"f1", VK_F1}, {"f2", VK_F2}, {"f3", VK_F3}, {"f4", VK_F4},
    {"f5", VK_F5}, {"f6", VK_F6}, {"f7", VK_F7}, {"f8", VK_F8},
    {"f9", VK_F9}, {"f10", VK_F10}, {"f11", VK_F11}, {"f12", VK_F12},
    {"f13", VK_F13}, {"f14", VK_F14}, {"f15", VK_F15}, {"f16", VK_F16},
    {"f17", VK_F17}, {"f18", VK_F18}, {"f19", VK_F19}, {"f20", VK_F20},
};

// "cmd" is the Mac name; on Windows the equivalent physical key is Win.
const std::map<std::string, WORD> kMods = {
    {"ctrl", VK_CONTROL},
    {"alt", VK_MENU},
    {"shift", VK_SHIFT},
    {"cmd", VK_LWIN},
    {"lctrl", VK_LCONTROL}, {"rctrl", VK_RCONTROL},
    {"lalt", VK_LMENU}, {"ralt", VK_RMENU},
    {"lshift", VK_LSHIFT}, {"rshift", VK_RSHIFT},
    {"lcmd", VK_LWIN}, {"rcmd", VK_RWIN},
};

// A virtual-key plus its extended-key bit. Numpad Enter and Return are the same
// VK_RETURN and are told apart only by that bit, so the flag has to travel with the key
// rather than be derived from the virtual-key alone.
struct KeyCode {
  WORD vk = 0;
  bool extended = false;

  explicit operator bool() const { return vk != 0; }
  bool operator==(const KeyCode& other) const {
    return vk == other.vk && extended == other.extended;
  }
};

struct Hold {
  std::string id;
  KeyCode key;  // vk == 0 when the combo is modifiers only
  std::vector<KeyCode> mods;
};

// Everything currently held, in press order, so we can always release it — even if the
// plugin dies mid-hold. A stuck key is the worst failure here.
std::vector<Hold> g_holds;

// Is this key down on behalf of any hold? Keys are never pressed twice or released while
// another hold still wants them.
bool IsDown(const KeyCode& key) {
  for (const Hold& hold : g_holds) {
    if (hold.key == key) return true;
    if (std::find(hold.mods.begin(), hold.mods.end(), key) != hold.mods.end()) return true;
  }
  return false;
}

bool IsExtendedKey(WORD vk) {
  switch (vk) {
    case VK_RCONTROL:
    case VK_RMENU:
    case VK_LWIN:
    case VK_RWIN:
    case VK_INSERT:
    case VK_DELETE:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_LEFT:
    case VK_RIGHT:
    case VK_UP:
    case VK_DOWN:
      return true;
    default:
      return false;
  }
}

// Names whose extended bit cannot be recovered from the virtual-key, because another
// name maps to the same one.
KeyCode Resolve(const std::string& name, WORD vk) {
  return KeyCode{vk, IsExtendedKey(vk) || name == "numpadenter"};
}

void SendKey(const KeyCode& key, bool down) {
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = key.vk;
  input.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) |
                     (key.extended ? KEYEVENTF_EXTENDEDKEY : 0);
  SendInput(1, &input, sizeof(INPUT));
}

void ReleaseHold(const std::string& id) {
  auto it = std::find_if(g_holds.begin(), g_holds.end(),
                         [&](const Hold& hold) { return hold.id == id; });
  if (it == g_holds.end()) return;

  const Hold hold = *it;
  g_holds.erase(it);

  // Reverse order: key first, then modifiers — but only what no other hold still wants.
  if (hold.key && !IsDown(hold.key)) SendKey(hold.key, false);
  for (auto m = hold.mods.rbegin(); m != hold.mods.rend(); ++m) {
    if (!IsDown(*m)) SendKey(*m, false);
  }
}

void ReleaseAll() {
  while (!g_holds.empty()) {
    ReleaseHold(g_holds.back().id);
  }
}

void Press(const std::string& id, const std::vector<KeyCode>& mods, const KeyCode& key) {
  ReleaseHold(id);
  for (const KeyCode& m : mods) {
    if (!IsDown(m)) SendKey(m, true);
  }
  if (key && !IsDown(key)) SendKey(key, true);
  g_holds.push_back(Hold{id, key, mods});
}

// Tap a combo *without* disturbing any hold — this is what makes a "before release"
// hotkey different from an "after release" one. Modifiers already down are reused rather
// than re-pressed, and a tap key identical to a held key is skipped: its key-up would
// cancel the hold that owns it.
void TapOver(const std::vector<KeyCode>& mods, const KeyCode& key) {
  std::vector<KeyCode> extra;
  for (const KeyCode& m : mods) {
    if (!IsDown(m)) extra.push_back(m);
  }

  for (const KeyCode& m : extra) SendKey(m, true);
  if (key && !IsDown(key)) {
    SendKey(key, true);
    SendKey(key, false);
  } else if (key) {
    std::cerr << "keyholder: skipping tap of the key already held\n";
  }
  for (auto it = extra.rbegin(); it != extra.rend(); ++it) SendKey(*it, false);
}

std::mutex g_out;

void Emit(const std::string& line) {
  std::lock_guard<std::mutex> held(g_out);
  std::cout << line << std::endl;
}

// Virtual-key back to the name the plugin and property inspector use. Left and right
// modifiers arrive as distinct virtual-keys in a low-level hook, so the side survives.
std::string NameForKey(DWORD vk, bool extended) {
  switch (vk) {
    case VK_LCONTROL: return "lctrl";
    case VK_RCONTROL: return "rctrl";
    case VK_LMENU: return "lalt";
    case VK_RMENU: return "ralt";
    case VK_LSHIFT: return "lshift";
    case VK_RSHIFT: return "rshift";
    case VK_LWIN: return "lcmd";
    case VK_RWIN: return "rcmd";
    default: break;
  }
  // Return and numpad Enter share VK_RETURN and differ only by the extended bit.
  if (vk == VK_RETURN) return extended ? "numpadenter" : "enter";
  for (const auto& entry : kKeys) {
    if (entry.second == vk && entry.first != "numpadenter") return entry.first;
  }
  return "-";
}

// Capturing swallows every keystroke, so it runs on its own thread with its own message
// loop and cannot outlive its welcome: the timer ends it even if the plugin goes away
// mid-recording. A wedged capture would be a dead keyboard, as bad as a stuck key.
constexpr UINT kCaptureTimeoutMs = 15000;
std::thread g_capture;
std::atomic<DWORD> g_capture_thread_id{0};
HHOOK g_hook = nullptr;

LRESULT CALLBACK OnCapturedKey(int code, WPARAM w_param, LPARAM l_param) {
  if (code != HC_ACTION) return CallNextHookEx(nullptr, code, w_param, l_param);
  const KBDLLHOOKSTRUCT* key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(l_param);
  const bool up = (key->flags & LLKHF_UP) != 0;
  Emit(std::string("K ") + (up ? "U " : "D ") +
       NameForKey(key->vkCode, (key->flags & LLKHF_EXTENDED) != 0));
  return 1;  // swallow it, so the shortcut it would trigger does not fire
}

void CaptureRun() {
  g_hook = SetWindowsHookExW(WH_KEYBOARD_LL, OnCapturedKey, GetModuleHandleW(nullptr), 0);
  if (!g_hook) {
    Emit("CAPTURE failed");
    return;
  }
  g_capture_thread_id = GetCurrentThreadId();
  const UINT_PTR deadline = SetTimer(nullptr, 0, kCaptureTimeoutMs, nullptr);
  Emit("CAPTURE on");

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if (msg.message == WM_TIMER) break;
  }

  KillTimer(nullptr, deadline);
  UnhookWindowsHookEx(g_hook);
  g_hook = nullptr;
  g_capture_thread_id = 0;
  Emit("CAPTURE off");
}

void StopCapture() {
  const DWORD id = g_capture_thread_id.load();
  if (id != 0) PostThreadMessageW(id, WM_QUIT, 0, 0);
  if (g_capture.joinable()) g_capture.join();
}

void StartCapture() {
  if (g_capture_thread_id.load() != 0) return;
  if (g_capture.joinable()) g_capture.join();
  g_capture = std::thread(CaptureRun);
}

BOOL WINAPI OnConsoleEvent(DWORD) {
  ReleaseAll();
  ExitProcess(0);
  return TRUE;
}

std::string Lower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return s;
}

}  // namespace

int main() {
  SetConsoleCtrlHandler(OnConsoleEvent, TRUE);

  std::string line;
  while (std::getline(std::cin, line)) {
    std::istringstream stream(line);
    std::string verb;
    stream >> verb;

    if (verb == "C") {
      std::string state;
      if (!(stream >> state)) {
        std::cerr << "keyholder: bad command: " << line << "\n";
        continue;
      }
      if (state == "1") {
        StartCapture();
      } else {
        StopCapture();
      }
      continue;
    }
    if (verb == "U") {
      std::string id;
      if (!(stream >> id)) {
        std::cerr << "keyholder: bad command: " << line << "\n";
        continue;
      }
      ReleaseHold(id);
      continue;
    }
    if (verb != "D" && verb != "T") continue;

    std::string id, mod_list, key_name;
    const bool is_hold = verb == "D";
    if (is_hold && !(stream >> id)) {
      std::cerr << "keyholder: bad command: " << line << "\n";
      continue;
    }
    if (!(stream >> mod_list >> key_name)) {
      std::cerr << "keyholder: bad command: " << line << "\n";
      continue;
    }

    KeyCode key_code;
    const std::string key_lower = Lower(key_name);
    auto key = kKeys.find(key_lower);
    if (key_name != "-" && key == kKeys.end()) {
      std::cerr << "keyholder: unknown key: " << key_name << "\n";
      continue;
    }
    if (key != kKeys.end()) key_code = Resolve(key_lower, key->second);

    std::vector<KeyCode> mods;
    if (mod_list != "-") {
      std::istringstream mod_stream(mod_list);
      std::string name;
      while (std::getline(mod_stream, name, ',')) {
        const std::string mod_lower = Lower(name);
        auto mod = kMods.find(mod_lower);
        if (mod != kMods.end()) mods.push_back(Resolve(mod_lower, mod->second));
      }
    }

    if (mods.empty() && !key_code) continue;
    if (is_hold) {
      Press(id, mods, key_code);
    } else {
      TapOver(mods, key_code);
    }
  }

  // stdin closed — Stream Deck killed the plugin. Never leave a key down, and never leave
  // the keyboard swallowed.
  StopCapture();
  ReleaseAll();
  return 0;
}
