// keyholder (Windows) — holds a key combo down until told to release.
//
// Protocol, one command per line on stdin:
//   D <mods> <key>   press and HOLD. mods is "-" or a comma list: ctrl,alt,shift,cmd
//   U                release whatever is held
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
    {"f13", VK_F13}, {"f14", VK_F14}, {"f15", VK_F15}, {"f16", VK_F16},
    {"f17", VK_F17}, {"f18", VK_F18}, {"f19", VK_F19},
};

// "cmd" is the Mac name; on Windows the equivalent physical key is Win.
const std::map<std::string, WORD> kMods = {
    {"ctrl", VK_CONTROL},
    {"alt", VK_MENU},
    {"shift", VK_SHIFT},
    {"cmd", VK_LWIN},
};

// What is currently held, in press order, so we can always release it — even if the
// plugin dies mid-hold. A stuck key is the worst failure here.
std::vector<WORD> g_held;

void SendKey(WORD vk, bool down) {
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
  SendInput(1, &input, sizeof(INPUT));
}

void ReleaseHeld() {
  // Reverse order: key first, then modifiers.
  for (auto it = g_held.rbegin(); it != g_held.rend(); ++it) {
    SendKey(*it, false);
  }
  g_held.clear();
}

void Press(const std::vector<WORD>& mods, WORD key) {
  ReleaseHeld();
  for (WORD m : mods) {
    SendKey(m, true);
    g_held.push_back(m);
  }
  SendKey(key, true);
  g_held.push_back(key);
}

BOOL WINAPI OnConsoleEvent(DWORD) {
  ReleaseHeld();
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
      ReleaseHeld();
      continue;
    }
    if (verb != "D") continue;

    std::string mod_list, key_name;
    stream >> mod_list >> key_name;

    auto key = kKeys.find(Lower(key_name));
    if (key == kKeys.end()) {
      std::cerr << "keyholder: unknown key: " << key_name << "\n";
      continue;
    }

    std::vector<WORD> mods;
    if (mod_list != "-") {
      std::istringstream mod_stream(mod_list);
      std::string name;
      while (std::getline(mod_stream, name, ',')) {
        auto mod = kMods.find(Lower(name));
        if (mod != kMods.end()) mods.push_back(mod->second);
      }
    }

    Press(mods, key->second);
  }

  // stdin closed — Stream Deck killed the plugin. Never leave a key down.
  ReleaseHeld();
  return 0;
}
