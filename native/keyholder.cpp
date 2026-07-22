// keyholder (Windows) — holds key combos down until told to release.
//
// Protocol, one command per line on stdin:
//   D <id> <mods> <key>   press and HOLD under <id>. Either combo field may be "-".
//   U <id>                release the hold owned by <id>
//   T <mods> <key>        TAP a combo without disturbing anything held
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
#include <iostream>
#include <map>
#include <sstream>
#include <string>
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

  // stdin closed — Stream Deck killed the plugin. Never leave a key down.
  ReleaseAll();
  return 0;
}
